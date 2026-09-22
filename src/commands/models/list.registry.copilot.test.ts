import { describe, expect, it, vi } from "vitest";

const discoveredModel = {
  id: "gpt-live-only",
  name: "GPT Live Only",
  provider: "github-copilot",
  api: "openai-responses",
  baseUrl: "https://api.copilot.test",
  reasoning: true,
  input: ["text"],
  cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
  contextWindow: 200_000,
  maxTokens: 20_000,
};

vi.mock("../../agents/agent-paths.js", () => ({
  resolveOpenClawAgentDir: () => "/tmp/copilot-list-test",
}));
vi.mock("../../agents/models-config.js", () => ({ ensureOpenClawModelsJson: vi.fn() }));
vi.mock("../../agents/pi-model-discovery.js", () => ({
  discoverAuthStorage: () => ({}),
  discoverModels: () => ({ getAll: () => [], getAvailable: () => [] }),
}));
vi.mock("../../providers/github-copilot-model-discovery.js", () => ({
  prepareGitHubCopilotModels: vi.fn(async () => ({
    status: "success",
    models: [discoveredModel],
  })),
}));

import { loadModelRegistry } from "./list.registry.js";
import { modelKey } from "./shared.js";

describe("models list Copilot discovery", () => {
  it("adds the same authenticated definition and marks it available", async () => {
    const loaded = await loadModelRegistry({});
    expect(loaded.models).toContainEqual(discoveredModel);
    expect(loaded.availableKeys?.has(modelKey("github-copilot", "gpt-live-only"))).toBe(true);
  });
});
