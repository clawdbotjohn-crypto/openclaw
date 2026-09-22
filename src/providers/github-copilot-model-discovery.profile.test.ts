import { afterEach, describe, expect, it, vi } from "vitest";

const { resolveApiKeyForProvider } = vi.hoisted(() => ({
  resolveApiKeyForProvider: vi.fn(async () => ({
    apiKey: "github-account-token",
    source: "profile:copilot:work",
    mode: "oauth" as const,
  })),
}));
vi.mock("../agents/model-auth.js", () => ({ resolveApiKeyForProvider }));
vi.mock("./github-copilot-token.js", () => ({
  resolveCopilotApiToken: vi.fn(async () => ({
    token: "short-bearer",
    expiresAt: Date.now() + 60_000,
    baseUrl: "https://api.profile.test",
    source: "network",
  })),
}));

import {
  prepareGitHubCopilotModels,
  resetGitHubCopilotModelDiscoveryForTest,
} from "./github-copilot-model-discovery.js";

describe("Copilot discovery profile scoping", () => {
  afterEach(() => {
    vi.unstubAllGlobals();
    resetGitHubCopilotModelDiscoveryForTest();
  });

  it("uses the explicitly selected auth profile without mutating config", async () => {
    const cfg = { agents: { defaults: { models: { "github-copilot/gpt-live": {} } } } };
    const before = structuredClone(cfg);
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => ({ ok: true, json: async () => ({ data: [] }) })),
    );
    await prepareGitHubCopilotModels({ cfg, agentDir: "/tmp/agent", profileId: "copilot:work" });
    expect(resolveApiKeyForProvider).toHaveBeenCalledWith({
      provider: "github-copilot",
      cfg,
      agentDir: "/tmp/agent",
      profileId: "copilot:work",
    });
    expect(cfg).toEqual(before);
  });
});
