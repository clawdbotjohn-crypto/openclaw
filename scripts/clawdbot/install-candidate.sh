#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'USAGE'
Usage: install-candidate.sh --artifact FILE [options]

Stage a verified OpenClaw npm tarball, back up the current runtime, atomically
swap the candidate into place, and automatically restore the pre-install
runtime if service startup or health checks fail.

Safety defaults:
  * Without --apply, this is a validation-only dry run and mutates nothing.
  * Mutation requires both --apply and --yes.
  * The active global runtime additionally requires --allow-live-runtime.

Options:
  --artifact FILE          Candidate npm .tgz (required)
  --checksum FILE          SHA-256 file (default: FILE.sha256; required)
  --prefix DIR             npm prefix containing lib/node_modules/openclaw
  --runtime-dir DIR        Runtime target (must match PREFIX layout)
  --release-dir DIR        Backup directory (default: ~/.openclaw/releases)
  --service NAME           User service (default: openclaw-gateway.service)
  --health-url URL         Health endpoint (default: http://127.0.0.1:18789/healthz)
  --apply                  Permit mutation after validation
  --yes                    Confirm the requested mutation
  --allow-live-runtime     Explicitly permit the active global runtime target
  -h, --help               Show this help

Test hooks (environment only; do not use for a live install):
  OPENCLAW_NPM_BIN, OPENCLAW_SYSTEMCTL_BIN, OPENCLAW_CURL_BIN,
  OPENCLAW_HEALTH_ATTEMPTS, OPENCLAW_HEALTH_INTERVAL_SECONDS
USAGE
}

ARTIFACT=""
CHECKSUM=""
PREFIX=""
RUNTIME_DIR=""
RELEASE_DIR="${OPENCLAW_RELEASE_DIR:-$HOME/.openclaw/releases}"
SERVICE="openclaw-gateway.service"
HEALTH_URL="http://127.0.0.1:18789/healthz"
APPLY=false
CONFIRMED=false
ALLOW_LIVE=false
NPM_BIN="${OPENCLAW_NPM_BIN:-npm}"
SYSTEMCTL_BIN="${OPENCLAW_SYSTEMCTL_BIN:-systemctl}"
CURL_BIN="${OPENCLAW_CURL_BIN:-curl}"
HEALTH_ATTEMPTS="${OPENCLAW_HEALTH_ATTEMPTS:-12}"
HEALTH_INTERVAL_SECONDS="${OPENCLAW_HEALTH_INTERVAL_SECONDS:-5}"

while (($#)); do
  case "$1" in
    --artifact) ARTIFACT="${2:?missing value for --artifact}"; shift 2 ;;
    --checksum) CHECKSUM="${2:?missing value for --checksum}"; shift 2 ;;
    --prefix) PREFIX="${2:?missing value for --prefix}"; shift 2 ;;
    --runtime-dir) RUNTIME_DIR="${2:?missing value for --runtime-dir}"; shift 2 ;;
    --release-dir) RELEASE_DIR="${2:?missing value for --release-dir}"; shift 2 ;;
    --service) SERVICE="${2:?missing value for --service}"; shift 2 ;;
    --health-url) HEALTH_URL="${2:?missing value for --health-url}"; shift 2 ;;
    --apply) APPLY=true; shift ;;
    --yes) CONFIRMED=true; shift ;;
    --allow-live-runtime) ALLOW_LIVE=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -n "$ARTIFACT" ]] || { echo "--artifact is required." >&2; exit 2; }
[[ -f "$ARTIFACT" ]] || { echo "Artifact not found: $ARTIFACT" >&2; exit 1; }
ARTIFACT="$(readlink -f "$ARTIFACT")"
CHECKSUM="${CHECKSUM:-${ARTIFACT}.sha256}"
[[ -f "$CHECKSUM" ]] || { echo "Checksum file is required: $CHECKSUM" >&2; exit 1; }
CHECKSUM="$(readlink -f "$CHECKSUM")"
[[ "$HEALTH_ATTEMPTS" =~ ^[1-9][0-9]*$ ]] || { echo "Invalid OPENCLAW_HEALTH_ATTEMPTS." >&2; exit 2; }
[[ "$HEALTH_INTERVAL_SECONDS" =~ ^[0-9]+([.][0-9]+)?$ ]] || {
  echo "Invalid OPENCLAW_HEALTH_INTERVAL_SECONDS." >&2
  exit 2
}

expected_sha="$(awk 'NF {print $1; exit}' "$CHECKSUM")"
[[ "$expected_sha" =~ ^[[:xdigit:]]{64}$ ]] || { echo "Invalid SHA-256 file: $CHECKSUM" >&2; exit 1; }
actual_sha="$(sha256sum "$ARTIFACT" | awk '{print $1}')"
[[ "${actual_sha,,}" == "${expected_sha,,}" ]] || {
  echo "Artifact checksum mismatch: expected $expected_sha, got $actual_sha" >&2
  exit 1
}

package_json=false
entrypoint=false
while IFS= read -r entry; do
  case "$entry" in
    package/package.json) package_json=true ;;
    package/openclaw.mjs) entrypoint=true ;;
  esac
done < <(tar -tzf "$ARTIFACT")
$package_json && $entrypoint || { echo "Artifact is not a valid OpenClaw npm package." >&2; exit 1; }

GLOBAL_PREFIX="$($NPM_BIN prefix --global)"
GLOBAL_RUNTIME="$GLOBAL_PREFIX/lib/node_modules/openclaw"
if [[ -z "$PREFIX" && -z "$RUNTIME_DIR" ]]; then
  PREFIX="$GLOBAL_PREFIX"
elif [[ -z "$PREFIX" ]]; then
  PREFIX="$(cd "$(dirname "$(dirname "$(dirname "$RUNTIME_DIR")")")" && pwd)"
fi
[[ -d "$PREFIX" ]] || { echo "Target prefix does not exist: $PREFIX" >&2; exit 1; }
PREFIX="$(cd "$PREFIX" && pwd)"
EXPECTED_RUNTIME="$PREFIX/lib/node_modules/openclaw"
RUNTIME_DIR="${RUNTIME_DIR:-$EXPECTED_RUNTIME}"
[[ "$RUNTIME_DIR" = /* ]] || RUNTIME_DIR="$(pwd)/$RUNTIME_DIR"
[[ "$RUNTIME_DIR" == "$EXPECTED_RUNTIME" ]] || {
  echo "Runtime target must be PREFIX/lib/node_modules/openclaw: $EXPECTED_RUNTIME" >&2
  exit 2
}
[[ -f "$RUNTIME_DIR/package.json" && -f "$RUNTIME_DIR/openclaw.mjs" ]] || {
  echo "Current runtime is not a valid OpenClaw installation: $RUNTIME_DIR" >&2
  exit 1
}

is_live=false
if [[ "$(readlink -f "$RUNTIME_DIR")" == "$(readlink -f "$GLOBAL_RUNTIME")" ]]; then
  is_live=true
fi

cat <<PLAN
Candidate install plan
  artifact:       $ARTIFACT
  artifact sha:   $actual_sha
  target runtime: $RUNTIME_DIR
  backup dir:     $RELEASE_DIR
  service:        $SERVICE
  health URL:     $HEALTH_URL
  global/live:    $is_live
PLAN

if ! $APPLY; then
  echo "DRY RUN ONLY: validation passed; no files or services were changed."
  exit 0
fi
$CONFIRMED || { echo "Refusing mutation: --apply also requires --yes." >&2; exit 2; }
if $is_live && ! $ALLOW_LIVE; then
  echo "Refusing active global runtime mutation without --allow-live-runtime." >&2
  exit 2
fi

mkdir -p "$RELEASE_DIR" "$PREFIX/lib/node_modules" "$PREFIX/bin"
exec 9>"$RELEASE_DIR/.candidate-install.lock"
flock -n 9 || { echo "Another candidate install is already running." >&2; exit 1; }

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
backup_output="$($script_dir/backup-runtime.sh --output-dir "$RELEASE_DIR" --runtime-dir "$RUNTIME_DIR" --yes)"
printf '%s\n' "$backup_output"
backup_archive="$(printf '%s\n' "$backup_output" | sed -n 's/^Backup complete: //p' | tail -1)"
[[ -n "$backup_archive" && -f "$backup_archive" ]] || {
  echo "Could not identify completed pre-install backup." >&2
  exit 1
}

stamp="$(date -u +%Y%m%dT%H%M%SZ)-$$"
runtime_parent="$(dirname "$RUNTIME_DIR")"
stage_prefix="$runtime_parent/.openclaw-candidate-stage-$stamp"
staged_runtime="$stage_prefix/lib/node_modules/openclaw"
previous_runtime="$runtime_parent/openclaw.previous-$stamp"
failed_runtime="$runtime_parent/openclaw.failed-$stamp"
bin_link="$PREFIX/bin/openclaw"

if ! "$NPM_BIN" install --global --prefix "$stage_prefix" "$ARTIFACT"; then
  echo "Candidate staging failed; diagnostic stage preserved at: $stage_prefix" >&2
  exit 1
fi
[[ -f "$staged_runtime/package.json" && -f "$staged_runtime/openclaw.mjs" ]] || {
  echo "Staged candidate is invalid; preserved at: $stage_prefix" >&2
  exit 1
}
OPENCLAW_STATE_DIR="$stage_prefix/state" OPENCLAW_CONFIG_PATH="$stage_prefix/openclaw.json" \
  "$stage_prefix/bin/openclaw" --version >/dev/null

health_ok() {
  "$SYSTEMCTL_BIN" --user is-active --quiet "$SERVICE" &&
    "$CURL_BIN" --silent --fail --max-time 3 "$HEALTH_URL" >/dev/null 2>&1
}

transaction_active=false
rollback_candidate() {
  local rollback_healthy=false
  echo "Candidate failed health checks; automatically restoring the pre-install runtime." >&2
  "$SYSTEMCTL_BIN" --user stop "$SERVICE" || true
  if [[ -e "$RUNTIME_DIR" ]]; then
    mv "$RUNTIME_DIR" "$failed_runtime"
  fi
  if [[ ! -d "$previous_runtime" ]]; then
    echo "Automatic rollback failed: pre-install runtime is missing at $previous_runtime" >&2
    return 1
  fi
  mv "$previous_runtime" "$RUNTIME_DIR"
  ln -sfn ../lib/node_modules/openclaw/openclaw.mjs "$bin_link"
  "$SYSTEMCTL_BIN" --user start "$SERVICE" || true
  for ((attempt=1; attempt<=HEALTH_ATTEMPTS; attempt++)); do
    if health_ok; then
      rollback_healthy=true
      break
    fi
    sleep "$HEALTH_INTERVAL_SECONDS"
  done
  if ! $rollback_healthy; then
    echo "CRITICAL: pre-install runtime was restored on disk but did not become healthy." >&2
    return 1
  fi
  echo "Automatic rollback succeeded. Failed candidate preserved at: $failed_runtime" >&2
  echo "Pre-install backup remains available at: $backup_archive" >&2
  return 0
}

on_unexpected_error() {
  local rc=$?
  trap - ERR
  if $transaction_active; then
    transaction_active=false
    rollback_candidate || exit 3
  fi
  exit "$rc"
}
trap on_unexpected_error ERR

"$SYSTEMCTL_BIN" --user stop "$SERVICE"
mv "$RUNTIME_DIR" "$previous_runtime"
transaction_active=true
mv "$staged_runtime" "$RUNTIME_DIR"
ln -sfn ../lib/node_modules/openclaw/openclaw.mjs "$bin_link"

candidate_healthy=false
if "$SYSTEMCTL_BIN" --user start "$SERVICE"; then
  for ((attempt=1; attempt<=HEALTH_ATTEMPTS; attempt++)); do
    if health_ok; then
      candidate_healthy=true
      break
    fi
    sleep "$HEALTH_INTERVAL_SECONDS"
  done
fi

if ! $candidate_healthy; then
  transaction_active=false
  rollback_candidate || exit 3
  exit 1
fi

transaction_active=false
rm -rf "$stage_prefix"
echo "Candidate installation succeeded."
echo "Pre-install archive: $backup_archive"
echo "Previous runtime preserved at: $previous_runtime"
