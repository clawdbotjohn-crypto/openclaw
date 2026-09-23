# Claude 4.8 adaptive-thinking follow-up

Status: separate follow-up; **not a blocker for `github-copilot/gpt-5.6-sol` promotion**.

## Evidence in the pinned runtime

The fork pins `@mariozechner/pi-ai` 0.55.3. Its Anthropic provider recognizes adaptive thinking only when a model ID contains `opus-4-6`, `opus-4.6`, `sonnet-4-6`, or `sonnet-4.6` (`dist/providers/anthropic.js`, `supportsAdaptiveThinking`).

Runtime Copilot discovery correctly maps `claude-opus-4.8` to `anthropic-messages` with `reasoning: true`. With any non-off OpenClaw thinking level, pi-ai therefore treats 4.8 as an older budget-thinking model and emits the legacy payload:

```json
{ "thinking": { "type": "enabled", "budget_tokens": 1024 } }
```

It can also add the old `interleaved-thinking-2025-05-14` beta header. That is the exact compatibility surface previously avoided by suppressing explicit thinking/reasoning for this model. The Sol path is different (`openai-responses`) and does not execute this Anthropic provider code.

## Decision

Do not add an OpenClaw-side heuristic or patch generated `node_modules` in the staged-installer PR. Correct handling belongs in the pinned pi-ai provider, and a 4.8 rule should not be guessed without an authenticated request proving the endpoint's contract. Keep Claude 4.8 thinking off until the follow-up is verified.

## Exact follow-up

1. Prefer upgrading pi-ai to a release that explicitly recognizes Claude Opus 4.8 adaptive thinking. If no such release exists, create a pnpm patch against pi-ai's Anthropic provider source rather than modifying installed output by hand.
2. Add provider-level request-capture tests for `github-copilot/claude-opus-4.8`:
   - thinking `off`: no `thinking`, no `output_config`, and no interleaved-thinking beta;
   - thinking `high`: `thinking: {type: "adaptive"}`, `output_config: {effort: "high"}`, and no interleaved-thinking beta;
   - no `budget_tokens` for 4.8.
3. Run one isolated authenticated Copilot request with thinking off, then one with thinking high. Capture only status/payload shape—never tokens.
4. Only after both requests pass, remove any model-specific live suppression in a separately reviewed promotion.
