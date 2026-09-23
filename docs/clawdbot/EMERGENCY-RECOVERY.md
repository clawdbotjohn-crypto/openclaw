# Emergency recovery: Clawdbot is dark

**Owner guide for John. This is the single authoritative maintenance/emergency route.** Recovery is not permission to update. Do not run `npm install -g`, `openclaw update`, the candidate installer, a deployment workflow, or a manual package-replacement fallback.

## Numbered owner-safe route

1. **Connect only to the current Pi Tailnet identity.** On the laptop, connect Tailscale and run:

   ```bash
   ssh john@clawdbot-pi-1.tail400409.ts.net
   ```

   If current MagicDNS resolution fails, use the current address:

   ```bash
   ssh john@100.126.230.66
   ```

   **Warning:** the former Tailnet name `clawdbot-pi` and its former peer/address are stale/expired. Do not use, trust, or revive that old Tailnet node. The Pi's local shell hostname may still print `clawdbot-pi`; that is not the stale Tailnet identity.

   If neither current route reaches the expected Pi, stop this procedure and go to step 7. Do not accept an unexpected host key or operate on a different machine.

2. **Collect read-only triage.** From the fork checkout:

   ```bash
   cd ~/.openclaw/workspace/projects/openclaw-fork
   hostname
   systemctl --user is-active openclaw-gateway.service
   systemctl --user status openclaw-gateway.service --no-pager -n 30
   journalctl --user -u openclaw-gateway.service -n 80 --no-pager
   scripts/clawdbot/smoke-test.sh --binary "$(command -v openclaw)" --gateway
   ```

   The smoke script uses the supported WebSocket RPC command `openclaw health --json --timeout …`, parses the JSON, and requires healthy structured fields including `ok: true`; an HTTP 200 or CLI exit code alone is not accepted.

3. **Choose exactly one recovery class from evidence.**
   - Journal explicitly reports invalid JSON, invalid/unknown config key, or config/schema loading failure: continue to step 4.
   - Config parses, but journal reports missing/corrupt package files, imports, syntax, or failure to execute OpenClaw: continue to step 5.
   - SSH/current Tailnet route fails or the Pi does not respond: continue to step 7.
   - Anything else, mixed evidence, filesystem/I/O errors, permissions, repeated OOM, or uncertainty: **stop and escalate**. Preserve step 2 output; do not guess.

4. **Config-only recovery.** First validate both files:

   ```bash
   ls -l ~/.openclaw/openclaw.json ~/.openclaw/watchdog/known-good.json
   jq empty ~/.openclaw/openclaw.json
   jq empty ~/.openclaw/watchdog/known-good.json
   ```

   If either known-good check fails, **stop and escalate**. Otherwise preserve the failed config, restore the known-good config, and restart once:

   ```bash
   stamp=$(date -u +%Y%m%dT%H%M%SZ)
   cp ~/.openclaw/openclaw.json ~/.openclaw/openclaw.json.failed-$stamp
   cp ~/.openclaw/watchdog/known-good.json ~/.openclaw/openclaw.json
   systemctl --user restart openclaw-gateway.service
   ```

   Wait 15 seconds and continue to step 6. Do not hand-edit JSON during an outage.

5. **Runtime/package recovery.** Use only the reviewed transactional script:

   ```bash
   cd ~/.openclaw/workspace/projects/openclaw-fork
   scripts/clawdbot/rollback-runtime.sh \
     --archive ~/.openclaw/releases/current-good.tgz \
     --yes
   ```

   The script fails closed on missing/malformed/ambiguous/mismatched checksums, shares a lock with backup/install, preserves the exact prior runtime and running/stopped state, and only reports success after active-path and required structured-health verification. If it reports any failure, **stop and escalate**. Do not extract, rename, symlink, or replace the package manually. Do not use `install-candidate.sh` as disaster recovery.

6. **Run final verification and stop on any failure.**

   ```bash
   cd ~/.openclaw/workspace/projects/openclaw-fork
   systemctl --user is-active openclaw-gateway.service
   scripts/clawdbot/smoke-test.sh --binary "$(command -v openclaw)" --gateway
   ss -ltn | grep -E '127\.0\.0\.1:18789|\[::1\]:18789'
   python3 ~/.openclaw/workspace/scripts/gateway_watchdog.py --status
   ```

   Required results are `active`, a parsed structured RPC health response with `ok: true`, a loopback listener, and no pending watchdog recovery. Then send one harmless bot message. Do not run an update because recovery succeeded.

   **Known external blocker:** the live watchdog source is outside this repository at `~/.openclaw/workspace/scripts/gateway_watchdog.py`. As reviewed on 2026-09-22, lines 136–144 still use the unsupported plain HTTP health route and even treat an active process as healthy when that request fails. This PR intentionally does not edit or apply that live external file. Therefore watchdog status is supplemental only and cannot satisfy the structured-health gate; correcting and separately deploying the watchdog remains an owner-reviewed blocker.

7. **Whole-Pi/current-Tailnet failure.** On the laptop:

   ```bash
   tailscale status
   tailscale ping clawdbot-pi-1.tail400409.ts.net
   ssh john@clawdbot-pi-1.tail400409.ts.net
   # Current numeric fallback only:
   ssh john@100.126.230.66
   ```

   If current Tailnet access still fails, confirm power and Ethernet/Wi-Fi. With physical monitor/keyboard access, inspect only:

   ```bash
   hostname
   ip address
   systemctl status tailscaled --no-pager
   systemctl --user status openclaw-gateway.service --no-pager
   ```

   If the OS is healthy and only Tailscale is inactive, John may restart Tailscale once. If the OS is responsive but generally wedged, John may perform one clean reboot, wait 2–3 minutes, and return to step 1. Do not repeatedly power-cycle, reimage, reinstall OpenClaw, change Tailnet nodes, or improvise around filesystem/read-only/I/O errors.

## Absolute stop/escalation conditions

Stop immediately and preserve logs if:

- the current FQDN/address reaches an unexpected host or host key;
- config LKG, runtime archive, or exact checksum validation fails;
- transactional rollback or final structured health fails;
- recovery would require credentials, safeguard changes, systemd installation changes, Tailnet mutation, or manual package replacement;
- the evidence does not select exactly one route above.

Get a second review before any further mutation.
