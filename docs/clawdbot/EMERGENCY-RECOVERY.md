# Emergency recovery: Clawdbot is dark

**Owner guide for John. Start here when the bot/Gateway cannot answer.** This is recovery only—not an update procedure. Do not run `npm install -g`, `openclaw update`, a candidate installer, or any GitHub deployment workflow.

## Emergency checklist (do this first)

1. From your laptop, connect to Tailscale and open PowerShell/Terminal.
2. SSH to the Pi:

   ```bash
   ssh john@clawdbot-pi
   ```

   If name resolution fails, use the **currently verified 2026-09-22** Tailscale address (it may become stale):

   ```bash
   ssh john@100.126.230.66
   ```

   Expected: a shell prompt on host `clawdbot-pi`. SSH asks for host-key confirmation only on a first connection; it must not show a different hostname unexpectedly.

3. Run this read-only triage block:

   ```bash
   hostname
   systemctl --user is-active openclaw-gateway.service
   systemctl --user status openclaw-gateway.service --no-pager -n 30
   curl --fail --silent --show-error --max-time 5 http://127.0.0.1:18789/healthz
   journalctl --user -u openclaw-gateway.service -n 80 --no-pager
   ```

   Healthy expected results:
   - hostname: `clawdbot-pi`
   - service: `active`
   - health: `{"ok":true,"status":"live"}` (extra fields are okay)

4. Choose exactly one path below:
   - explicit JSON/schema/config errors → **Config failure**
   - missing/corrupt OpenClaw files, import/syntax/startup errors with valid config → **Runtime failure**
   - no SSH or Pi does not respond → **Whole-Pi/network failure**
5. Run the final verification block. If it does not pass, **stop rather than improvising**.

Current ports verified 2026-09-22: Gateway `18789` on Pi loopback; browser relay `18792` on Pi loopback. They are not public listeners. For the laptop browser extension, keep this separate tunnel open: `ssh -L 18792:127.0.0.1:18792 john@clawdbot-pi`.

## Path A — Config failure

Use this path only when the journal explicitly reports invalid JSON, an unknown/invalid config key, or a config/schema load failure. First verify the recovery file exists:

```bash
ls -l ~/.openclaw/openclaw.json ~/.openclaw/watchdog/known-good.json
jq empty ~/.openclaw/watchdog/known-good.json
```

Expected: both files exist and `jq empty` exits silently with status 0. Then preserve the failed config, restore the watchdog's last-known-good copy, and restart only the Gateway:

```bash
stamp=$(date -u +%Y%m%dT%H%M%SZ)
cp ~/.openclaw/openclaw.json ~/.openclaw/openclaw.json.failed-$stamp
cp ~/.openclaw/watchdog/known-good.json ~/.openclaw/openclaw.json
systemctl --user restart openclaw-gateway.service
```

Wait 15 seconds, then run the final verification block below. Do not hand-edit JSON during an outage. If `known-good.json` is absent/invalid, stop.

## Path B — Runtime/package failure

Use this path only when config parses successfully but the service journal shows missing package files, module/import errors, syntax errors, or failure to execute OpenClaw.

Verify the known-good archive and checksum before changing anything:

```bash
cd ~/.openclaw/workspace/projects/openclaw-fork
ls -l ~/.openclaw/releases/current-good.tgz ~/.openclaw/releases/current-good.tgz.sha256
expected=$(awk 'NF {print $1; exit}' ~/.openclaw/releases/current-good.tgz.sha256)
actual=$(sha256sum ~/.openclaw/releases/current-good.tgz | awk '{print $1}')
printf 'expected=%s\nactual=%s\n' "$expected" "$actual"
test "$expected" = "$actual" && echo 'checksum: PASS'
```

Expected: `checksum: PASS`. Then invoke the reviewed **manual disaster-recovery** script:

```bash
scripts/clawdbot/rollback-runtime.sh \
  --archive ~/.openclaw/releases/current-good.tgz \
  --yes
```

The script preserves the failed runtime, restores the archive, starts the user Gateway, and performs its checks. Expected final line: `Rollback succeeded.`

This manual recovery is different from `install-candidate.sh` automatic rollback. The installer handles an unhealthy candidate during a separately approved install; do **not** use it in an outage.

## Path C — Whole-Pi or network failure

### C1. Check Tailscale from the laptop

```bash
tailscale status
tailscale ping clawdbot-pi
```

Expected: Tailscale is connected and the ping resolves `clawdbot-pi`. Then retry:

```bash
ssh john@clawdbot-pi
```

If Tailscale is connected but the name does not resolve, retry the currently verified address:

```bash
ssh john@100.126.230.66
```

### C2. If SSH still fails

1. Confirm the Pi has power and its Ethernet/Wi-Fi network is available.
2. If possible, attach a monitor/keyboard and log in locally. Confirm the machine identity:

   ```bash
   hostname
   ip address
   systemctl status tailscaled --no-pager
   systemctl --user status openclaw-gateway.service --no-pager
   ```

3. If the OS works locally and only Tailscale is inactive, John may restart Tailscale once:

   ```bash
   sudo systemctl restart tailscaled
   tailscale status
   ```

4. If the OS works but remains generally wedged, perform one clean reboot:

   ```bash
   sudo reboot
   ```

   Wait 2–3 minutes, reconnect with SSH, and return to the emergency checklist.

Do not repeatedly power-cycle the Pi. If it does not boot, reports filesystem/I/O errors, mounts storage read-only, or the host is not clearly `clawdbot-pi`, stop and diagnose the hardware/storage/network with physical access. Do not reimage the SD card or reinstall OpenClaw as an emergency guess.

## Final verification

Run after any recovery:

```bash
systemctl --user is-active openclaw-gateway.service
curl --fail --silent --show-error --max-time 5 http://127.0.0.1:18789/healthz
ss -ltn | grep -E '127\.0\.0\.1:18789|\[::1\]:18789'
python3 ~/.openclaw/workspace/scripts/gateway_watchdog.py --status
```

Expected:

- `active`
- health JSON with `"ok":true`
- at least one loopback listener on port `18789`
- watchdog status reports healthy/no pending recovery

Then send the bot a harmless message. Do not run upgrades just because recovery succeeded.

## Stop—do not improvise—if any of these are true

- A command resolves to a host other than `clawdbot-pi`.
- The known-good config or runtime archive is missing, invalid, or fails checksum.
- The rollback script reports failure or the final health check still fails.
- Logs show filesystem, SD-card, permission, or repeated out-of-memory failures.
- Recovery would require editing credentials, disabling safeguards, changing systemd installation, or replacing the live package manually.
- You are unsure whether a path is config-only or runtime-only.

Preserve the output of `systemctl status` and `journalctl`; get a second review before any further mutation.
