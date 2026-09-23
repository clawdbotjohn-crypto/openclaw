#!/usr/bin/env bash
set -Eeuo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=runtime-common.sh
source "$script_dir/runtime-common.sh"

usage() {
  cat <<'USAGE'
Usage: install-candidate.sh --artifact FILE --metadata FILE [options]

Validate provenance and package integrity, archive a proven-healthy baseline,
stage the package, and transactionally swap it into place. Any ERR/INT/TERM or
unexpected EXIT after mutation begins restores the exact prior runtime and its
explicitly proven active/inactive service state.

Required provenance options:
  --artifact FILE             Candidate npm .tgz
  --checksum FILE             Exactly one SHA-256 record (default: FILE.sha256)
  --metadata FILE             build-metadata.txt from the same artifact
  --expected-repository O/R   Exact expected GitHub repository
  --expected-ref REF          Exact promotable refs/heads/* ref
  --expected-sha SHA          Exact post-merge 40-character commit SHA

Target/options:
  --prefix DIR                npm prefix containing lib/node_modules/openclaw
  --runtime-dir DIR           Runtime target (must match PREFIX layout)
  --release-dir DIR           Backup directory (default: ~/.openclaw/releases)
  --service NAME              User service (default: openclaw-gateway.service)
  --health-bin PATH           CLI symlink bound to target runtime/openclaw.mjs
  --apply --yes               Both are required to mutate
  --allow-live-runtime        Additionally required for active global target
  -h, --help                  Show help
USAGE
}

ARTIFACT=""; CHECKSUM=""; METADATA=""
EXPECTED_REPOSITORY=""; EXPECTED_REF=""; EXPECTED_SHA=""
PREFIX=""; RUNTIME_DIR=""
RELEASE_DIR="${OPENCLAW_RELEASE_DIR:-$HOME/.openclaw/releases}"
RUNTIME_SERVICE="openclaw-gateway.service"
RUNTIME_SYSTEMCTL_BIN="${OPENCLAW_SYSTEMCTL_BIN:-systemctl}"
NPM_BIN="${OPENCLAW_NPM_BIN:-npm}"
RUNTIME_HEALTH_BIN="${OPENCLAW_HEALTH_BIN:-}"
RUNTIME_HEALTH_TIMEOUT_MS="${OPENCLAW_HEALTH_TIMEOUT_MS:-10000}"
RUNTIME_HEALTH_ATTEMPTS="${OPENCLAW_HEALTH_ATTEMPTS:-12}"
RUNTIME_HEALTH_INTERVAL_SECONDS="${OPENCLAW_HEALTH_INTERVAL_SECONDS:-5}"
APPLY=false; CONFIRMED=false; ALLOW_LIVE=false
while (($#)); do
  case "$1" in
    --artifact) ARTIFACT="${2:?missing value}"; shift 2 ;;
    --checksum) CHECKSUM="${2:?missing value}"; shift 2 ;;
    --metadata) METADATA="${2:?missing value}"; shift 2 ;;
    --expected-repository) EXPECTED_REPOSITORY="${2:?missing value}"; shift 2 ;;
    --expected-ref) EXPECTED_REF="${2:?missing value}"; shift 2 ;;
    --expected-sha) EXPECTED_SHA="${2:?missing value}"; shift 2 ;;
    --prefix) PREFIX="${2:?missing value}"; shift 2 ;;
    --runtime-dir) RUNTIME_DIR="${2:?missing value}"; shift 2 ;;
    --release-dir) RELEASE_DIR="${2:?missing value}"; shift 2 ;;
    --service) RUNTIME_SERVICE="${2:?missing value}"; shift 2 ;;
    --health-bin) RUNTIME_HEALTH_BIN="${2:?missing value}"; shift 2 ;;
    --apply) APPLY=true; shift ;;
    --yes) CONFIRMED=true; shift ;;
    --allow-live-runtime) ALLOW_LIVE=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -n "$ARTIFACT" && -f "$ARTIFACT" ]] || { echo "--artifact must name an existing file." >&2; exit 2; }
[[ -n "$METADATA" && -f "$METADATA" ]] || { echo "--metadata must name build-metadata.txt." >&2; exit 2; }
[[ -n "$EXPECTED_REPOSITORY" && -n "$EXPECTED_REF" && -n "$EXPECTED_SHA" ]] || {
  echo "Explicit --expected-repository, --expected-ref, and --expected-sha are required." >&2; exit 2;
}
SOURCE_ARTIFACT="$(readlink -f "$ARTIFACT")"
SOURCE_CHECKSUM="${CHECKSUM:-${SOURCE_ARTIFACT}.sha256}"
[[ -f "$SOURCE_CHECKSUM" ]] || { echo "Checksum file is required: $SOURCE_CHECKSUM" >&2; exit 1; }
SOURCE_CHECKSUM="$(readlink -f "$SOURCE_CHECKSUM")"
SOURCE_METADATA="$(readlink -f "$METADATA")"
artifact_snapshot_dir="$(runtime_make_private_temp_dir "$(readlink -m "${TMPDIR:-/tmp}")" openclaw-install-artifact)"
cleanup_artifact_snapshot() { [[ -z "${artifact_snapshot_dir:-}" ]] || rm -rf -- "$artifact_snapshot_dir"; artifact_snapshot_dir=""; }
trap cleanup_artifact_snapshot EXIT
mkdir -m 700 "$artifact_snapshot_dir/artifact" "$artifact_snapshot_dir/inputs"
ARTIFACT="$artifact_snapshot_dir/artifact/$(basename "$SOURCE_ARTIFACT")"
CHECKSUM="$artifact_snapshot_dir/inputs/checksum.sha256"
METADATA="$artifact_snapshot_dir/inputs/build-metadata.txt"
cp -- "$SOURCE_ARTIFACT" "$ARTIFACT"
cp -- "$SOURCE_CHECKSUM" "$CHECKSUM"
cp -- "$SOURCE_METADATA" "$METADATA"
chmod 600 "$ARTIFACT" "$CHECKSUM" "$METADATA"
runtime_validate_checksum "$ARTIFACT" "$CHECKSUM"
runtime_validate_provenance "$METADATA" "$EXPECTED_REPOSITORY" "$EXPECTED_REF" "$EXPECTED_SHA" "$ARTIFACT" "$RUNTIME_VALIDATED_SHA256"
[[ "$RUNTIME_HEALTH_ATTEMPTS" =~ ^[1-9][0-9]*$ && "$RUNTIME_HEALTH_TIMEOUT_MS" =~ ^[1-9][0-9]*$ ]] || { echo "Invalid health settings." >&2; exit 2; }
[[ "$RUNTIME_HEALTH_INTERVAL_SECONDS" =~ ^[0-9]+([.][0-9]+)?$ ]] || { echo "Invalid health interval." >&2; exit 2; }

artifact_list="$artifact_snapshot_dir/inputs/archive.list"
runtime_archive_list "$ARTIFACT" "$artifact_list"
grep -Fxq 'package/package.json' "$artifact_list" && grep -Fxq 'package/openclaw.mjs' "$artifact_list" || {
  echo "Artifact is not a valid OpenClaw npm package." >&2; exit 1;
}

GLOBAL_PREFIX="$($NPM_BIN prefix --global)"
GLOBAL_RUNTIME="$GLOBAL_PREFIX/lib/node_modules/openclaw"
if [[ -z "$PREFIX" && -z "$RUNTIME_DIR" ]]; then PREFIX="$GLOBAL_PREFIX"
elif [[ -z "$PREFIX" ]]; then PREFIX="$(dirname "$(dirname "$(dirname "$(readlink -m "$RUNTIME_DIR")")")")"; fi
[[ -d "$PREFIX" ]] || { echo "Target prefix does not exist: $PREFIX" >&2; exit 1; }
PREFIX="$(cd "$PREFIX" && pwd -P)"
EXPECTED_RUNTIME="$PREFIX/lib/node_modules/openclaw"
RUNTIME_DIR="$(readlink -m "${RUNTIME_DIR:-$EXPECTED_RUNTIME}")"
[[ "$RUNTIME_DIR" == "$EXPECTED_RUNTIME" ]] || { echo "Runtime target must be $EXPECTED_RUNTIME" >&2; exit 2; }
[[ -d "$RUNTIME_DIR" && ! -L "$RUNTIME_DIR" && -f "$RUNTIME_DIR/package.json" && -f "$RUNTIME_DIR/openclaw.mjs" ]] || { echo "Current runtime is invalid: $RUNTIME_DIR" >&2; exit 1; }
RUNTIME_HEALTH_BIN="${RUNTIME_HEALTH_BIN:-$PREFIX/bin/openclaw}"
runtime_bind_health_to_runtime "$RUNTIME_DIR" "$RUNTIME_HEALTH_BIN"
runtime_verify_active_path "$RUNTIME_DIR" "$PREFIX/bin/openclaw" || { echo "Active CLI does not resolve to target runtime." >&2; exit 1; }

is_live=false
[[ "$(readlink -f "$RUNTIME_DIR")" == "$(readlink -f "$GLOBAL_RUNTIME")" ]] && is_live=true
cat <<PLAN
Candidate install plan
  artifact source: $SOURCE_ARTIFACT
  artifact sha:    $RUNTIME_VALIDATED_SHA256 (private validated snapshot)
  repository:     $EXPECTED_REPOSITORY
  ref / sha:      $EXPECTED_REF @ $EXPECTED_SHA
  target runtime: $RUNTIME_DIR
  backup dir:     $RELEASE_DIR
  service:        $RUNTIME_SERVICE
  bound health:   $(readlink -f "$RUNTIME_HEALTH_BIN")
  global/live:    $is_live
PLAN
if ! $APPLY; then echo "DRY RUN ONLY: validation passed; no files or services were changed."; exit 0; fi
$CONFIRMED || { echo "Refusing mutation: --apply also requires --yes." >&2; exit 2; }
if $is_live && ! $ALLOW_LIVE; then echo "Refusing active global runtime mutation without --allow-live-runtime." >&2; exit 2; fi

mkdir -p "$RELEASE_DIR" "$PREFIX/lib/node_modules" "$PREFIX/bin"
RELEASE_DIR="$(cd "$RELEASE_DIR" && pwd -P)"
runtime_validate_owned_directory "$RELEASE_DIR"
runtime_acquire_lock "$RELEASE_DIR/.runtime.lock"
runtime_capture_service_state
initial_service_state="$RUNTIME_SERVICE_STATE"
if [[ "$initial_service_state" == active ]]; then
  runtime_structured_health_once || { echo "Current baseline failed structured health; preserving known-good and refusing install." >&2; exit 1; }
fi

backup_args=(--output-dir "$RELEASE_DIR" --runtime-dir "$RUNTIME_DIR" --service "$RUNTIME_SERVICE" --health-bin "$RUNTIME_HEALTH_BIN" --lock-fd "$RUNTIME_LOCK_FD" --yes)
[[ "$initial_service_state" == active ]] || backup_args+=(--no-promote-current-good)
backup_output="$(OPENCLAW_SYSTEMCTL_BIN="$RUNTIME_SYSTEMCTL_BIN" OPENCLAW_HEALTH_TIMEOUT_MS="$RUNTIME_HEALTH_TIMEOUT_MS" "$script_dir/backup-runtime.sh" "${backup_args[@]}")"
printf '%s\n' "$backup_output"
backup_archive="$(printf '%s\n' "$backup_output" | sed -n 's/^Backup complete: //p' | tail -1)"
[[ -n "$backup_archive" && -f "$backup_archive" ]] || { echo "Could not identify completed pre-install backup." >&2; exit 1; }
runtime_validate_checksum "$backup_archive" "$backup_archive.sha256"

runtime_parent="$(dirname "$RUNTIME_DIR")"
runtime_validate_owned_directory "$runtime_parent"
tx_dir="$(runtime_make_private_tx_dir "$runtime_parent" openclaw-install-tx)"
stage_prefix="$tx_dir/stage-prefix"
staged_runtime="$stage_prefix/lib/node_modules/openclaw"
previous_runtime="$tx_dir/previous-runtime"
failed_runtime="$tx_dir/failed-runtime"
bin_link="$PREFIX/bin/openclaw"
original_bin_target="$(readlink "$bin_link")"
original_runtime_identity="$(runtime_path_identity "$RUNTIME_DIR")"

if ! runtime_run_without_lock "$NPM_BIN" install --ignore-scripts --global --prefix "$stage_prefix" "$ARTIFACT"; then echo "Candidate staging failed; private transaction retained at: $tx_dir" >&2; exit 1; fi
[[ -f "$staged_runtime/package.json" && -f "$staged_runtime/openclaw.mjs" ]] || { echo "Staged candidate is invalid; retained at: $tx_dir" >&2; exit 1; }
OPENCLAW_STATE_DIR="$stage_prefix/state" OPENCLAW_CONFIG_PATH="$stage_prefix/openclaw.json" runtime_run_without_lock "$stage_prefix/bin/openclaw" --version >/dev/null

transaction_active=false; recovering=false; script_pid="$BASHPID"
restore_previous() {
  local reason="$1" ok=true temp_link="$tx_dir/bin-restore"
  $recovering && return 1
  recovering=true
  trap - ERR EXIT
  trap '' INT TERM
  runtime_test_repeated_recovery_signals || true
  echo "Recovery required after $reason; restoring exact pre-install runtime/service state." >&2
  if [[ -d "$previous_runtime" ]]; then
    if [[ "$(runtime_path_identity "$previous_runtime" 2>/dev/null || true)" != "$original_runtime_identity" ]]; then
      echo "CRITICAL: previous-runtime is not the exact original; refusing recovery mutation." >&2
      return 1
    fi
    if ! runtime_capture_service_state; then
      echo "CRITICAL: recovery service-state query failed before any further mutation; transaction retained at: $tx_dir" >&2
      return 1
    fi
    if [[ "$RUNTIME_SERVICE_STATE" == active ]]; then
      runtime_run_without_lock "$RUNTIME_SYSTEMCTL_BIN" --user stop "$RUNTIME_SERVICE" || ok=false
      $ok && runtime_require_service_state inactive || ok=false
    fi
    if $ok && [[ -e "$RUNTIME_DIR" || -L "$RUNTIME_DIR" ]]; then
      if [[ -e "$failed_runtime" || -L "$failed_runtime" ]]; then ok=false
      else mv -T -- "$RUNTIME_DIR" "$failed_runtime" || ok=false; fi
    fi
    if $ok && [[ ! -e "$RUNTIME_DIR" && ! -L "$RUNTIME_DIR" ]]; then mv -T -- "$previous_runtime" "$RUNTIME_DIR" || ok=false; fi
  fi
  rm -f -- "$temp_link"
  ln -s "$original_bin_target" "$temp_link" && mv -Tf -- "$temp_link" "$bin_link" || ok=false
  runtime_verify_active_path "$RUNTIME_DIR" "$bin_link" || ok=false
  RUNTIME_HEALTH_BIN="$bin_link"
  runtime_restore_service_state "$initial_service_state" || ok=false
  if $ok; then
    transaction_active=false
    echo "Automatic recovery verified the prior active path and $initial_service_state service state." >&2
    echo "Pre-install backup remains available at: $backup_archive" >&2
    return 0
  fi
  echo "CRITICAL: automatic recovery could not verify exact runtime/service restoration. Transaction retained at: $tx_dir" >&2
  return 1
}
abort_transaction() {
  local source="$1" rc="$2"
  [[ "$BASHPID" == "$script_pid" ]] || return 0
  trap - ERR INT TERM EXIT
  trap '' INT TERM
  if $transaction_active && ! restore_previous "$source"; then cleanup_artifact_snapshot; exit 3; fi
  cleanup_artifact_snapshot
  case "$source" in INT) exit 130 ;; TERM) exit 143 ;; *) exit "$rc" ;; esac
}
trap 'abort_transaction ERR $?' ERR
trap 'abort_transaction INT 130' INT
trap 'abort_transaction TERM 143' TERM
trap 'rc=$?; if $transaction_active; then abort_transaction EXIT "$rc"; else cleanup_artifact_snapshot; fi' EXIT

[[ ! -e "$previous_runtime" && ! -L "$previous_runtime" && ! -e "$failed_runtime" && ! -L "$failed_runtime" ]] || {
  echo "Transaction sibling collision detected before mutation; retained at: $tx_dir" >&2; exit 1;
}
transaction_active=true
runtime_test_hook before-stop
runtime_run_without_lock "$RUNTIME_SYSTEMCTL_BIN" --user stop "$RUNTIME_SERVICE"
runtime_require_service_state inactive
runtime_test_hook after-stop
[[ ! -e "$previous_runtime" && ! -L "$previous_runtime" ]] || { echo "previous-runtime collision; refusing original move." >&2; false; }
mv -T -- "$RUNTIME_DIR" "$previous_runtime"
[[ "$(runtime_path_identity "$previous_runtime")" == "$original_runtime_identity" ]] || { echo "Original runtime identity changed during move." >&2; false; }
runtime_test_hook after-move-original
mv -T -- "$staged_runtime" "$RUNTIME_DIR"
runtime_test_hook after-activate-candidate
new_link="$tx_dir/bin-candidate"
ln -s ../lib/node_modules/openclaw/openclaw.mjs "$new_link"
mv -Tf -- "$new_link" "$bin_link"
runtime_test_hook after-link
runtime_verify_active_path "$RUNTIME_DIR" "$bin_link"
RUNTIME_HEALTH_BIN="$bin_link"
if [[ "$initial_service_state" == active ]]; then
  runtime_run_without_lock "$RUNTIME_SYSTEMCTL_BIN" --user start "$RUNTIME_SERVICE"
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
cleanup_artifact_snapshot
rm -rf -- "$stage_prefix" "$failed_runtime"
echo "Candidate installation succeeded; active path and required service state were verified."
echo "Pre-install archive: $backup_archive"
echo "Previous runtime preserved at: $previous_runtime"
