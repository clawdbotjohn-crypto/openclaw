#!/usr/bin/env bash
set -Eeuo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=runtime-common.sh
source "$script_dir/runtime-common.sh"

usage() {
  cat <<'USAGE'
Usage: rollback-runtime.sh [options] --yes

Transactionally restore a validated known-good archive. ERR/INT/TERM/unexpected
EXIT recovery restores the exact pre-rollback runtime and prior running/stopped
service state. A missing, malformed, ambiguous, mismatched, or misnamed checksum
is fatal.

Options:
  --archive FILE       Known-good .tgz (default: current-good.tgz)
  --checksum FILE      Exact checksum file (default: ARCHIVE.sha256)
  --runtime-dir DIR    Installed OpenClaw directory (auto-detected)
  --release-dir DIR    Shared-lock directory (default: ~/.openclaw/releases)
  --service NAME       User service (default: openclaw-gateway.service)
  --health-bin PATH    Active OpenClaw CLI path (default: PREFIX/bin/openclaw)
  --yes                Required acknowledgement
  -h, --help           Show help
USAGE
}

RELEASE_DIR="${OPENCLAW_RELEASE_DIR:-$HOME/.openclaw/releases}"
ARCHIVE="${OPENCLAW_ROLLBACK_ARCHIVE:-$RELEASE_DIR/current-good.tgz}"
CHECKSUM=""; RUNTIME_DIR=""; CONFIRMED=false
RUNTIME_SERVICE="openclaw-gateway.service"
RUNTIME_SYSTEMCTL_BIN="${OPENCLAW_SYSTEMCTL_BIN:-systemctl}"
RUNTIME_HEALTH_BIN="${OPENCLAW_HEALTH_BIN:-}"
RUNTIME_HEALTH_TIMEOUT_MS="${OPENCLAW_HEALTH_TIMEOUT_MS:-10000}"
RUNTIME_HEALTH_ATTEMPTS="${OPENCLAW_HEALTH_ATTEMPTS:-12}"
RUNTIME_HEALTH_INTERVAL_SECONDS="${OPENCLAW_HEALTH_INTERVAL_SECONDS:-5}"
while (($#)); do
  case "$1" in
    --archive) ARCHIVE="${2:?missing value}"; shift 2 ;;
    --checksum) CHECKSUM="${2:?missing value}"; shift 2 ;;
    --runtime-dir) RUNTIME_DIR="${2:?missing value}"; shift 2 ;;
    --release-dir) RELEASE_DIR="${2:?missing value}"; shift 2 ;;
    --service) RUNTIME_SERVICE="${2:?missing value}"; shift 2 ;;
    --health-bin) RUNTIME_HEALTH_BIN="${2:?missing value}"; shift 2 ;;
    --yes) CONFIRMED=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done
$CONFIRMED || { echo "Refusing rollback without --yes." >&2; exit 2; }
[[ -f "$ARCHIVE" ]] || { echo "Archive not found: $ARCHIVE" >&2; exit 1; }
ARCHIVE="$(readlink -f "$ARCHIVE")"
CHECKSUM="$(readlink -f "${CHECKSUM:-${ARCHIVE}.sha256}")"
runtime_validate_checksum "$ARCHIVE" "$CHECKSUM"
[[ "$RUNTIME_HEALTH_ATTEMPTS" =~ ^[1-9][0-9]*$ && "$RUNTIME_HEALTH_TIMEOUT_MS" =~ ^[1-9][0-9]*$ ]] || { echo "Invalid health settings." >&2; exit 2; }
[[ "$RUNTIME_HEALTH_INTERVAL_SECONDS" =~ ^[0-9]+([.][0-9]+)?$ ]] || { echo "Invalid health interval." >&2; exit 2; }

if [[ -z "$RUNTIME_DIR" ]]; then
  prefix="$(npm prefix --global)"
  RUNTIME_DIR="$prefix/lib/node_modules/openclaw"
else
  prefix="$(cd "$(dirname "$(dirname "$(dirname "$RUNTIME_DIR")")")" && pwd)"
fi
RUNTIME_DIR="$(readlink -m "$RUNTIME_DIR")"
runtime_parent="$(dirname "$RUNTIME_DIR")"
bin_link="$prefix/bin/openclaw"
RUNTIME_HEALTH_BIN="${RUNTIME_HEALTH_BIN:-$bin_link}"
[[ -f "$RUNTIME_DIR/package.json" && -f "$RUNTIME_DIR/openclaw.mjs" ]] || { echo "Current runtime is invalid: $RUNTIME_DIR" >&2; exit 1; }
[[ -x "$RUNTIME_HEALTH_BIN" ]] || { echo "Health CLI is not executable: $RUNTIME_HEALTH_BIN" >&2; exit 1; }
runtime_verify_active_path "$RUNTIME_DIR" "$bin_link" || { echo "Active CLI does not resolve to runtime." >&2; exit 1; }

mkdir -p "$RELEASE_DIR"
RELEASE_DIR="$(cd "$RELEASE_DIR" && pwd)"
runtime_acquire_lock "$RELEASE_DIR/.runtime.lock"
initial_running=false
runtime_service_is_running && initial_running=true

entries=0
while IFS= read -r entry; do
  ((entries+=1))
  case "$entry" in openclaw|openclaw/|openclaw/*) ;; *) echo "Unsafe archive entry: $entry" >&2; exit 1 ;; esac
  [[ "$entry" != *"../"* && "$entry" != ../* && "$entry" != /* ]] || { echo "Unsafe traversal entry: $entry" >&2; exit 1; }
done < <(tar -tzf "$ARCHIVE")
(( entries > 0 )) || { echo "Archive is empty." >&2; exit 1; }

stamp="$(date -u +%Y%m%dT%H%M%SZ)-$$"
stage="$runtime_parent/.openclaw-restore-$stamp"
replaced="$runtime_parent/openclaw.replaced-$stamp"
restore_failed="$runtime_parent/openclaw.restore-failed-$stamp"
mkdir -p "$stage"
tar -xzf "$ARCHIVE" --strip-components=1 -C "$stage"
[[ -f "$stage/package.json" && -f "$stage/openclaw.mjs" ]] || { echo "Archive does not contain a valid OpenClaw runtime." >&2; exit 1; }
original_bin_target="$(readlink "$bin_link")"

transaction_active=false; original_saved=false; restored_active=false; recovering=false
restore_original() {
  local reason="$1" ok=true
  $recovering && return 1
  recovering=true
  trap - ERR INT TERM EXIT
  echo "Recovery required after $reason; restoring exact pre-rollback runtime/service state." >&2
  # Reconcile filesystem state first: a signal can arrive after an atomic mv
  # returns but before its bookkeeping assignment executes.
  [[ -d "$replaced" ]] && original_saved=true
  if $original_saved && [[ -e "$RUNTIME_DIR" ]]; then restored_active=true; fi
  "$RUNTIME_SYSTEMCTL_BIN" --user stop "$RUNTIME_SERVICE" >/dev/null 2>&1 || true
  if $restored_active && [[ -e "$RUNTIME_DIR" ]]; then mv "$RUNTIME_DIR" "$restore_failed" || ok=false; fi
  if $original_saved; then
    [[ ! -e "$RUNTIME_DIR" && -d "$replaced" ]] && mv "$replaced" "$RUNTIME_DIR" || ok=false
  fi
  ln -sfn "$original_bin_target" "$bin_link" || ok=false
  runtime_verify_active_path "$RUNTIME_DIR" "$bin_link" || ok=false
  if $initial_running; then
    "$RUNTIME_SYSTEMCTL_BIN" --user start "$RUNTIME_SERVICE" || ok=false
    $ok && runtime_wait_for_structured_health || ok=false
  else
    "$RUNTIME_SYSTEMCTL_BIN" --user stop "$RUNTIME_SERVICE" >/dev/null 2>&1 || true
    runtime_service_is_running && ok=false
  fi
  transaction_active=false
  if $ok; then
    echo "Recovery verified the original active path and prior service state." >&2
    return 0
  fi
  echo "CRITICAL: recovery could not verify exact runtime/service restoration. Stop and escalate; do not retry." >&2
  return 1
}
abort_transaction() {
  local source="$1" rc="$2"
  trap - ERR INT TERM EXIT
  if $transaction_active; then restore_original "$source" || exit 3; fi
  case "$source" in INT) exit 130 ;; TERM) exit 143 ;; *) exit "$rc" ;; esac
}
trap 'abort_transaction ERR $?' ERR
trap 'abort_transaction INT 130' INT
trap 'abort_transaction TERM 143' TERM
trap 'rc=$?; if $transaction_active; then abort_transaction EXIT "$rc"; fi' EXIT

transaction_active=true
runtime_test_hook before-stop
"$RUNTIME_SYSTEMCTL_BIN" --user stop "$RUNTIME_SERVICE"
runtime_test_hook after-stop
mv "$RUNTIME_DIR" "$replaced"
runtime_test_hook after-move-original
original_saved=true
mv "$stage" "$RUNTIME_DIR"
runtime_test_hook after-activate-restored
restored_active=true
ln -sfn ../lib/node_modules/openclaw/openclaw.mjs "$bin_link"
runtime_test_hook after-link
runtime_verify_active_path "$RUNTIME_DIR" "$bin_link"
if $initial_running; then
  "$RUNTIME_SYSTEMCTL_BIN" --user start "$RUNTIME_SERVICE"
  runtime_test_hook after-start
  runtime_wait_for_structured_health
  runtime_test_hook after-health
else
  runtime_service_is_running && { echo "Service unexpectedly running after stopped-state rollback." >&2; false; }
  runtime_test_hook after-stopped-verify
fi

transaction_active=false
trap - ERR INT TERM EXIT
echo "Rollback succeeded only after active path and required service state verification."
echo "Preserved replaced runtime at: $replaced"
echo "Restored archive: $ARCHIVE"
