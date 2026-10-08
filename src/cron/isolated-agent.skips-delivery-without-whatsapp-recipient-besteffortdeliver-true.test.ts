import "./isolated-agent.mocks.js";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { afterAll, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
import { runSubagentAnnounceFlow } from "../agents/subagent-announce.js";
import * as subagentRegistry from "../agents/subagent-registry.js";
import type { CliDeps } from "../cli/deps.js";
import { callGateway } from "../gateway/call.js";
import {
  createCliDeps,
  expectDirectTelegramDelivery,
  mockAgentPayloads,
  runTelegramAnnounceTurn,
} from "./isolated-agent.delivery.test-helpers.js";
import { runCronIsolatedAgentTurn } from "./isolated-agent.js";
import { writeSessionStore } from "./isolated-agent.test-harness.js";
import { setupIsolatedAgentTurnMocks } from "./isolated-agent.test-setup.js";
import * as subagentFollowup from "./isolated-agent/subagent-followup.js";

type HomeEnvSnapshot = {
  HOME: string | undefined;
  USERPROFILE: string | undefined;
  HOMEDRIVE: string | undefined;
  HOMEPATH: string | undefined;
  OPENCLAW_HOME: string | undefined;
  OPENCLAW_STATE_DIR: string | undefined;
};

const TELEGRAM_TARGET = { mode: "announce", channel: "telegram", to: "123" } as const;
let suiteTempHomeRoot = "";
let suiteTempHomeCaseId = 0;

function snapshotHomeEnv(): HomeEnvSnapshot {
  return {
    HOME: process.env.HOME,
    USERPROFILE: process.env.USERPROFILE,
    HOMEDRIVE: process.env.HOMEDRIVE,
    HOMEPATH: process.env.HOMEPATH,
    OPENCLAW_HOME: process.env.OPENCLAW_HOME,
    OPENCLAW_STATE_DIR: process.env.OPENCLAW_STATE_DIR,
  };
}

function restoreHomeEnv(snapshot: HomeEnvSnapshot) {
  const restoreValue = (key: keyof HomeEnvSnapshot) => {
    const value = snapshot[key];
    if (value === undefined) {
      delete process.env[key];
    } else {
      process.env[key] = value;
    }
  };
  restoreValue("HOME");
  restoreValue("USERPROFILE");
  restoreValue("HOMEDRIVE");
  restoreValue("HOMEPATH");
  restoreValue("OPENCLAW_HOME");
  restoreValue("OPENCLAW_STATE_DIR");
}

async function withTempHome<T>(fn: (home: string) => Promise<T>): Promise<T> {
  const home = path.join(suiteTempHomeRoot, `case-${suiteTempHomeCaseId++}`);
  await fs.mkdir(path.join(home, ".openclaw", "agents", "main", "sessions"), { recursive: true });
  const snapshot = snapshotHomeEnv();
  process.env.HOME = home;
  process.env.USERPROFILE = home;
  delete process.env.OPENCLAW_HOME;
  process.env.OPENCLAW_STATE_DIR = path.join(home, ".openclaw");
  if (process.platform === "win32") {
    const parsed = path.parse(home);
    if (parsed.root) {
      process.env.HOMEDRIVE = parsed.root.replace(/[\\/]+$/, "");
      process.env.HOMEPATH = home.slice(process.env.HOMEDRIVE.length) || "\\";
    }
  }
  try {
    return await fn(home);
  } finally {
    restoreHomeEnv(snapshot);
  }
}

async function runExplicitTelegramAnnounceTurn(params: {
  home: string;
  storePath: string;
  deps: CliDeps;
}): Promise<Awaited<ReturnType<typeof runCronIsolatedAgentTurn>>> {
  return runTelegramAnnounceTurn({
    ...params,
    delivery: TELEGRAM_TARGET,
  });
}

async function withTelegramAnnounceFixture(
  run: (params: { home: string; storePath: string; deps: CliDeps }) => Promise<void>,
  params?: {
    deps?: Partial<CliDeps>;
    sessionStore?: { lastProvider?: string; lastTo?: string };
  },
): Promise<void> {
  await withTempHome(async (home) => {
    const storePath = await writeSessionStore(home, {
      lastProvider: params?.sessionStore?.lastProvider ?? "webchat",
      lastTo: params?.sessionStore?.lastTo ?? "",
    });
    const deps = createCliDeps(params?.deps);
    await run({ home, storePath, deps });
  });
}

function expectDeliveredOk(result: Awaited<ReturnType<typeof runCronIsolatedAgentTurn>>): void {
  expect(result.status).toBe("ok");
  expect(result.delivered).toBe(true);
}

async function expectBestEffortTelegramNotDelivered(
  payload: Record<string, unknown>,
): Promise<void> {
  await expectStructuredTelegramFailure({
    payload,
    bestEffort: true,
    expectedStatus: "ok",
    expectDeliveryAttempted: true,
  });
}

async function expectStructuredTelegramFailure(params: {
  payload: Record<string, unknown>;
  bestEffort: boolean;
  expectedStatus: "ok" | "error";
  expectedErrorFragment?: string;
  expectDeliveryAttempted?: boolean;
}): Promise<void> {
  await withTelegramAnnounceFixture(
    async ({ home, storePath, deps }) => {
      mockAgentPayloads([params.payload]);
      const res = await runTelegramAnnounceTurn({
        home,
        storePath,
        deps,
        delivery: {
          ...TELEGRAM_TARGET,
          ...(params.bestEffort ? { bestEffort: true } : {}),
        },
      });

      expect(res.status).toBe(params.expectedStatus);
      if (params.expectedStatus === "ok") {
        expect(res.delivered).toBe(false);
      }
      if (params.expectDeliveryAttempted !== undefined) {
        expect(res.deliveryAttempted).toBe(params.expectDeliveryAttempted);
      }
      if (params.expectedErrorFragment) {
        expect(res.error).toContain(params.expectedErrorFragment);
      }
      expect(runSubagentAnnounceFlow).not.toHaveBeenCalled();
      expect(deps.sendMessageTelegram).toHaveBeenCalledTimes(1);
    },
    {
      deps: {
        sendMessageTelegram: vi.fn().mockRejectedValue(new Error("boom")),
      },
    },
  );
}

async function runFailedTextDelivery(bestEffort: boolean) {
  let outcome:
    | {
        res: Awaited<ReturnType<typeof runCronIsolatedAgentTurn>>;
        deps: CliDeps;
      }
    | undefined;
  await withTelegramAnnounceFixture(
    async ({ home, storePath, deps }) => {
      mockAgentPayloads([{ text: "hello from cron" }]);
      const res = await runTelegramAnnounceTurn({
        home,
        storePath,
        deps,
        delivery: {
          mode: "announce",
          channel: "telegram",
          to: "123",
          bestEffort,
        },
      });
      outcome = { res, deps };
    },
    {
      deps: {
        sendMessageTelegram: vi.fn().mockRejectedValue(new Error("direct delivery failed")),
      },
    },
  );
  if (!outcome) {
    throw new Error("direct delivery did not produce an outcome");
  }
  return outcome;
}

async function assertExplicitTelegramTargetAnnounce(params: {
  home: string;
  storePath: string;
  deps: CliDeps;
  payloads: Array<Record<string, unknown>>;
  expectedText: string;
}): Promise<void> {
  mockAgentPayloads(params.payloads);
  const res = await runExplicitTelegramAnnounceTurn({
    home: params.home,
    storePath: params.storePath,
    deps: params.deps,
  });

  expectDeliveredOk(res);
  expect(runSubagentAnnounceFlow).not.toHaveBeenCalled();
  expectDirectTelegramDelivery(params.deps, {
    chatId: "123",
    text: params.expectedText,
  });
}

describe("runCronIsolatedAgentTurn", () => {
  beforeAll(async () => {
    suiteTempHomeRoot = await fs.mkdtemp(path.join(os.tmpdir(), "openclaw-cron-delivery-suite-"));
  });

  afterAll(async () => {
    if (!suiteTempHomeRoot) {
      return;
    }
    await fs.rm(suiteTempHomeRoot, { recursive: true, force: true });
    suiteTempHomeRoot = "";
    suiteTempHomeCaseId = 0;
  });

  beforeEach(() => {
    setupIsolatedAgentTurnMocks();
  });

  it("announces explicit targets with direct and final-payload text", async () => {
    await withTelegramAnnounceFixture(async ({ home, storePath, deps }) => {
      await assertExplicitTelegramTargetAnnounce({
        home,
        storePath,
        deps,
        payloads: [{ text: "hello from cron" }],
        expectedText: "hello from cron",
      });
      vi.clearAllMocks();
      await assertExplicitTelegramTargetAnnounce({
        home,
        storePath,
        deps,
        payloads: [{ text: "Working on it..." }, { text: "Final weather summary" }],
        expectedText: "Final weather summary",
      });
    });
  });

  it("patches kept session labels after direct delivery", async () => {
    await withTelegramAnnounceFixture(async ({ home, storePath, deps }) => {
      mockAgentPayloads([{ text: "hello from cron" }]);

      const res = await runExplicitTelegramAnnounceTurn({ home, storePath, deps });

      expectDeliveredOk(res);
      expect(deps.sendMessageTelegram).toHaveBeenCalledTimes(1);
      expect(callGateway).toHaveBeenCalledTimes(1);
      expect(callGateway).toHaveBeenCalledWith({
        method: "sessions.patch",
        params: { key: "agent:main:cron:job-1", label: "job-1" },
        timeoutMs: 10_000,
      });
    });
  });

  it("patches then deletes one-shot sessions after the direct send", async () => {
    await withTelegramAnnounceFixture(async ({ home, storePath, deps }) => {
      mockAgentPayloads([{ text: "hello from cron" }]);

      const res = await runTelegramAnnounceTurn({
        home,
        storePath,
        deps,
        deleteAfterRun: true,
        delivery: TELEGRAM_TARGET,
      });

      expectDeliveredOk(res);
      expect(callGateway).toHaveBeenNthCalledWith(1, {
        method: "sessions.patch",
        params: { key: "agent:main:cron:job-1", label: "job-1" },
        timeoutMs: 10_000,
      });
      expect(callGateway).toHaveBeenNthCalledWith(2, {
        method: "sessions.delete",
        params: {
          key: "agent:main:cron:job-1",
          deleteTranscript: true,
          emitLifecycleHooks: false,
        },
        timeoutMs: 10_000,
      });
      const sendOrder = vi.mocked(deps.sendMessageTelegram).mock.invocationCallOrder[0];
      const [patchOrder, deleteOrder] = vi.mocked(callGateway).mock.invocationCallOrder;
      expect(sendOrder).toBeLessThan(patchOrder);
      expect(patchOrder).toBeLessThan(deleteOrder);
    });
  });

  it("delivers the descendant-synthesized final without using the requester announce lane", async () => {
    const countSpy = vi
      .spyOn(subagentRegistry, "countActiveDescendantRuns")
      .mockReturnValueOnce(24)
      .mockReturnValue(0);
    const waitSpy = vi
      .spyOn(subagentFollowup, "waitForDescendantSubagentSummary")
      .mockResolvedValue("Final answer after all descendants");
    vi.mocked(runSubagentAnnounceFlow).mockRejectedValue(
      new Error("requester session lane is busy"),
    );

    try {
      await withTelegramAnnounceFixture(async ({ home, storePath, deps }) => {
        mockAgentPayloads([{ text: "Still working on descendant results..." }]);

        const res = await runExplicitTelegramAnnounceTurn({ home, storePath, deps });

        expectDeliveredOk(res);
        expect(waitSpy).toHaveBeenCalledTimes(1);
        expect(runSubagentAnnounceFlow).not.toHaveBeenCalled();
        expectDirectTelegramDelivery(deps, {
          chatId: "123",
          text: "Final answer after all descendants",
        });
      });
    } finally {
      countSpy.mockRestore();
      waitSpy.mockRestore();
    }
  });

  it("delivers once but does not delete while ended descendants still have pending callbacks", async () => {
    const pendingSpy = vi.spyOn(subagentRegistry, "countPendingDescendantRuns").mockReturnValue(3);

    try {
      await withTelegramAnnounceFixture(async ({ home, storePath, deps }) => {
        mockAgentPayloads([{ text: "Final answer with callbacks still draining" }]);

        const res = await runTelegramAnnounceTurn({
          home,
          storePath,
          deps,
          deleteAfterRun: true,
          delivery: TELEGRAM_TARGET,
        });

        expectDeliveredOk(res);
        expectDirectTelegramDelivery(deps, {
          chatId: "123",
          text: "Final answer with callbacks still draining",
        });
        expect(callGateway).toHaveBeenCalledWith(
          expect.objectContaining({ method: "sessions.patch" }),
        );
        expect(callGateway).not.toHaveBeenCalledWith(
          expect.objectContaining({ method: "sessions.delete" }),
        );
      });
    } finally {
      pendingSpy.mockRestore();
    }
  });

  it("does not patch or delete when descendant delivery is deferred before direct send", async () => {
    const countSpy = vi
      .spyOn(subagentRegistry, "countActiveDescendantRuns")
      .mockReturnValueOnce(2)
      .mockReturnValue(1);
    const waitSpy = vi
      .spyOn(subagentFollowup, "waitForDescendantSubagentSummary")
      .mockResolvedValue(undefined);

    try {
      await withTelegramAnnounceFixture(async ({ home, storePath, deps }) => {
        mockAgentPayloads([{ text: "Still working on descendant results..." }]);

        const res = await runTelegramAnnounceTurn({
          home,
          storePath,
          deps,
          deleteAfterRun: true,
          delivery: TELEGRAM_TARGET,
        });

        expect(res.status).toBe("ok");
        expect(res.deliveryAttempted).toBe(false);
        expect(waitSpy).toHaveBeenCalledTimes(1);
        expect(deps.sendMessageTelegram).not.toHaveBeenCalled();
        expect(callGateway).not.toHaveBeenCalled();
      });
    } finally {
      countSpy.mockRestore();
      waitSpy.mockRestore();
    }
  });

  it("splits oversized direct text deterministically through the channel adapter", async () => {
    await withTelegramAnnounceFixture(async ({ home, storePath, deps }) => {
      const text = "x".repeat(8_001);
      mockAgentPayloads([{ text }]);

      const res = await runExplicitTelegramAnnounceTurn({ home, storePath, deps });

      expectDeliveredOk(res);
      expect(runSubagentAnnounceFlow).not.toHaveBeenCalled();
      const chunks = vi.mocked(deps.sendMessageTelegram).mock.calls.map((call) => call[1]);
      expect(chunks).toHaveLength(3);
      expect(chunks.every((chunk) => chunk.length <= 4_000)).toBe(true);
      expect(chunks.join("")).toBe(text);
    });
  });

  it("routes direct announce delivery with the configured target and account", async () => {
    await withTelegramAnnounceFixture(async ({ home, storePath, deps }) => {
      mockAgentPayloads([{ text: "hello from cron" }]);

      const res = await runTelegramAnnounceTurn({
        home,
        storePath,
        deps,
        delivery: {
          mode: "announce",
          channel: "telegram",
          to: "123",
          accountId: "alerts",
        },
      });

      expectDeliveredOk(res);
      expect(runSubagentAnnounceFlow).not.toHaveBeenCalled();
      expect(deps.sendMessageTelegram).toHaveBeenCalledWith(
        "123",
        "hello from cron",
        expect.objectContaining({ accountId: "alerts" }),
      );
    });
  });

  it("routes threaded announce targets through direct delivery", async () => {
    await withTempHome(async (home) => {
      const storePath = await writeSessionStore(home, { lastProvider: "webchat", lastTo: "" });
      await fs.writeFile(
        storePath,
        JSON.stringify(
          {
            "agent:main:main": {
              sessionId: "main-session",
              updatedAt: Date.now(),
              lastChannel: "telegram",
              lastTo: "123",
              lastThreadId: 42,
            },
          },
          null,
          2,
        ),
        "utf-8",
      );
      const deps = createCliDeps();
      mockAgentPayloads([{ text: "Final weather summary" }]);
      const res = await runTelegramAnnounceTurn({
        home,
        storePath,
        deps,
        delivery: { mode: "announce", channel: "last" },
      });

      expect(res.status).toBe("ok");
      expect(res.delivered).toBe(true);
      expect(runSubagentAnnounceFlow).not.toHaveBeenCalled();
      expectDirectTelegramDelivery(deps, {
        chatId: "123",
        text: "Final weather summary",
        messageThreadId: 42,
      });
    });
  });

  it("keeps thread-bound direct delivery failures as run errors", async () => {
    await withTempHome(async (home) => {
      const storePath = await writeSessionStore(home, { lastProvider: "webchat", lastTo: "" });
      await fs.writeFile(
        storePath,
        JSON.stringify(
          {
            "agent:main:main": {
              sessionId: "main-session",
              updatedAt: Date.now(),
              lastChannel: "telegram",
              lastTo: "123",
              lastThreadId: 42,
            },
          },
          null,
          2,
        ),
        "utf-8",
      );
      const deps = createCliDeps({
        sendMessageTelegram: vi.fn().mockRejectedValue(new Error("thread send failed")),
      });
      mockAgentPayloads([{ text: "Final weather summary" }]);

      const res = await runTelegramAnnounceTurn({
        home,
        storePath,
        deps,
        delivery: { mode: "announce", channel: "last" },
      });

      expect(res.status).toBe("error");
      expect(res.deliveryAttempted).toBe(true);
      expect(res.error).toContain("thread send failed");
      expect(runSubagentAnnounceFlow).not.toHaveBeenCalled();
    });
  });

  it("skips announce when messaging tool already sent to target", async () => {
    await withTelegramAnnounceFixture(async ({ home, storePath, deps }) => {
      mockAgentPayloads([{ text: "sent" }], {
        didSendViaMessagingTool: true,
        messagingToolSentTargets: [{ tool: "message", provider: "telegram", to: "123" }],
      });

      const res = await runExplicitTelegramAnnounceTurn({
        home,
        storePath,
        deps,
      });

      expectDeliveredOk(res);
      expect(runSubagentAnnounceFlow).not.toHaveBeenCalled();
      expect(deps.sendMessageTelegram).not.toHaveBeenCalled();
    });
  });

  it("delivers structured channel payloads directly without announce flow", async () => {
    await withTelegramAnnounceFixture(async ({ home, storePath, deps }) => {
      const buttons = [[{ text: "Approve", callback_data: "approve" }]];
      mockAgentPayloads([{ text: "Choose an action", channelData: { telegram: { buttons } } }]);

      const res = await runExplicitTelegramAnnounceTurn({ home, storePath, deps });

      expectDeliveredOk(res);
      expect(runSubagentAnnounceFlow).not.toHaveBeenCalled();
      expect(deps.sendMessageTelegram).toHaveBeenCalledWith(
        "123",
        "Choose an action",
        expect.objectContaining({ buttons }),
      );
    });
  });

  it("reports not-delivered when best-effort structured outbound sends all fail", async () => {
    await expectBestEffortTelegramNotDelivered({
      text: "caption",
      mediaUrl: "https://example.com/img.png",
    });
  });

  it("skips announce for heartbeat-only output", async () => {
    await withTelegramAnnounceFixture(async ({ home, storePath, deps }) => {
      mockAgentPayloads([{ text: "HEARTBEAT_OK" }]);
      const res = await runTelegramAnnounceTurn({
        home,
        storePath,
        deps,
        delivery: { mode: "announce", channel: "telegram", to: "123" },
      });

      expect(res.status).toBe("ok");
      expect(runSubagentAnnounceFlow).not.toHaveBeenCalled();
      expect(deps.sendMessageTelegram).not.toHaveBeenCalled();
    });
  });

  it("fails when structured direct delivery fails and best-effort is disabled", async () => {
    await expectStructuredTelegramFailure({
      payload: { text: "hello from cron", mediaUrl: "https://example.com/img.png" },
      bestEffort: false,
      expectedStatus: "error",
      expectedErrorFragment: "boom",
    });
  });

  it("preserves successful run status when direct text delivery fails", async () => {
    const { res, deps } = await runFailedTextDelivery(false);
    expect(res.status).toBe("ok");
    expect(res.delivered).toBe(false);
    expect(res.deliveryAttempted).toBe(true);
    expect(res.error).toContain("direct delivery failed");
    expect(runSubagentAnnounceFlow).not.toHaveBeenCalled();
    expect(deps.sendMessageTelegram).toHaveBeenCalledTimes(1);
  });

  it("marks best-effort direct text failures as attempted but not delivered", async () => {
    const { res, deps } = await runFailedTextDelivery(true);
    expect(res.status).toBe("ok");
    expect(res.delivered).toBe(false);
    expect(res.deliveryAttempted).toBe(true);
    expect(res.error).toBeUndefined();
    expect(runSubagentAnnounceFlow).not.toHaveBeenCalled();
    expect(deps.sendMessageTelegram).toHaveBeenCalledTimes(1);
  });

  it("ignores structured direct delivery failures when best-effort is enabled", async () => {
    await expectBestEffortTelegramNotDelivered({
      text: "hello from cron",
      mediaUrl: "https://example.com/img.png",
    });
  });
});
