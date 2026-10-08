import {
  countActiveDescendantRuns,
  countPendingDescendantRuns,
} from "../../agents/subagent-registry.js";
import { SILENT_REPLY_TOKEN } from "../../auto-reply/tokens.js";
import type { ReplyPayload } from "../../auto-reply/types.js";
import { createOutboundSendDeps, type CliDeps } from "../../cli/outbound-send-deps.js";
import type { OpenClawConfig } from "../../config/config.js";
import { resolveAgentMainSessionKey } from "../../config/sessions.js";
import { callGateway } from "../../gateway/call.js";
import { deliverOutboundPayloads } from "../../infra/outbound/deliver.js";
import { resolveAgentOutboundIdentity } from "../../infra/outbound/identity.js";
import { resolveOutboundSessionRoute } from "../../infra/outbound/outbound-session.js";
import { buildOutboundSessionContext } from "../../infra/outbound/session-context.js";
import { logWarn } from "../../logger.js";
import type { CronJob, CronRunTelemetry } from "../types.js";
import type { DeliveryTargetResolution } from "./delivery-target.js";
import { pickSummaryFromOutput } from "./helpers.js";
import type { RunCronAgentTurnResult } from "./run.js";
import {
  expectsSubagentFollowup,
  isLikelyInterimCronMessage,
  readDescendantSubagentFallbackReply,
  waitForDescendantSubagentSummary,
} from "./subagent-followup.js";

export function matchesMessagingToolDeliveryTarget(
  target: { provider?: string; to?: string; accountId?: string },
  delivery: { channel?: string; to?: string; accountId?: string },
): boolean {
  if (!delivery.channel || !delivery.to || !target.to) {
    return false;
  }
  const channel = delivery.channel.trim().toLowerCase();
  const provider = target.provider?.trim().toLowerCase();
  if (provider && provider !== "message" && provider !== channel) {
    return false;
  }
  if (target.accountId && delivery.accountId && target.accountId !== delivery.accountId) {
    return false;
  }
  // Strip :topic:NNN suffix from target.to before comparing — the cron delivery.to
  // is already stripped to chatId only, but the agent's message tool may pass a
  // topic-qualified target (e.g. "-1003597428309:topic:462").
  const normalizedTargetTo = target.to.replace(/:topic:\d+$/, "");
  return normalizedTargetTo === delivery.to;
}

export function resolveCronDeliveryBestEffort(job: CronJob): boolean {
  if (typeof job.delivery?.bestEffort === "boolean") {
    return job.delivery.bestEffort;
  }
  if (job.payload.kind === "agentTurn" && typeof job.payload.bestEffortDeliver === "boolean") {
    return job.payload.bestEffortDeliver;
  }
  return false;
}

async function resolveCronAnnounceSessionKey(params: {
  cfg: OpenClawConfig;
  agentId: string;
  fallbackSessionKey: string;
  delivery: {
    channel: NonNullable<DeliveryTargetResolution["channel"]>;
    to?: string;
    accountId?: string;
    threadId?: string | number;
  };
}): Promise<string> {
  const to = params.delivery.to?.trim();
  if (!to) {
    return params.fallbackSessionKey;
  }
  try {
    const route = await resolveOutboundSessionRoute({
      cfg: params.cfg,
      channel: params.delivery.channel,
      agentId: params.agentId,
      accountId: params.delivery.accountId,
      target: to,
      threadId: params.delivery.threadId,
    });
    const resolved = route?.sessionKey?.trim();
    if (resolved) {
      return resolved;
    }
  } catch {
    // Fall back to main session routing if announce session resolution fails.
  }
  return params.fallbackSessionKey;
}

export type SuccessfulDeliveryTarget = Extract<DeliveryTargetResolution, { ok: true }>;

type DispatchCronDeliveryParams = {
  cfg: OpenClawConfig;
  cfgWithAgentDefaults: OpenClawConfig;
  deps: CliDeps;
  job: CronJob;
  agentId: string;
  agentSessionKey: string;
  runSessionId: string;
  runStartedAt: number;
  runEndedAt: number;
  timeoutMs: number;
  resolvedDelivery: DeliveryTargetResolution;
  deliveryRequested: boolean;
  skipHeartbeatDelivery: boolean;
  skipMessagingToolDelivery: boolean;
  deliveryBestEffort: boolean;
  deliveryPayloadHasStructuredContent: boolean;
  deliveryPayloads: ReplyPayload[];
  synthesizedText?: string;
  summary?: string;
  outputText?: string;
  telemetry?: CronRunTelemetry;
  abortSignal?: AbortSignal;
  isAborted: () => boolean;
  abortReason: () => string;
  withRunSession: (
    result: Omit<RunCronAgentTurnResult, "sessionId" | "sessionKey">,
  ) => RunCronAgentTurnResult;
};

export type DispatchCronDeliveryState = {
  result?: RunCronAgentTurnResult;
  delivered: boolean;
  deliveryAttempted: boolean;
  summary?: string;
  outputText?: string;
  synthesizedText?: string;
  deliveryPayloads: ReplyPayload[];
};

export async function dispatchCronDelivery(
  params: DispatchCronDeliveryParams,
): Promise<DispatchCronDeliveryState> {
  let summary = params.summary;
  let outputText = params.outputText;
  let synthesizedText = params.synthesizedText;
  let deliveryPayloads = params.deliveryPayloads;

  // `true` means we confirmed at least one outbound send reached the target.
  // Keep this strict so timer fallback can safely decide whether to wake main.
  let delivered = params.skipMessagingToolDelivery;
  let deliveryAttempted = params.skipMessagingToolDelivery;
  const failDeliveryTarget = (error: string) =>
    params.withRunSession({
      status: "error",
      error,
      errorKind: "delivery-target",
      summary,
      outputText,
      deliveryAttempted,
      ...params.telemetry,
    });

  const deliverViaDirect = async (
    delivery: SuccessfulDeliveryTarget,
    options?: {
      preserveSuccessfulRunOnFailure?: boolean;
      synthesizedTextOnly?: boolean;
      sessionKey?: string;
      detachAbortAfterStart?: boolean;
    },
  ): Promise<RunCronAgentTurnResult | null> => {
    const identity = resolveAgentOutboundIdentity(params.cfgWithAgentDefaults, params.agentId);
    try {
      const payloadsForDelivery = options?.synthesizedTextOnly
        ? synthesizedText
          ? [{ text: synthesizedText }]
          : []
        : deliveryPayloads.length > 0
          ? deliveryPayloads
          : synthesizedText
            ? [{ text: synthesizedText }]
            : [];
      if (payloadsForDelivery.length === 0) {
        return null;
      }
      if (params.isAborted()) {
        return params.withRunSession({
          status: "error",
          error: params.abortReason(),
          deliveryAttempted,
          ...params.telemetry,
        });
      }
      deliveryAttempted = true;
      const deliverySession = buildOutboundSessionContext({
        cfg: params.cfgWithAgentDefaults,
        agentId: params.agentId,
        sessionKey: options?.sessionKey ?? params.agentSessionKey,
      });
      const deliveryResults = await deliverOutboundPayloads({
        cfg: params.cfgWithAgentDefaults,
        channel: delivery.channel,
        to: delivery.to,
        accountId: delivery.accountId,
        threadId: delivery.threadId,
        payloads: payloadsForDelivery,
        session: deliverySession,
        identity,
        bestEffort: params.deliveryBestEffort,
        deps: createOutboundSendDeps(params.deps),
        abortSignal: options?.detachAbortAfterStart ? undefined : params.abortSignal,
      });
      delivered = deliveryResults.length > 0;
      if (!delivered && options?.preserveSuccessfulRunOnFailure) {
        const message = "cron announce delivery failed";
        logWarn(`[cron:${params.job.id}] ${message}`);
        if (!params.deliveryBestEffort) {
          return params.withRunSession({
            status: "ok",
            summary,
            outputText,
            error: message,
            delivered: false,
            deliveryAttempted,
            ...params.telemetry,
          });
        }
      }
      return null;
    } catch (err) {
      if (options?.preserveSuccessfulRunOnFailure) {
        logWarn(`[cron:${params.job.id}] ${String(err)}`);
        if (!params.deliveryBestEffort) {
          return params.withRunSession({
            status: "ok",
            summary,
            outputText,
            error: String(err),
            delivered: false,
            deliveryAttempted,
            ...params.telemetry,
          });
        }
        return null;
      }
      if (!params.deliveryBestEffort) {
        return params.withRunSession({
          status: "error",
          summary,
          outputText,
          error: String(err),
          deliveryAttempted,
          ...params.telemetry,
        });
      }
      return null;
    }
  };

  const deliverViaAnnounce = async (
    delivery: SuccessfulDeliveryTarget,
  ): Promise<RunCronAgentTurnResult | null> => {
    if (!synthesizedText) {
      return null;
    }
    const initialSynthesizedText = synthesizedText.trim();
    let activeSubagentRuns = countActiveDescendantRuns(params.agentSessionKey);
    const expectedSubagentFollowup = expectsSubagentFollowup(initialSynthesizedText);
    const hadActiveDescendants = activeSubagentRuns > 0;
    if (activeSubagentRuns > 0 || expectedSubagentFollowup) {
      let finalReply = await waitForDescendantSubagentSummary({
        sessionKey: params.agentSessionKey,
        initialReply: initialSynthesizedText,
        timeoutMs: params.timeoutMs,
        observedActiveDescendants: activeSubagentRuns > 0 || expectedSubagentFollowup,
      });
      activeSubagentRuns = countActiveDescendantRuns(params.agentSessionKey);
      if (
        !finalReply &&
        activeSubagentRuns === 0 &&
        (hadActiveDescendants || expectedSubagentFollowup)
      ) {
        finalReply = await readDescendantSubagentFallbackReply({
          sessionKey: params.agentSessionKey,
          runStartedAt: params.runStartedAt,
        });
      }
      if (finalReply && activeSubagentRuns === 0) {
        outputText = finalReply;
        summary = pickSummaryFromOutput(finalReply) ?? summary;
        synthesizedText = finalReply;
        deliveryPayloads = [{ text: finalReply }];
      }
    }
    if (activeSubagentRuns > 0) {
      // Parent orchestration is still in progress; avoid announcing a partial
      // update to the main requester.
      return params.withRunSession({ status: "ok", summary, outputText, ...params.telemetry });
    }
    if (
      (hadActiveDescendants || expectedSubagentFollowup) &&
      synthesizedText.trim() === initialSynthesizedText &&
      isLikelyInterimCronMessage(initialSynthesizedText) &&
      initialSynthesizedText.toUpperCase() !== SILENT_REPLY_TOKEN.toUpperCase()
    ) {
      // Descendants existed but no post-orchestration synthesis arrived, so
      // suppress stale parent text like "on it, pulling everything together".
      return params.withRunSession({ status: "ok", summary, outputText, ...params.telemetry });
    }
    if (synthesizedText.toUpperCase() === SILENT_REPLY_TOKEN.toUpperCase()) {
      return params.withRunSession({
        status: "ok",
        summary,
        outputText,
        delivered: true,
        ...params.telemetry,
      });
    }
    // The isolated run already synthesized its user-ready final. Send that final
    // through the channel adapter directly instead of starting a second agent turn.
    // Preserve the destination conversation identity that the former announce path used.
    const announceMainSessionKey = resolveAgentMainSessionKey({
      cfg: params.cfg,
      agentId: params.agentId,
    });
    const announceSessionKey = await resolveCronAnnounceSessionKey({
      cfg: params.cfgWithAgentDefaults,
      agentId: params.agentId,
      fallbackSessionKey: announceMainSessionKey,
      delivery: {
        channel: delivery.channel,
        to: delivery.to,
        accountId: delivery.accountId,
        threadId: delivery.threadId,
      },
    });
    // Preserve the historical announce contract: delivery failure is reported
    // separately without changing an otherwise successful cron run to `error`.
    try {
      return await deliverViaDirect(delivery, {
        preserveSuccessfulRunOnFailure: true,
        synthesizedTextOnly: true,
        sessionKey: announceSessionKey,
        // Once the first chunk is attempted, finish this bounded provider send instead
        // of aborting between chunks and leaving a duplicate-prone partial delivery.
        detachAbortAfterStart: true,
      });
    } finally {
      // runSubagentAnnounceFlow previously owned session labeling and one-shot
      // cleanup. Keep both after the direct attempt (including failures) without
      // touching sessions whose delivery was deferred while descendants were active.
      if (deliveryAttempted) {
        const label = typeof params.job.name === "string" ? params.job.name.trim() : "";
        if (label) {
          try {
            await callGateway({
              method: "sessions.patch",
              params: { key: params.agentSessionKey, label },
              timeoutMs: 10_000,
            });
          } catch {
            // Best-effort labeling, matching the former announce flow.
          }
        }
        if (params.job.deleteAfterRun && countPendingDescendantRuns(params.agentSessionKey) === 0) {
          try {
            await callGateway({
              method: "sessions.delete",
              params: {
                key: params.agentSessionKey,
                deleteTranscript: true,
                emitLifecycleHooks: false,
              },
              timeoutMs: 10_000,
            });
          } catch {
            // Best-effort cleanup, matching the former announce flow.
          }
        }
      }
    }
  };

  if (
    params.deliveryRequested &&
    !params.skipHeartbeatDelivery &&
    !params.skipMessagingToolDelivery
  ) {
    if (!params.resolvedDelivery.ok) {
      if (!params.deliveryBestEffort) {
        return {
          result: failDeliveryTarget(params.resolvedDelivery.error.message),
          delivered,
          deliveryAttempted,
          summary,
          outputText,
          synthesizedText,
          deliveryPayloads,
        };
      }
      logWarn(`[cron:${params.job.id}] ${params.resolvedDelivery.error.message}`);
      return {
        result: params.withRunSession({
          status: "ok",
          summary,
          outputText,
          deliveryAttempted,
          ...params.telemetry,
        }),
        delivered,
        deliveryAttempted,
        summary,
        outputText,
        synthesizedText,
        deliveryPayloads,
      };
    }

    // Structured payloads must retain media/channel data. Existing thread-bound
    // delivery also stays on its direct path. Other text-only announce output
    // first runs the descendant/interim/silent guards, then sends the already-final
    // synthesized text through the same direct outbound adapter.
    const useDirectDelivery =
      params.deliveryPayloadHasStructuredContent || params.resolvedDelivery.threadId != null;
    if (useDirectDelivery) {
      const directResult = await deliverViaDirect(params.resolvedDelivery);
      if (directResult) {
        return {
          result: directResult,
          delivered,
          deliveryAttempted,
          summary,
          outputText,
          synthesizedText,
          deliveryPayloads,
        };
      }
    } else {
      const announceResult = await deliverViaAnnounce(params.resolvedDelivery);
      if (announceResult) {
        return {
          result: announceResult,
          delivered,
          deliveryAttempted,
          summary,
          outputText,
          synthesizedText,
          deliveryPayloads,
        };
      }
    }
  }

  return {
    delivered,
    deliveryAttempted,
    summary,
    outputText,
    synthesizedText,
    deliveryPayloads,
  };
}
