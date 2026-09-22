#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
required=(
  ".github/workflows/clawdbot-build.yml"
  "docs/clawdbot/maintenance-runbook.md"
  "docs/clawdbot/patch-manifest.md"
  "scripts/clawdbot/backup-runtime.sh"
  "scripts/clawdbot/rollback-runtime.sh"
  "scripts/clawdbot/smoke-test.sh"
)
for file in "${required[@]}"; do
  [[ -s "$root/$file" ]] || { echo "Missing required file: $file" >&2; exit 1; }
done
for script in "$root"/scripts/clawdbot/*.sh; do
  bash -n "$script"
  [[ -x "$script" ]] || { echo "Script is not executable: $script" >&2; exit 1; }
done
workflow="$root/.github/workflows/clawdbot-build.yml"
grep -q 'workflow_dispatch:' "$workflow"
grep -q 'runs-on: ubuntu-24.04' "$workflow"
grep -q 'pnpm pack' "$workflow"
grep -q 'actions/upload-artifact@v5' "$workflow"
if grep -Eq 'npm publish|pnpm publish|gh release|systemctl|scp |rsync ' "$workflow"; then
  echo "Workflow contains a forbidden publish/deploy command." >&2
  exit 1
fi
echo "Safety foundation verification passed."
