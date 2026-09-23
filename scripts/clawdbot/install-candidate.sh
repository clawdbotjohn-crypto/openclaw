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
running/stopped service state.

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
  --health-bin PATH           OpenClaw CLI used for structured RPC health
  --apply --yes               Both are required to mutate
  --allow-live-runtime        Additionally required for active global target
  -h, --help                  Show help

Test hooks are accepted only with OPENCLAW_TEST_MODE=1, a /tmp
OPENCLAW_TEST_ROOT containing the runtime, and explicit phase/mode variables.
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
artifact_snapshot_dir=""
cleanup_artifact_snapshot() {
  [[ -z "$artifact_snapshot_dir" ]] || rm -rf -- "$artifact_snapshot_dir"
  artifact_snapshot_dir=""
}
trap cleanup_artifact_snapshot EXIT
artifact_snapshot_dir="$(mktemp -d "${TMPDIR:-/tmp}/openclaw-install-artifact.XXXXXX")"
chmod 700 "$artifact_snapshot_dir"
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

package_json=false; entrypoint=false
while IFS= read -r entry; do
  case "$entry" in package/package.json) package_json=true ;; package/openclaw.mjs) entrypoint=true ;; esac
done < <(tar -tzf "$ARTIFACT")
$package_json && $entrypoint || { echo "Artifact is not a valid OpenClaw npm package." >&2; exit 1; }

GLOBAL_PREFIX="$($NPM_BIN prefix --global)"
GLOBAL_RUNTIME="$GLOBAL_PREFIX/lib/node_modules/openclaw"
if [[ -z "$PREFIX" && -z "$RUNTIME_DIR" ]]; then PREFIX="$GLOBAL_PREFIX"
elif [[ -z "$PREFIX" ]]; then PREFIX="$(cd "$(dirname "$(dirname "$(dirname "$RUNTIME_DIR")")")" && pwd)"; fi
[[ -d "$PREFIX" ]] || { echo "Target prefix does not exist: $PREFIX" >&2; exit 1; }
PREFIX="$(cd "$PREFIX" && pwd)"
EXPECTED_RUNTIME="$PREFIX/lib/node_modules/openclaw"
RUNTIME_DIR="${RUNTIME_DIR:-$EXPECTED_RUNTIME}"
[[ "$(readlink -m "$RUNTIME_DIR")" == "$EXPECTED_RUNTIME" ]] || { echo "Runtime target must be $EXPECTED_RUNTIME" >&2; exit 2; }
[[ -f "$RUNTIME_DIR/package.json" && -f "$RUNTIME_DIR/openclaw.mjs" ]] || { echo "Current runtime is invalid: $RUNTIME_DIR" >&2; exit 1; }
RUNTIME_HEALTH_BIN="${RUNTIME_HEALTH_BIN:-$PREFIX/bin/openclaw}"
[[ -x "$RUNTIME_HEALTH_BIN" ]] || { echo "Health CLI is not executable: $RUNTIME_HEALTH_BIN" >&2; exit 1; }
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
  health probe:   $RUNTIME_HEALTH_BIN health --json --timeout $RUNTIME_HEALTH_TIMEOUT_MS
  global/live:    $is_live
PLAN
if ! $APPLY; then echo "DRY RUN ONLY: validation passed; no files or services were changed."; exit 0; fi
$CONFIRMED || { echo "Refusing mutation: --apply also requires --yes." >&2; exit 2; }
if $is_live && ! $ALLOW_LIVE; then echo "Refusing active global runtime mutation without --allow-live-runtime." >&2; exit 2; fi

mkdir -p "$RELEASE_DIR" "$PREFIX/lib/node_modules" "$PREFIX/bin"
RELEASE_DIR="$(cd "$RELEASE_DIR" && pwd)"
runtime_acquire_lock "$RELEASE_DIR/.runtime.lock"
initial_running=false
runtime_service_is_running && initial_running=true
if $initial_running; then
  runtime_structured_health_once || { echo "Current baseline failed structured health; preserving known-good and refusing install." >&2; exit 1; }
fi

backup_args=(--output-dir "$RELEASE_DIR" --runtime-dir "$RUNTIME_DIR" --service "$RUNTIME_SERVICE" --health-bin "$RUNTIME_HEALTH_BIN" --lock-fd "$RUNTIME_LOCK_FD" --yes)
$initial_running || backup_args+=(--no-promote-current-good)
backup_output="$(OPENCLAW_SYSTEMCTL_BIN="$RUNTIME_SYSTEMCTL_BIN" OPENCLAW_HEALTH_TIMEOUT_MS="$RUNTIME_HEALTH_TIMEOUT_MS" "$script_dir/backup-runtime.sh" "${backup_args[@]}")"
printf '%s\n' "$backup_output"
backup_archive="$(printf '%s\n' "$backup_output" | sed -n 's/^Backup complete: //p' | tail -1)"
[[ -n "$backup_archive" && -f "$backup_archive" ]] || { echo "Could not identify completed pre-install backup." >&2; exit 1; }
runtime_validate_checksum "$backup_archive" "$backup_archive.sha256"

stamp="$(date -u +%Y%m%dT%H%M%SZ)-$$"
runtime_parent="$(dirname "$RUNTIME_DIR")"
stage_prefix="$runtime_parent/.openclaw-candidate-stage-$stamp"
staged_runtime="$stage_prefix/lib/node_modules/openclaw"
previous_runtime="$runtime_parent/openclaw.previous-$stamp"
failed_runtime="$runtime_parent/openclaw.failed-$stamp"
bin_link="$PREFIX/bin/openclaw"
original_bin_target="$(readlink "$bin_link")"

if ! "$NPM_BIN" install --global --prefix "$stage_prefix" "$ARTIFACT"; then echo "Candidate staging failed; preserved at: $stage_prefix" >&2; exit 1; fi
[[ -f "$staged_runtime/package.json" && -f "$staged_runtime/openclaw.mjs" ]] || { echo "Staged candidate is invalid: $stage_prefix" >&2; exit 1; }
OPENCLAW_STATE_DIR="$stage_prefix/state" OPENCLAW_CONFIG_PATH="$stage_prefix/openclaw.json" "$stage_prefix/bin/openclaw" --version >/dev/null

transaction_active=false; original_saved=false; candidate_active=false; recovering=false
restore_previous() {
  local reason="$1" ok=true
  $recovering && return 1
  recovering=true
  trap - ERR INT TERM EXIT
  echo "Recovery required after $reason; restoring exact pre-install runtime/service state." >&2
  # Reconcile filesystem state first: a signal can arrive after an atomic mv
  # returns but before its bookkeeping assignment executes.
  [[ -d "$previous_runtime" ]] && original_saved=true
  if $original_saved && [[ -e "$RUNTIME_DIR" ]]; then candidate_active=true; fi
  "$RUNTIME_SYSTEMCTL_BIN" --user stop "$RUNTIME_SERVICE" >/dev/null 2>&1 || true
  if $candidate_active && [[ -e "$RUNTIME_DIR" ]]; then mv "$RUNTIME_DIR" "$failed_runtime" || ok=false; fi
  if $original_saved; then
    [[ ! -e "$RUNTIME_DIR" && -d "$previous_runtime" ]] && mv "$previous_runtime" "$RUNTIME_DIR" || ok=false
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
    if $initial_running; then
      echo "Automatic recovery verified the prior active path and structured health/service state." >&2
    else
      echo "Automatic recovery verified the prior active path and stopped service state." >&2
    fi
    echo "Pre-install backup remains available at: $backup_archive" >&2
    return 0
  fi
  echo "CRITICAL: automatic recovery could not verify exact runtime/service restoration. Stop and escalate; do not retry." >&2
  return 1
}
abort_transaction() {
  local source="$1" rc="$2"
  trap - ERR INT TERM EXIT
  if $transaction_active; then
    if ! restore_previous "$source"; then cleanup_artifact_snapshot; exit 3; fi
  fi
  cleanup_artifact_snapshot
  case "$source" in INT) exit 130 ;; TERM) exit 143 ;; *) exit "$rc" ;; esac
}
trap 'abort_transaction ERR $?' ERR
trap 'abort_transaction INT 130' INT
trap 'abort_transaction TERM 143' TERM
trap 'rc=$?; if $transaction_active; then abort_transaction EXIT "$rc"; else cleanup_artifact_snapshot; fi' EXIT

transaction_active=true
runtime_test_hook before-stop
"$RUNTIME_SYSTEMCTL_BIN" --user stop "$RUNTIME_SERVICE"
runtime_test_hook after-stop
mv "$RUNTIME_DIR" "$previous_runtime"
runtime_test_hook after-move-original
original_saved=true
mv "$staged_runtime" "$RUNTIME_DIR"
runtime_test_hook after-activate-candidate
candidate_active=true
ln -sfn ../lib/node_modules/openclaw/openclaw.mjs "$bin_link"
runtime_test_hook after-link
runtime_verify_active_path "$RUNTIME_DIR" "$bin_link"
if $initial_running; then
  "$RUNTIME_SYSTEMCTL_BIN" --user start "$RUNTIME_SERVICE"
  runtime_test_hook after-start
  runtime_wait_for_structured_health
  runtime_test_hook after-health
else
  runtime_service_is_running && { echo "Service unexpectedly running after stopped-state install." >&2; false; }
  runtime_test_hook after-stopped-verify
fi

transaction_active=false
trap - ERR INT TERM EXIT
cleanup_artifact_snapshot
rm -rf "$stage_prefix"
echo "Candidate installation succeeded; active path and required service state were verified."
echo "Pre-install archive: $backup_archive"
echo "Previous runtime preserved at: $previous_runtime"
