# Clawdbot Patch Manifest

This document tracks downstream behavior that must survive a future switch from the
stock global OpenClaw installation to this maintenance fork.

## Live runtime baseline

- OpenClaw: `2026.3.2`
- `@mariozechner/pi-ai`: `0.55.3`
- Fork base: upstream tag `v2026.3.2`
- Fork branch: `clawdbot-stable`

The live Raspberry Pi remains on its existing global installation until John explicitly
approves a swap.

## Active live modifications

### GitHub Copilot model catalog additions

The installed `pi-ai/dist/models.generated.js` currently contains manual catalog
entries for:

- `github-copilot/gpt-5.6-sol`
- `github-copilot/claude-opus-4.8`

These entries make the pinned runtime recognize model IDs that are advertised by the
authenticated GitHub Copilot model endpoint. A pristine reinstall of OpenClaw
`2026.3.2` resolves `pi-ai` from the package registry and erases these generated-file
edits. Because Sol is the current primary model, a pristine live reinstall is not a
no-op.

Before a fork package can replace the live installation, equivalent behavior must be
implemented reproducibly and tested. Preferred options, in order:

1. A maintained model/provider implementation in source.
2. A pinned, tested `pi-ai` fork or package override.
3. A version-controlled package patch applied during the build.

Do not blindly copy generated JavaScript into the fork.

## Historical patches requiring re-verification

These patches solved real problems, but their need and implementation must be checked
against the pinned source before porting:

- **Callback-loop protection:** prevented duplicate subagent completion announcements
  from repeatedly waking a parent session. Not detected in the current installed
  bundles during the September 2026 audit. Reproduce the original failure before
  porting.
- **SearXNG provider:** added local SearXNG search support. The local service still
  exists, but OpenClaw currently uses Brave search and the old bundle patch is absent.
  Port only if local search is deliberately restored.
- **DuckDuckGo provider:** experimental HTML scraping was unreliable because of
  CAPTCHA responses. Treat as retired unless requirements change.
- **Cron wake-race fix:** changed scheduling order so overdue jobs run before the next
  wake is recomputed. The issue was fixed upstream in February 2026; verify that the
  pinned source contains the upstream fix before adding anything.

## Model request compatibility

Catalog recognition and request compatibility are separate. Adding a model ID does not
necessarily implement its required reasoning/request format. In particular, newer
Anthropic models may require adaptive thinking rather than legacy budget-style
`thinking.type=enabled`. Every model port needs basic tool-call and configured-reasoning
probes before it is used in routing.

## Update rule

Every downstream change should be:

1. A focused commit.
2. Covered by a build or regression test where practical.
3. Listed here with its upstream status.
4. Removed when an equivalent upstream fix is intentionally adopted.
