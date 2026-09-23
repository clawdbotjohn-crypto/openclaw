#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
required=(
  ".github/workflows/clawdbot-build.yml"
  "docs/clawdbot/EMERGENCY-RECOVERY.md"
  "docs/clawdbot/maintenance-runbook.md"
  "docs/clawdbot/patch-manifest.md"
  "scripts/clawdbot/runtime-common.sh"
  "scripts/clawdbot/backup-runtime.sh"
  "scripts/clawdbot/install-candidate.sh"
  "scripts/clawdbot/rollback-runtime.sh"
  "scripts/clawdbot/smoke-test.sh"
  "scripts/clawdbot/tests/install-candidate.test.sh"
)
for file in "${required[@]}"; do
  [[ -s "$root/$file" ]] || { echo "Missing required file: $file" >&2; exit 1; }
done
for script in "$root"/scripts/clawdbot/*.sh "$root"/scripts/clawdbot/tests/*.sh; do
  bash -n "$script"
  [[ -x "$script" ]] || { echo "Script is not executable: $script" >&2; exit 1; }
done
workflow="$root/.github/workflows/clawdbot-build.yml"
grep -q 'runs-on: ubuntu-24.04' "$workflow"
grep -q 'contents: read' "$workflow"
grep -q 'scripts/clawdbot/tests/install-candidate.test.sh' "$workflow"
grep -q 'pnpm pack' "$workflow"
grep -q 'actions/upload-artifact@v5' "$workflow"
if grep -Eq 'workflow_dispatch|npm publish|pnpm publish|gh release|systemctl|curl |openclaw |scp |rsync |kubectl |docker push' "$workflow"; then
  echo "Workflow contains a forbidden manual/publish/deploy/live command." >&2
  exit 1
fi
if grep -IEq 'curl .*18789|18789.*curl|/healthz' \
  "$root/scripts/clawdbot/runtime-common.sh" "$root/scripts/clawdbot/backup-runtime.sh" \
  "$root/scripts/clawdbot/install-candidate.sh" "$root/scripts/clawdbot/rollback-runtime.sh" \
  "$root/scripts/clawdbot/smoke-test.sh" "$root/scripts/clawdbot/tests/install-candidate.test.sh" \
  "$root/docs/clawdbot/EMERGENCY-RECOVERY.md" "$root/docs/clawdbot/maintenance-runbook.md"; then
  echo "Owner safety paths contain a forbidden plain-HTTP health gate." >&2
  exit 1
fi
echo "Safety foundation verification passed."
