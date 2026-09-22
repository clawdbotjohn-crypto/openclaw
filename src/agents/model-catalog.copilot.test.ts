import { beforeEach, describe, expect, it, vi } from "vitest";

vi.mock("../providers/github-copilot-model-discovery.js", () => ({
  prepareGitHubCopilotModels: vi.fn(async () => ({
    status: "success",
    models: [
      {
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
      },
    ],
  })),
}));
vi.mock("./models-config.js", () => ({ ensureOpenClawModelsJson: vi.fn() }));
vi.mock("./agent-paths.js", () => ({ resolveOpenClawAgentDir: () => "/tmp/catalog-test" }));

import {
  __setModelCatalogImportForTest,
  loadModelCatalog,
  resetModelCatalogCacheForTest,
} from "./model-catalog.js";

describe("model catalog Copilot discovery", () => {
  beforeEach(() => {
    resetModelCatalogCacheForTest();
    __setModelCatalogImportForTest(
      async () =>
        ({
          discoverAuthStorage: () => ({}),
          ModelRegistry: class {
            getAll() {
              return [];
            }
          },
        }) as never,
    );
  });

  it("includes authenticated models on the first uncached load", async () => {
    const models = await loadModelCatalog({ config: {}, useCache: false });
    expect(models).toContainEqual(
      expect.objectContaining({ provider: "github-copilot", id: "gpt-live-only" }),
    );
  });
});
