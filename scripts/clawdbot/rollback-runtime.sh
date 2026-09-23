#!/usr/bin/env bash
set -Eeuo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=runtime-common.sh
source "$script_dir/runtime-common.sh"

usage() {
  cat <<'USAGE'
Usage: rollback-runtime.sh [options] --yes

Transactionally restore a validated known-good archive. ERR/INT/TERM/unexpected
EXIT recovery restores the exact pre-rollback runtime and its explicitly proven
active/inactive service state. Unknown/query-error service states abort before
runtime mutation.

Options:
  --archive FILE       Known-good .tgz (default: current-good.tgz)
  --checksum FILE      Exact checksum file (default: ARCHIVE.sha256)
  --runtime-dir DIR    Installed OpenClaw directory (auto-detected)
  --release-dir DIR    Shared-lock directory (default: ~/.openclaw/releases)
  --service NAME       User service (default: openclaw-gateway.service)
  --health-bin PATH    Active CLI symlink bound to target runtime/openclaw.mjs
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
SOURCE_ARCHIVE="$(readlink -f "$ARCHIVE")"
SOURCE_CHECKSUM="${CHECKSUM:-${SOURCE_ARCHIVE}.sha256}"
[[ -f "$SOURCE_CHECKSUM" ]] || { echo "Checksum file is required: $SOURCE_CHECKSUM" >&2; exit 1; }
SOURCE_CHECKSUM="$(readlink -f "$SOURCE_CHECKSUM")"
archive_snapshot_dir="$(runtime_make_private_temp_dir "$(readlink -m "${TMPDIR:-/tmp}")" openclaw-rollback-archive)"
cleanup_archive_snapshot() { [[ -z "${archive_snapshot_dir:-}" ]] || rm -rf -- "$archive_snapshot_dir"; archive_snapshot_dir=""; }
trap cleanup_archive_snapshot EXIT
mkdir -m 700 "$archive_snapshot_dir/archive" "$archive_snapshot_dir/inputs"
ARCHIVE="$archive_snapshot_dir/archive/$(basename "$SOURCE_ARCHIVE")"
CHECKSUM="$archive_snapshot_dir/inputs/checksum.sha256"
cp -- "$SOURCE_ARCHIVE" "$ARCHIVE"
cp -- "$SOURCE_CHECKSUM" "$CHECKSUM"
chmod 600 "$ARCHIVE" "$CHECKSUM"
runtime_validate_checksum "$ARCHIVE" "$CHECKSUM"
[[ "$RUNTIME_HEALTH_ATTEMPTS" =~ ^[1-9][0-9]*$ && "$RUNTIME_HEALTH_TIMEOUT_MS" =~ ^[1-9][0-9]*$ ]] || { echo "Invalid health settings." >&2; exit 2; }
[[ "$RUNTIME_HEALTH_INTERVAL_SECONDS" =~ ^[0-9]+([.][0-9]+)?$ ]] || { echo "Invalid health interval." >&2; exit 2; }

if [[ -z "$RUNTIME_DIR" ]]; then
  prefix="$(npm prefix --global)"
  RUNTIME_DIR="$prefix/lib/node_modules/openclaw"
else
  RUNTIME_DIR="$(readlink -m "$RUNTIME_DIR")"
  prefix="$(dirname "$(dirname "$(dirname "$RUNTIME_DIR")")")"
fi
prefix="$(cd "$prefix" && pwd -P)"
RUNTIME_DIR="$(readlink -m "$RUNTIME_DIR")"
runtime_parent="$(dirname "$RUNTIME_DIR")"
bin_link="$prefix/bin/openclaw"
RUNTIME_HEALTH_BIN="${RUNTIME_HEALTH_BIN:-$bin_link}"
[[ -d "$RUNTIME_DIR" && ! -L "$RUNTIME_DIR" && -f "$RUNTIME_DIR/package.json" && -f "$RUNTIME_DIR/openclaw.mjs" ]] || { echo "Current runtime is invalid: $RUNTIME_DIR" >&2; exit 1; }
runtime_bind_health_to_runtime "$RUNTIME_DIR" "$RUNTIME_HEALTH_BIN"
runtime_verify_active_path "$RUNTIME_DIR" "$bin_link" || { echo "Active CLI does not resolve to runtime." >&2; exit 1; }

mkdir -p "$RELEASE_DIR"
RELEASE_DIR="$(cd "$RELEASE_DIR" && pwd -P)"
runtime_validate_owned_directory "$RELEASE_DIR"
runtime_acquire_lock "$RELEASE_DIR/.runtime.lock"
runtime_capture_service_state
initial_service_state="$RUNTIME_SERVICE_STATE"

archive_list="$archive_snapshot_dir/inputs/archive.list"
runtime_archive_list "$ARCHIVE" "$archive_list"
entries=0
while IFS= read -r entry; do
  ((entries+=1))
  case "$entry" in openclaw|openclaw/|openclaw/*) ;; *) echo "Unsafe archive entry: $entry" >&2; exit 1 ;; esac
  [[ "$entry" != *"../"* && "$entry" != ../* && "$entry" != /* ]] || { echo "Unsafe traversal entry: $entry" >&2; exit 1; }
done < "$archive_list"
(( entries > 0 )) || { echo "Archive is empty." >&2; exit 1; }

time_parent="$runtime_parent"
runtime_validate_owned_directory "$time_parent"
tx_dir="$(runtime_make_private_tx_dir "$time_parent" openclaw-rollback-tx)"
stage="$tx_dir/staged-runtime"
replaced="$tx_dir/replaced-runtime"
restore_failed="$tx_dir/failed-restored-runtime"
mkdir -m 700 "$stage"
tar -xzf "$ARCHIVE" --strip-components=1 -C "$stage"
[[ -f "$stage/package.json" && -f "$stage/openclaw.mjs" ]] || { echo "Archive does not contain a valid OpenClaw runtime; transaction retained at: $tx_dir" >&2; exit 1; }
original_bin_target="$(readlink "$bin_link")"

transaction_active=false; recovering=false; script_pid="$BASHPID"
restore_original() {
  local reason="$1" ok=true temp_link="$tx_dir/bin-restore"
  $recovering && return 1
  recovering=true
  trap - ERR EXIT
  trap '' INT TERM
  runtime_test_repeated_recovery_signals || true
  echo "Recovery required after $reason; restoring exact pre-rollback runtime/service state." >&2
  if [[ -d "$replaced" ]]; then
    runtime_capture_service_state || ok=false
    if $ok && [[ "$RUNTIME_SERVICE_STATE" == active ]]; then
      "$RUNTIME_SYSTEMCTL_BIN" --user stop "$RUNTIME_SERVICE" || ok=false
      $ok && runtime_require_service_state inactive || ok=false
    fi
    if $ok && [[ -e "$RUNTIME_DIR" || -L "$RUNTIME_DIR" ]]; then
      if [[ -e "$restore_failed" || -L "$restore_failed" ]]; then ok=false
      else mv -T -- "$RUNTIME_DIR" "$restore_failed" || ok=false; fi
    fi
    if $ok && [[ ! -e "$RUNTIME_DIR" && ! -L "$RUNTIME_DIR" ]]; then mv -T -- "$replaced" "$RUNTIME_DIR" || ok=false; fi
  fi
  rm -f -- "$temp_link"
  ln -s "$original_bin_target" "$temp_link" && mv -Tf -- "$temp_link" "$bin_link" || ok=false
  runtime_verify_active_path "$RUNTIME_DIR" "$bin_link" || ok=false
  RUNTIME_HEALTH_BIN="$bin_link"
  runtime_restore_service_state "$initial_service_state" || ok=false
  if $ok; then
    transaction_active=false
    echo "Recovery verified the original active path and $initial_service_state service state." >&2
    return 0
  fi
  echo "CRITICAL: recovery could not verify exact runtime/service restoration. Transaction retained at: $tx_dir" >&2
  return 1
}
abort_transaction() {
  local source="$1" rc="$2"
  [[ "$BASHPID" == "$script_pid" ]] || return 0
  trap - ERR INT TERM EXIT
  trap '' INT TERM
  if $transaction_active && ! restore_original "$source"; then cleanup_archive_snapshot; exit 3; fi
  cleanup_archive_snapshot
  case "$source" in INT) exit 130 ;; TERM) exit 143 ;; *) exit "$rc" ;; esac
}
trap 'abort_transaction ERR $?' ERR
trap 'abort_transaction INT 130' INT
trap 'abort_transaction TERM 143' TERM
trap 'rc=$?; if $transaction_active; then abort_transaction EXIT "$rc"; else cleanup_archive_snapshot; fi' EXIT

transaction_active=true
runtime_test_hook before-stop
"$RUNTIME_SYSTEMCTL_BIN" --user stop "$RUNTIME_SERVICE"
runtime_require_service_state inactive
runtime_test_hook after-stop
mv -T -- "$RUNTIME_DIR" "$replaced"
runtime_test_hook after-move-original
mv -T -- "$stage" "$RUNTIME_DIR"
runtime_test_hook after-activate-restored
new_link="$tx_dir/bin-restored"
ln -s ../lib/node_modules/openclaw/openclaw.mjs "$new_link"
mv -Tf -- "$new_link" "$bin_link"
runtime_test_hook after-link
runtime_verify_active_path "$RUNTIME_DIR" "$bin_link"
RUNTIME_HEALTH_BIN="$bin_link"
if [[ "$initial_service_state" == active ]]; then
  "$RUNTIME_SYSTEMCTL_BIN" --user start "$RUNTIME_SERVICE"
  runtime_require_service_state active
  runtime_test_hook after-start
  runtime_wait_for_structured_health
  runtime_test_hook after-health
else
  runtime_require_service_state inactive
  runtime_test_hook after-stopped-verify
fi

transaction_active=false
trap - ERR INT TERM EXIT
cleanup_archive_snapshot
rm -rf -- "$restore_failed"
echo "Rollback succeeded only after active path and required service state verification."
echo "Preserved replaced runtime at: $replaced"
echo "Restored archive: $SOURCE_ARCHIVE"
