import { beforeEach, describe, expect, it, vi } from "vitest";
import {
  discoverGitHubCopilotModels,
  normalizeGitHubCopilotModelsResponse,
  resetGitHubCopilotModelDiscoveryForTest,
} from "./github-copilot-model-discovery.js";
import type { resolveCopilotApiToken } from "./github-copilot-token.js";

const visible = (id: string, overrides: Record<string, unknown> = {}) => ({
  id,
  name: id,
  object: "model",
  vendor: id.includes("claude") ? "Anthropic" : id.includes("gemini") ? "Google" : "OpenAI",
  model_picker_enabled: true,
  policy: { state: "enabled" },
  capabilities: {
    type: "chat",
    family: id,
    supports: {
      tool_calls: true,
      streaming: true,
      vision: true,
      reasoning_effort: ["low", "high"],
    },
    limits: {
      max_context_window_tokens: 200_000,
      max_prompt_tokens: 180_000,
      max_output_tokens: 20_000,
    },
  },
  ...overrides,
});
const response = (data: unknown[], ok = true) =>
  ({ ok, status: ok ? 200 : 503, json: async () => ({ data }) }) as Response;
const exchange = (baseUrl: string, token = "short-lived-secret") =>
  vi.fn(async () => ({
    token,
    expiresAt: Date.now() + 60_000,
    baseUrl,
    source: "network" as const,
  })) as unknown as typeof resolveCopilotApiToken;

describe("GitHub Copilot live model discovery", () => {
  beforeEach(() => resetGitHubCopilotModelDiscoveryForTest());

  it("strictly maps visible executable models and filters unsupported rows", () => {
    const models = normalizeGitHubCopilotModelsResponse(
      {
        data: [
          visible("claude-opus-4.8"),
          visible("gemini-3-pro"),
          visible("gpt-5.6-sol"),
          visible("hidden", { model_picker_enabled: false }),
          visible("accounts/router"),
          visible("no-tools", {
            capabilities: { type: "chat", family: "gpt", supports: { tool_calls: false } },
          }),
          visible("disabled", { policy: { state: "disabled" } }),
          visible("no-stream", {
            capabilities: {
              type: "chat",
              family: "gpt",
              supports: { tool_calls: true, streaming: false },
            },
          }),
        ],
      },
      "https://api.example.test",
    );
    expect(models.map(({ id, api }) => [id, api])).toEqual([
      ["claude-opus-4.8", "anthropic-messages"],
      ["gemini-3-pro", "openai-completions"],
      ["gpt-5.6-sol", "openai-responses"],
    ]);
    expect(models[2]).toMatchObject({
      contextWindow: 200_000,
      maxTokens: 20_000,
      reasoning: true,
      input: ["text", "image"],
      headers: expect.objectContaining({
        "Editor-Version": "vscode/1.107.0",
        "Copilot-Integration-Id": "vscode-chat",
      }),
    });
    expect(() =>
      normalizeGitHubCopilotModelsResponse(
        { data: [{ ...visible("bad"), model_picker_enabled: "yes" }] },
        "https://api.test",
      ),
    ).toThrow("Invalid Copilot /models");
  });

  it("coalesces concurrent requests and refreshes after the 30 second TTL", async () => {
    let now = 1_000;
    const fetchImpl = vi.fn().mockResolvedValue(response([visible("gpt-new")])) as typeof fetch;
    const params = {
      githubToken: "account-a",
      fetchImpl,
      now: () => now,
      resolveTokenImpl: exchange("https://api.a.test"),
    };
    const [first, concurrent] = await Promise.all([
      discoverGitHubCopilotModels(params),
      discoverGitHubCopilotModels(params),
    ]);
    expect(first).toEqual(concurrent);
    expect(fetchImpl).toHaveBeenCalledWith(
      "https://api.a.test/models",
      expect.objectContaining({
        headers: expect.objectContaining({
          Authorization: "Bearer short-lived-secret",
          "User-Agent": "GitHubCopilotChat/0.35.0",
          "Editor-Version": "vscode/1.107.0",
          "Editor-Plugin-Version": "copilot-chat/0.35.0",
          "Copilot-Integration-Id": "vscode-chat",
        }),
      }),
    );
    expect(fetchImpl).toHaveBeenCalledTimes(1);
    await discoverGitHubCopilotModels(params);
    expect(fetchImpl).toHaveBeenCalledTimes(1);
    now += 30_001;
    await discoverGitHubCopilotModels(params);
    expect(fetchImpl).toHaveBeenCalledTimes(2);
  });

  it("preserves stale evidence on transient failure but replaces it on authoritative removal", async () => {
    let now = 0;
    const fetchImpl = vi
      .fn()
      .mockResolvedValueOnce(response([visible("gpt-live-only")]))
      .mockResolvedValueOnce(response([], false))
      .mockResolvedValueOnce(response([]))
      .mockResolvedValueOnce(response([], false)) as typeof fetch;
    const params = {
      githubToken: "account-a",
      fetchImpl,
      now: () => now,
      resolveTokenImpl: exchange("https://api.a.test"),
    };
    expect((await discoverGitHubCopilotModels(params)).models).toHaveLength(1);
    now += 30_001;
    const stale = await discoverGitHubCopilotModels(params);
    expect(stale.status).toBe("stale");
    expect(stale.models[0]?.id).toBe("gpt-live-only");
    now += 30_001;
    expect(await discoverGitHubCopilotModels(params)).toEqual({ status: "success", models: [] });
    now += 30_001;
    expect(await discoverGitHubCopilotModels(params)).toEqual({ status: "stale", models: [] });
  });

  it("isolates account and base URL caches while allowing bearer rotation", async () => {
    let now = 0;
    const fetchA = vi.fn().mockResolvedValue(response([visible("gpt-a")])) as typeof fetch;
    const fetchB = vi.fn().mockResolvedValue(response([visible("gpt-b")])) as typeof fetch;
    await discoverGitHubCopilotModels({
      githubToken: "account-a",
      fetchImpl: fetchA,
      now: () => now,
      resolveTokenImpl: exchange("https://api.a.test", "bearer-1"),
    });
    await discoverGitHubCopilotModels({
      githubToken: "account-b",
      fetchImpl: fetchB,
      now: () => now,
      resolveTokenImpl: exchange("https://api.a.test", "bearer-2"),
    });
    now += 30_001;
    const rotated = await discoverGitHubCopilotModels({
      githubToken: "account-a",
      fetchImpl: vi.fn().mockResolvedValue(response([], false)) as typeof fetch,
      now: () => now,
      resolveTokenImpl: exchange("https://api.a.test", "bearer-rotated"),
    });
    expect(rotated.models[0]?.id).toBe("gpt-a");
    const otherBase = await discoverGitHubCopilotModels({
      githubToken: "account-a",
      fetchImpl: vi.fn().mockResolvedValue(response([], false)) as typeof fetch,
      now: () => now,
      resolveTokenImpl: exchange("https://enterprise.test", "bearer-3"),
    });
    expect(otherBase).toEqual({ status: "unavailable", models: [] });
  });

  it("does not mutate config or expose bearer values in returned definitions", async () => {
    const config = { agents: { defaults: { models: { "github-copilot/gpt-new": {} } } } };
    const before = structuredClone(config);
    const result = await discoverGitHubCopilotModels({
      githubToken: "github-secret",
      fetchImpl: vi.fn().mockResolvedValue(response([visible("gpt-new")])) as typeof fetch,
      resolveTokenImpl: exchange("https://api.test", "bearer-secret"),
    });
    expect(config).toEqual(before);
    expect(JSON.stringify(result)).not.toContain("secret");
  });
});
