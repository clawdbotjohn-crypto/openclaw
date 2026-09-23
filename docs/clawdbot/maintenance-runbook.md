# Clawdbot OpenClaw maintenance runbook

> **Gateway dark, degraded, or recovery needed?** Do not use update instructions on this page. Follow the one numbered owner route in **[Emergency recovery: Clawdbot is dark](./EMERGENCY-RECOVERY.md)**. It contains the sole config/runtime/network recovery procedure and explicit stop/escalation conditions. There is intentionally no manual package-replacement fallback.

## Safety boundary

The Raspberry Pi stays on its current global OpenClaw installation until John explicitly approves a live swap. Building, testing, opening, or merging a PR does not authorize installation, Gateway restart, deployment, live config mutation, watchdog deployment, or Tailnet changes.

Current remote access is `clawdbot-pi-1.tail400409.ts.net` with numeric fallback `100.126.230.66`. **The old Tailnet name `clawdbot-pi` and old peer/address are stale/expired; never use or revive them.**

## Branches and recovery assets

- `clawdbot-stable`: reviewed maintenance baseline.
- Feature branches: one downstream change per branch where practical.
- `upstream`: `https://github.com/openclaw/openclaw.git`.
- `origin`: `https://github.com/clawdbotjohn-crypto/openclaw.git`.
- Config recovery, complete runtime archives, and model reconciliation are independent. Never treat binary/config rollback as model lifecycle management.

Review and selectively cherry-pick upstream changes. Do not automatically merge/rebase stable onto upstream.

## Post-merge candidate process

1. Update `patch-manifest.md` and push a focused feature branch.
2. Let PR CI run isolated package, installer, rollback, signal/failure, checksum, and provenance tests. PR artifacts are **not promotable** because their event/ref/SHA may describe `refs/pull/*` or a synthetic GitHub merge commit.
3. Obtain review and merge to `clawdbot-stable`. Promotion is post-merge only.
4. Let the no-publish workflow build fresh from the exact `refs/heads/clawdbot-stable` push SHA. It has read-only contents permission and no `workflow_dispatch`, publish, deploy, or live mutation path.
5. Download the tarball, its exact `.sha256`, and matching `build-metadata.txt`. Record the exact repository, branch ref, and merged 40-character SHA expected for promotion.
6. Run a validation-only plan (no files/services changed):

   ```bash
   scripts/clawdbot/install-candidate.sh \
     --artifact /path/to/openclaw-YYYY.M.D.tgz \
     --checksum /path/to/openclaw-YYYY.M.D.tgz.sha256 \
     --metadata /path/to/build-metadata.txt \
     --expected-repository clawdbotjohn-crypto/openclaw \
     --expected-ref refs/heads/clawdbot-stable \
     --expected-sha <exact-post-merge-40-character-sha>
   ```

   The installer fails closed on missing/malformed/ambiguous checksums; mismatched repository/ref/SHA/package checksum; pull refs; non-push events; and synthetic PR artifacts.

7. Test the artifact only in an isolated prefix/config. Do not point it at live state.
8. Stop. A live attempt requires John's explicit approval, no active worker, and a second review of the exact artifact/SHA. Only the approved operator may add all mutation gates: `--apply --yes --allow-live-runtime`.
9. During an approved apply, installer/backup/manual rollback share one lock. Service state is fail-closed: the scripts separately prove `LoadState=loaded` and accept only exact `active`/0 or exact `inactive`/3 (`stopped`/3 compatibility). `failed`, `activating`, `deactivating`, unknown units, malformed output, timeout, D-Bus/permission/query errors, and all mismatches abort before runtime mutation. A service that began explicitly stopped stays stopped and existing known-good pointers are preserved.
10. A promotable backup first proves that the supplied health CLI canonically resolves to the selected runtime's own `openclaw.mjs`, takes a private stable snapshot, probes structured `openclaw health --json` through the executable inside that snapshot, proves the snapshot did not mutate, and archives that exact tree. A CLI from runtime B cannot promote an archive of runtime A. There is no arbitrary custom-health-command promotion path.
11. Known-good pointer replacement is a journaled multi-pointer transaction with atomic per-pointer rename and a commit marker. Any ERR/INT/TERM/unexpected EXIT before commit restores every prior symlink, regular file, or absence from retained copies. Failed restore is loud and retains the complete private recovery journal. Installer/rollback recovery likewise restores the exact prior runtime inode/path/bytes and prior active/inactive state; if service stop/start recovery cannot be proven, it retains the private transaction for escalation. On any recovery warning or failure, stop and follow the owner recovery route—never perform package surgery.

## Supported structured health check

```bash
cd ~/.openclaw/workspace/projects/openclaw-fork
systemctl --user status openclaw-gateway.service --no-pager
scripts/clawdbot/smoke-test.sh --binary "$(command -v openclaw)" --gateway
```

The smoke script invokes the supported WebSocket RPC command `openclaw health --json --timeout …`, parses JSON, and requires stable healthy content (`ok: true` plus timestamp/duration, channels/order/labels, agent, and sessions structures). HTTP success is not a health gate.

The live watchdog is an unresolved external blocker: `~/.openclaw/workspace/scripts/gateway_watchdog.py` is outside this repository and still uses a plain HTTP request with process-only fallback. This PR does not touch or deploy it. Until separately corrected and owner-reviewed, watchdog status is supplemental and cannot replace the structured probe.

## Failure routing

- Invalid config/schema evidence: use only config path in the owner recovery route.
- Runtime/import/entrypoint evidence with valid config: use only transactional manual rollback in that route.
- Missing/deprecated model: use model reconciliation; do not roll back a healthy Gateway.
- Upstream conflict or omitted downstream behavior: fix and review on a branch; never repair the live package in place.
- SSH/Tailnet outage: use only the current FQDN/current IP route; do not alter Tailnet nodes.
