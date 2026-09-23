import { createHash } from "node:crypto";
import type { Api, Model } from "@mariozechner/pi-ai";
import { resolveApiKeyForProvider } from "../agents/model-auth.js";
import type { OpenClawConfig } from "../config/config.js";
import { resolveCopilotApiToken } from "./github-copilot-token.js";

const CACHE_TTL_MS = 30_000;
const REQUEST_TIMEOUT_MS = 8_000;
const DEFAULT_CONTEXT_WINDOW = 128_000;
const DEFAULT_MAX_TOKENS = 8_192;
const PROVIDER = "github-copilot";
const COPILOT_CLIENT_HEADERS = {
  "User-Agent": "GitHubCopilotChat/0.35.0",
  "Editor-Version": "vscode/1.107.0",
  "Editor-Plugin-Version": "copilot-chat/0.35.0",
  "Copilot-Integration-Id": "vscode-chat",
} as const;

type JsonObject = Record<string, unknown>;
export type CopilotDiscoveryResult =
  | { status: "success" | "stale"; models: Model<Api>[] }
  | { status: "unavailable" | "no-auth"; models: [] };
type CacheEntry = { expiresAt: number; models: Model<Api>[] };

// Keys are one-way account identity + normalized API base URL. Short-lived
// bearer tokens are deliberately absent so refreshes share TTL/stale evidence.
const cache = new Map<string, CacheEntry>();
const inFlight = new Map<string, Promise<CopilotDiscoveryResult>>();
const accountKeys = new Map<string, Set<string>>();

function isObject(value: unknown): value is JsonObject {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
function optionalBoolean(parent: JsonObject, key: string): boolean | undefined {
  const value = parent[key];
  if (value === undefined) {
    return undefined;
  }
  if (typeof value !== "boolean") {
    throw new Error(`Invalid Copilot /models field: ${key}`);
  }
  return value;
}
function optionalString(parent: JsonObject, key: string): string | undefined {
  const value = parent[key];
  if (value === undefined) {
    return undefined;
  }
  if (typeof value !== "string") {
    throw new Error(`Invalid Copilot /models field: ${key}`);
  }
  return value;
}
function optionalPositiveNumber(parent: JsonObject, key: string): number | undefined {
  const value = parent[key];
  if (value === undefined) {
    return undefined;
  }
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value <= 0) {
    throw new Error(`Invalid Copilot /models field: ${key}`);
  }
  return value;
}
function optionalObject(parent: JsonObject, key: string): JsonObject | undefined {
  const value = parent[key];
  if (value === undefined) {
    return undefined;
  }
  if (!isObject(value)) {
    throw new Error(`Invalid Copilot /models field: ${key}`);
  }
  return value;
}
function optionalStringArray(parent: JsonObject, key: string): string[] | null | undefined {
  const value = parent[key];
  if (value === undefined || value === null) {
    return value;
  }
  if (!Array.isArray(value) || value.some((entry) => typeof entry !== "string")) {
    throw new Error(`Invalid Copilot /models field: ${key}`);
  }
  return value;
}

function resolveApi(params: { id: string; vendor?: string; family?: string }): Api | undefined {
  const vendor = params.vendor?.toLowerCase() ?? "";
  const family = params.family?.toLowerCase() ?? "";
  const identity = `${family} ${params.id.toLowerCase()}`;
  if (vendor === "anthropic" || identity.includes("claude")) {
    return "anthropic-messages";
  }
  if (identity.includes("gemini")) {
    return "openai-completions";
  }
  if (vendor === "openai" || /(?:^|\s)(?:gpt-|o\d|codex)/.test(identity)) {
    return "openai-responses";
  }
  return undefined;
}

export function normalizeGitHubCopilotModelsResponse(
  payload: unknown,
  baseUrl: string,
): Model<Api>[] {
  if (!isObject(payload) || !Array.isArray(payload.data)) {
    throw new Error("Invalid Copilot /models response: expected object with data array");
  }
  const models: Model<Api>[] = [];
  const seen = new Set<string>();
  for (const raw of payload.data) {
    if (!isObject(raw)) {
      throw new Error("Invalid Copilot /models response: model must be object");
    }
    const id = optionalString(raw, "id")?.trim();
    if (!id) {
      throw new Error("Invalid Copilot /models response: model id required");
    }
    const name = optionalString(raw, "name")?.trim();
    const object = optionalString(raw, "object")?.toLowerCase();
    const vendor = optionalString(raw, "vendor");
    const pickerEnabled = optionalBoolean(raw, "model_picker_enabled");
    const capabilities = optionalObject(raw, "capabilities") ?? {};
    const type = optionalString(capabilities, "type")?.toLowerCase();
    const family = optionalString(capabilities, "family");
    const supports = optionalObject(capabilities, "supports") ?? {};
    const limits = optionalObject(capabilities, "limits") ?? {};
    const policy = optionalObject(raw, "policy") ?? {};
    const policyState = optionalString(policy, "state")?.toLowerCase();
    const toolCalls = optionalBoolean(supports, "tool_calls");
    const streaming = optionalBoolean(supports, "streaming");
    const vision = optionalBoolean(supports, "vision");
    const reasoningEffort = optionalStringArray(supports, "reasoning_effort");

    // Account visibility and executable chat/tool evidence are mandatory.
    if (
      id.startsWith("accounts/") ||
      id.includes("/") ||
      /\s/.test(id) ||
      object !== "model" ||
      type !== "chat" ||
      pickerEnabled !== true ||
      toolCalls !== true ||
      streaming === false ||
      policyState === "disabled" ||
      policyState === "unconfigured"
    ) {
      continue;
    }
    const api = resolveApi({ id, vendor, family });
    const identity = id.toLowerCase();
    if (!api || seen.has(identity)) {
      continue;
    }
    seen.add(identity);
    models.push({
      id,
      name: name || id,
      api,
      provider: PROVIDER,
      baseUrl,
      // IDE-authenticated Copilot endpoints require the client identity on
      // inference requests as well as on /models discovery.
      headers: { ...COPILOT_CLIENT_HEADERS },
      reasoning: Array.isArray(reasoningEffort) && reasoningEffort.length > 0,
      input: vision === true ? ["text", "image"] : ["text"],
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
      contextWindow:
        optionalPositiveNumber(limits, "max_context_window_tokens") ??
        optionalPositiveNumber(limits, "max_prompt_tokens") ??
        DEFAULT_CONTEXT_WINDOW,
      maxTokens: optionalPositiveNumber(limits, "max_output_tokens") ?? DEFAULT_MAX_TOKENS,
    } as Model<Api>);
  }
  return models;
}

function hash(value: string): string {
  return createHash("sha256").update(value).digest("hex");
}
function staleForAccount(accountKey: string): CopilotDiscoveryResult {
  const keys = accountKeys.get(accountKey);
  // When exchange itself fails the API base URL is unknown. Reuse stale
  // evidence only when this account has exactly one known URL; otherwise fail
  // closed rather than crossing enterprise/public endpoint scopes.
  if (!keys || keys.size !== 1) {
    return { status: "unavailable", models: [] };
  }
  const entry = cache.get([...keys][0]);
  return entry ? { status: "stale", models: entry.models } : { status: "unavailable", models: [] };
}

export async function discoverGitHubCopilotModels(params: {
  githubToken: string;
  fetchImpl?: typeof fetch;
  now?: () => number;
  resolveTokenImpl?: typeof resolveCopilotApiToken;
}): Promise<CopilotDiscoveryResult> {
  const githubToken = params.githubToken.trim();
  if (!githubToken) {
    return { status: "no-auth", models: [] };
  }
  const accountKey = hash(githubToken);
  const now = params.now ?? Date.now;
  let exchanged: Awaited<ReturnType<typeof resolveCopilotApiToken>>;
  try {
    exchanged = await (params.resolveTokenImpl ?? resolveCopilotApiToken)({ githubToken });
  } catch {
    return staleForAccount(accountKey);
  }
  const baseUrl = exchanged.baseUrl.replace(/\/+$/, "");
  const key = `${accountKey}:${baseUrl}`;
  const cached = cache.get(key);
  if (cached && cached.expiresAt > now()) {
    return { status: "success", models: cached.models };
  }
  const pending = inFlight.get(key);
  if (pending) {
    return pending;
  }
  const request = (async (): Promise<CopilotDiscoveryResult> => {
    try {
      const response = await (params.fetchImpl ?? fetch)(`${baseUrl}/models`, {
        method: "GET",
        headers: {
          Authorization: `Bearer ${exchanged.token}`,
          Accept: "application/json",
          ...COPILOT_CLIENT_HEADERS,
        },
        signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
      });
      if (!response.ok) {
        return cached
          ? { status: "stale", models: cached.models }
          : { status: "unavailable", models: [] };
      }
      const models = normalizeGitHubCopilotModelsResponse(await response.json(), baseUrl);
      cache.set(key, { expiresAt: now() + CACHE_TTL_MS, models });
      const keys = accountKeys.get(accountKey) ?? new Set<string>();
      keys.add(key);
      accountKeys.set(accountKey, keys);
      return { status: "success", models };
    } catch {
      return cached
        ? { status: "stale", models: cached.models }
        : { status: "unavailable", models: [] };
    } finally {
      inFlight.delete(key);
    }
  })();
  inFlight.set(key, request);
  return request;
}

export async function prepareGitHubCopilotModels(params: {
  cfg?: OpenClawConfig;
  agentDir?: string;
  profileId?: string;
}): Promise<CopilotDiscoveryResult> {
  try {
    const auth = await resolveApiKeyForProvider({
      provider: PROVIDER,
      cfg: params.cfg,
      agentDir: params.agentDir,
      profileId: params.profileId,
    });
    return auth.apiKey
      ? discoverGitHubCopilotModels({ githubToken: auth.apiKey })
      : { status: "no-auth", models: [] };
  } catch {
    return { status: "no-auth", models: [] };
  }
}

export function resetGitHubCopilotModelDiscoveryForTest(): void {
  cache.clear();
  inFlight.clear();
  accountKeys.clear();
}
