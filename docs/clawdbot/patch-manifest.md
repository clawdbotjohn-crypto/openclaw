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

### Authenticated GitHub Copilot live model discovery

**Downstream implementation:** `clawdbot/copilot-live-model-discovery` semantically backports
current upstream authenticated `GET {baseUrl}/models` discovery to the older v2026.3.2
registry/runtime seams. It reuses the existing GitHub-token-to-Copilot-token exchange and the
API base URL returned by that exchange. Account-visible, picker-enabled chat models with proven
tool-call support are normalized in memory and shared by the model catalog, `models list`, and
runtime resolution. The 30-second process cache is isolated by a hash of the source account token
and normalized base URL, coalesces concurrent requests, and retains the last successful snapshot
on transient failures. Requests identify as the same pinned VS Code Copilot Chat client used by
pi-ai (`User-Agent`, editor/plugin version, and integration ID) for both discovery and inference;
the real endpoint returns HTTP 400 without those compatibility headers. A successful 200 response is authoritative, including an
empty/removal response. Short-lived bearers and discovered definitions are never written to config or
`models.json`; `agents.defaults.models` remains an operator allowlist.

**Upstream references:** semantic backport of OpenClaw commit
`eb20f68c1e96309a76a05c124be1c93db85804a3`, especially
`extensions/github-copilot/models.ts`, `dynamic-models.ts`, `model-metadata.ts`, and
`src/plugin-sdk/provider-catalog-shared.ts`. This is intentionally not a cherry-pick because the
pinned release predates provider plugins and live provider-catalog infrastructure.

**Scope boundary:** this patch does not update `pi-ai`, generated models, or implement newer
Claude adaptive-thinking/request behavior. Discovery only claims metadata supported by the live
response and conservative transport-family mapping.

**Rollback:** revert the focused live-discovery commit. The bundled v2026.3.2 registry remains the
fallback, and no user files require migration or cleanup.

**Verification evidence:**

- `pnpm exec vitest run src/providers/github-copilot-model-discovery.test.ts src/providers/github-copilot-model-discovery.profile.test.ts src/agents/model-catalog.copilot.test.ts src/commands/models/list.registry.copilot.test.ts src/agents/pi-embedded-runner/model.test.ts` — 5 files, 29 tests passed.
- `pnpm exec vitest run src/agents/pi-embedded-runner/model.forward-compat.test.ts` — 1 file, 6 tests passed.
- `pnpm exec oxlint <12 touched TypeScript files>` — 0 warnings, 0 errors; `pnpm exec oxfmt --write <touched files>` and `git diff --check` passed.
- `pnpm exec tsdown` — build passed (312-file and 321-file bundles completed in about 10 seconds each; only existing dynamic-import/plugin-timing warnings).
- `pnpm exec tsgo --pretty false` reached only four pre-existing Feishu extension errors (`botName`, `PluginHookRunner`, missing `config/sessions/types.js`, and an implicit-any `trigger`); it reported no errors in touched files.

**Retirement criteria:** remove this patch once the fork deliberately upgrades to an upstream
release containing authenticated Copilot provider-catalog discovery plus runtime execution wiring,
and equivalent account isolation, stale/error semantics, removal behavior, and focused tests pass
without the downstream shim.

### Staged candidate installer and portable build checksum

**Downstream implementation:** `scripts/clawdbot/install-candidate.sh` fails closed on an exact,
single-record tarball checksum and exact `build-metadata.txt` repository/promotable branch ref/
post-merge SHA/push event/tarball checksum. Pull refs and PR artifacts are not promotable. It
copies the artifact, checksum, and provenance into a private transaction-owned snapshot, validates
that snapshot's package shape and isolated CLI execution, and passes only the snapshot to npm. The
same runtime lock is shared with backup and manual rollback; rollback likewise validates, lists, and
extracts only a private archive snapshot. Archive listing is captured to a private file and its producer
exit status must succeed before any entry is trusted. Service state is tri-state and fail-closed: an exact
`LoadState=loaded` proof plus exact `active`/0 or `inactive`/3 is required; failed, transitioning,
unknown, malformed, timeout, permission, and query-error states abort before mutation.

Promotable backup health is cryptographically/tree bound rather than caller-asserted: the supplied CLI
must canonically resolve to the selected runtime's own entrypoint, a stable private snapshot is made,
the executable inside that exact snapshot performs parsed `openclaw health --json` WebSocket RPC,
and pre/post tree digests reject mutation before that tree is archived. Known-good promotion uses a
private journal, exact copies of every old pointer type/absence, atomic renames, and an atomic commit
marker. Pre-commit ERR/INT/TERM/EXIT recovery is reconciled from filesystem/journal state; restore
failure retains the complete journal and fails loudly. Installer and rollback use exclusive 0700
transaction directories for staged/previous/failed/recovery paths and retain recovery material when
service stop/start restoration cannot be proven. The installer is validation-only by default; mutation
requires `--apply --yes`, and the active global target also requires `--allow-live-runtime`. Promotion
remains post-merge.

**Tests:** `scripts/clawdbot/tests/install-candidate.test.sh` runs 197 isolated fake-environment
cases: every applicable running and stopped installer/rollback mutation boundary crossed with
ERR/INT/TERM/EXIT; exact runtime content/inode/path, pointer bytes/link/absence, lock, and service
state assertions; active/inactive and every fail-closed service-state class; stop/start and
recovery-stop/recovery-start failure; same-runtime and A-vs-B health binding, aliases, symlink escape,
and source mutation; private collision-proof transactions and unsafe temporary-parent rejection; producer-failing plausible archive lists;
and immediately-before/immediately-after every pointer rename, restore failure, repeated recovery
signals, and post-commit reconciliation. Checksum/provenance and structured-health gates remain
covered. Fake `systemctl`, npm, CLI, archive tools, and `/tmp` directories prevent tests from reaching
live state.

**Rollback:** revert the installer/workflow commit. This does not alter package runtime behavior,
config schema, or user state. For an operational outage, use only the independent transactional
`rollback-runtime.sh` owner route in `EMERGENCY-RECOVERY.md`; never perform manual package
replacement.

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
probes before it is used in routing. The pinned pi-ai 0.55.3 handling and exact Claude Opus 4.8
follow-up are documented in `claude-adaptive-thinking-follow-up.md`; it is separate from and does
not block the OpenAI-responses-based Sol promotion.

## Update rule

Every downstream change should be:

1. A focused commit.
2. Covered by a build or regression test where practical.
3. Listed here with its upstream status.
4. Removed when an equivalent upstream fix is intentionally adopted.
