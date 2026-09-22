# Clawdbot OpenClaw Maintenance Runbook

## Safety boundary

The Raspberry Pi stays on the current global OpenClaw installation until John explicitly
approves a live swap. Building, testing, or merging this fork does not authorize an
installation, Gateway restart, or production deployment.

## Branches and releases

- `clawdbot-stable`: reviewed, buildable maintenance baseline.
- Feature branches: one downstream change per branch where practical.
- `upstream`: `https://github.com/openclaw/openclaw.git`.
- `origin`: `https://github.com/clawdbotjohn-crypto/openclaw.git`.

Upstream changes are reviewed and selectively cherry-picked. Do not automatically merge
or rebase the stable branch onto upstream.

## Three independent recovery paths

1. **Configuration:** the Pi's daily cleanup saves primary and previous LKG configs.
   `gateway-watchdog.timer` checks every 10 minutes and restores config after three
   consecutive failures.
2. **Binary/runtime:** `backup-runtime.sh` preserves the complete working global package,
   including patched dependencies. `rollback-runtime.sh` restores that archive.
3. **Models:** catalog/deprecation reconciliation is separate. Binary or config rollback
   must not be treated as model lifecycle management.

## Candidate process

1. Update `patch-manifest.md`.
2. Push a focused branch.
3. Run **Clawdbot fork package build** in GitHub Actions.
4. Download and verify the tarball and SHA-256 file.
5. Test the artifact in an isolated prefix/config. Do not point it at live state.
6. Before any approved live installation, run:

   ```bash
   cd ~/.openclaw/workspace/projects/openclaw-fork
   scripts/clawdbot/backup-runtime.sh --yes
   ```

7. Record the archive path and checksum.
8. Only after John's explicit approval, use a separately reviewed candidate installer.
   This repository intentionally does not include an automatic live installer yet.

## Normal health checks

```bash
systemctl --user status openclaw-gateway.service --no-pager
systemctl --user status gateway-watchdog.timer --no-pager
python3 ~/.openclaw/workspace/scripts/gateway_watchdog.py --status
```

## Config-only emergency recovery

Normally the watchdog handles this within about 30 minutes. Manual recovery:

```bash
ssh john@clawdbot-pi
cp ~/.openclaw/watchdog/known-good.json ~/.openclaw/openclaw.json
systemctl --user restart openclaw-gateway.service
systemctl --user status openclaw-gateway.service --no-pager
```

## Binary/runtime emergency recovery

Use this when the OpenClaw package itself is damaged or a fork candidate cannot start:

```bash
ssh john@clawdbot-pi
cd ~/.openclaw/workspace/projects/openclaw-fork
scripts/clawdbot/rollback-runtime.sh --archive ~/.openclaw/releases/current-good.tgz --yes
```

The rollback script stops the Gateway, preserves the failed runtime, restores the
archive, starts the Gateway, and checks service health. It automatically puts the
pre-rollback runtime back if the restored archive fails its basic checks.

If the helper script itself cannot run:

```bash
systemctl --user stop openclaw-gateway.service
# Do not delete the current runtime. Rename it and extract the known-good archive.
mv ~/.npm-global/lib/node_modules/openclaw \
  ~/.npm-global/lib/node_modules/openclaw.failed.$(date +%Y%m%d-%H%M%S)
mkdir -p ~/.npm-global/lib/node_modules

tar -xzf ~/.openclaw/releases/current-good.tgz \
  -C ~/.npm-global/lib/node_modules
ln -sfn ../lib/node_modules/openclaw/openclaw.mjs ~/.npm-global/bin/openclaw
systemctl --user start openclaw-gateway.service
```

## Failure modes

- **Gateway rejects config:** use config LKG; no binary change is required.
- **Gateway executable does not start:** use runtime rollback.
- **Model is missing/deprecated:** use model reconciliation; do not roll back a healthy
  Gateway merely to restore an obsolete model.
- **Fork package omits a monkey patch:** roll back runtime, then implement the behavior as
  a tested fork commit.
- **Upstream cherry-pick conflicts:** stop and resolve on a feature branch. Never repair
  the live global package in place during an update.
- **Discord is unavailable:** SSH remains the control path; this runbook is also stored
  on GitHub.
