#!/usr/bin/env bash
# Shared fail-closed helpers for the OpenClaw runtime maintenance scripts.
# This file is sourced; callers remain responsible for `set -Eeuo pipefail`.

runtime_die() {
  echo "$*" >&2
  return 1
}

runtime_canonical_path() {
  readlink -f -- "$1"
}

runtime_validate_owned_directory() {
  local directory="$1" canonical owner mode
  [[ -d "$directory" && ! -L "$directory" ]] || runtime_die "Required directory is missing or is a symlink: $directory" || return
  canonical="$(readlink -f -- "$directory")" || runtime_die "Cannot canonicalize directory: $directory" || return
  [[ "$canonical" == "$directory" ]] || runtime_die "Directory must be supplied by its canonical path: $directory" || return
  owner="$(stat -c %u -- "$directory")"
  [[ "$owner" == "$(id -u)" ]] || runtime_die "Directory is not owned by the current user: $directory" || return
  mode="$(stat -c %a -- "$directory")"
  # Group collaboration is permitted, but a transaction parent must never be
  # writable by unrelated users. Exclusive 0700 children provide the boundary.
  (( (8#$mode & 0002) == 0 )) || runtime_die "Transaction parent is writable by other users: $directory" || return
}

runtime_make_private_tx_dir() {
  local parent="$1" prefix="$2" result
  runtime_validate_owned_directory "$parent" || return
  [[ "$prefix" =~ ^[A-Za-z0-9._-]+$ ]] || runtime_die "Invalid transaction prefix." || return
  result="$(mktemp -d "$parent/.${prefix}.XXXXXX")" || runtime_die "Could not create private transaction directory in $parent" || return
  chmod 700 "$result" || { rm -rf -- "$result"; return 1; }
  [[ ! -L "$result" && "$(stat -c %u:%a -- "$result")" == "$(id -u):700" ]] || {
    rm -rf -- "$result"
    runtime_die "Private transaction directory validation failed."
    return
  }
  printf '%s\n' "$result"
}

runtime_validate_checksum() {
  local archive="$1" checksum_file="$2"
  [[ -f "$checksum_file" ]] || runtime_die "Checksum file is required: $checksum_file" || return

  local nonempty_count hash recorded extra
  nonempty_count="$(awk 'NF { count++ } END { print count + 0 }' "$checksum_file")"
  [[ "$nonempty_count" == 1 ]] || runtime_die "Checksum file must contain exactly one non-empty record: $checksum_file" || return
  read -r hash recorded extra < <(awk 'NF { print; exit }' "$checksum_file")
  [[ -z "${extra:-}" && "$hash" =~ ^[[:xdigit:]]{64}$ && -n "${recorded:-}" ]] ||
    runtime_die "Malformed SHA-256 record: $checksum_file" || return
  recorded="${recorded#\*}"
  [[ "$recorded" == "$(basename "$archive")" ]] ||
    runtime_die "Checksum record names '$recorded', expected '$(basename "$archive")'." || return

  local actual
  actual="$(sha256sum "$archive" | awk '{print $1}')"
  [[ "${actual,,}" == "${hash,,}" ]] ||
    runtime_die "Archive checksum mismatch: expected $hash, got $actual" || return
  RUNTIME_VALIDATED_SHA256="${actual,,}"
}

runtime_metadata_value() {
  local metadata="$1" key="$2"
  awk -F= -v wanted="$key" '$1 == wanted { count++; value=substr($0, index($0, "=") + 1) } END { if (count == 1) print value; else exit 1 }' "$metadata"
}

runtime_validate_provenance() {
  local metadata="$1" expected_repository="$2" expected_ref="$3" expected_sha="$4" artifact="$5" artifact_sha="$6"
  [[ -f "$metadata" ]] || runtime_die "Build metadata is required: $metadata" || return
  [[ "$expected_repository" =~ ^[^/[:space:]]+/[^/[:space:]]+$ ]] || runtime_die "Invalid expected repository." || return
  [[ "$expected_ref" == refs/heads/* && "$expected_ref" != refs/pull/* && "$expected_ref" != *"/pull/"* ]] ||
    runtime_die "Expected promotable ref must be an explicit refs/heads/* ref, never a pull ref." || return
  [[ "$expected_sha" =~ ^[[:xdigit:]]{40}$ ]] || runtime_die "Expected SHA must be an exact 40-character commit SHA." || return

  local repository ref sha event_name tarball package_sha
  repository="$(runtime_metadata_value "$metadata" repository)" || runtime_die "Metadata repository is missing or ambiguous." || return
  ref="$(runtime_metadata_value "$metadata" ref)" || runtime_die "Metadata ref is missing or ambiguous." || return
  sha="$(runtime_metadata_value "$metadata" sha)" || runtime_die "Metadata sha is missing or ambiguous." || return
  event_name="$(runtime_metadata_value "$metadata" event_name)" || runtime_die "Metadata event_name is missing or ambiguous." || return
  tarball="$(runtime_metadata_value "$metadata" tarball)" || runtime_die "Metadata tarball is missing or ambiguous." || return
  package_sha="$(runtime_metadata_value "$metadata" package_sha256)" || runtime_die "Metadata package_sha256 is missing or ambiguous." || return

  [[ "$ref" != refs/pull/* && "$ref" != *"/pull/"* ]] || runtime_die "Pull-ref artifacts are not promotable: $ref" || return
  [[ "$event_name" == push ]] || runtime_die "Only post-merge push artifacts are promotable; metadata event is '$event_name'." || return
  [[ "$repository" == "$expected_repository" ]] || runtime_die "Metadata repository mismatch: $repository" || return
  [[ "$ref" == "$expected_ref" ]] || runtime_die "Metadata ref mismatch: $ref" || return
  [[ "${sha,,}" == "${expected_sha,,}" ]] || runtime_die "Metadata SHA mismatch: $sha" || return
  [[ "$tarball" == "$(basename "$artifact")" ]] || runtime_die "Metadata tarball mismatch: $tarball" || return
  [[ "$package_sha" =~ ^[[:xdigit:]]{64}$ && "${package_sha,,}" == "${artifact_sha,,}" ]] ||
    runtime_die "Metadata package checksum mismatch." || return
}

runtime_archive_list() {
  local archive="$1" output="$2"
  [[ -f "$archive" ]] || runtime_die "Archive is missing: $archive" || return
  [[ ! -e "$output" && ! -L "$output" ]] || runtime_die "Archive-list output already exists: $output" || return
  ( umask 077; : > "$output" ) || return
  if ! tar -tzf "$archive" > "$output"; then
    echo "Archive listing failed: $archive" >&2
    return 1
  fi
  [[ -s "$output" ]] || runtime_die "Archive is empty: $archive" || return
}

runtime_validate_health_json() {
  local file="$1" node_bin="${OPENCLAW_NODE_BIN:-node}"
  "$node_bin" - "$file" <<'NODE'
const fs = require("node:fs");
const file = process.argv[2];
let value;
try { value = JSON.parse(fs.readFileSync(file, "utf8")); } catch { process.exit(2); }
const object = (v) => v !== null && typeof v === "object" && !Array.isArray(v);
const valid = object(value) && value.ok === true &&
  Number.isFinite(value.ts) && value.ts > 0 &&
  Number.isFinite(value.durationMs) && value.durationMs >= 0 &&
  object(value.channels) && Array.isArray(value.channelOrder) &&
  object(value.channelLabels) && typeof value.defaultAgentId === "string" && value.defaultAgentId.length > 0 &&
  Array.isArray(value.agents) && value.agents.length > 0 &&
  object(value.sessions) && typeof value.sessions.path === "string" &&
  Number.isInteger(value.sessions.count) && value.sessions.count >= 0 && Array.isArray(value.sessions.recent);
process.exit(valid ? 0 : 3);
NODE
}

# Tri-state service capture. Only an exact `active`/0 is running and only an
# exact `inactive` (or compatibility `stopped`)/3 is stopped. failed,
# activating, deactivating, unknown, malformed output, and all query errors are
# unknown and must abort before mutation.
runtime_capture_service_state() {
  local load output load_rc rc
  set +e
  load="$("$RUNTIME_SYSTEMCTL_BIN" --user show --property=LoadState --value "$RUNTIME_SERVICE" 2>/dev/null)"
  load_rc=$?
  output="$("$RUNTIME_SYSTEMCTL_BIN" --user is-active "$RUNTIME_SERVICE" 2>/dev/null)"
  rc=$?
  set -e
  load="${load%$'\n'}"
  output="${output%$'\n'}"
  # `is-active` alone is insufficient: systemd can report an unknown unit as
  # `inactive`/3. Require a separate, exact LoadState=loaded proof.
  if [[ "$load_rc" != 0 || "$load" != loaded ]]; then
    RUNTIME_SERVICE_STATE=unknown
    echo "Cannot prove loaded service $RUNTIME_SERVICE (status=$load_rc output=${load:-<empty>}); refusing mutation." >&2
    return 1
  fi
  case "$rc:$output" in
    0:active) RUNTIME_SERVICE_STATE=active; return 0 ;;
    3:inactive|3:stopped) RUNTIME_SERVICE_STATE=inactive; return 0 ;;
    *)
      RUNTIME_SERVICE_STATE=unknown
      echo "Cannot prove service state for $RUNTIME_SERVICE (status=$rc output=${output:-<empty>}); refusing mutation." >&2
      return 1
      ;;
  esac
}

runtime_require_service_state() {
  local expected="$1"
  runtime_capture_service_state || return
  [[ "$RUNTIME_SERVICE_STATE" == "$expected" ]] || runtime_die "Service state is '$RUNTIME_SERVICE_STATE', expected '$expected'." || return
}

runtime_structured_health_once() {
  runtime_require_service_state active || return 1
  local output
  output="$(mktemp "${TMPDIR:-/tmp}/openclaw-health.XXXXXX")" || return 1
  if ! "$RUNTIME_HEALTH_BIN" health --json --timeout "$RUNTIME_HEALTH_TIMEOUT_MS" >"$output" 2>/dev/null; then
    rm -f "$output"
    return 1
  fi
  if ! runtime_validate_health_json "$output"; then
    rm -f "$output"
    return 1
  fi
  rm -f "$output"
}

runtime_wait_for_structured_health() {
  local attempt
  for ((attempt=1; attempt<=RUNTIME_HEALTH_ATTEMPTS; attempt++)); do
    runtime_structured_health_once && return 0
    (( attempt == RUNTIME_HEALTH_ATTEMPTS )) || sleep "$RUNTIME_HEALTH_INTERVAL_SECONDS"
  done
  return 1
}

runtime_verify_active_path() {
  local runtime_dir="$1" bin_link="$2"
  [[ -f "$runtime_dir/package.json" && -f "$runtime_dir/openclaw.mjs" && -e "$bin_link" ]] || return 1
  [[ "$(readlink -f "$bin_link")" == "$(readlink -f "$runtime_dir/openclaw.mjs")" ]]
}

runtime_bind_health_to_runtime() {
  local runtime_dir="$1" health_bin="$2" canonical_runtime canonical_entry canonical_health
  canonical_runtime="$(readlink -f -- "$runtime_dir")" || runtime_die "Cannot canonicalize runtime: $runtime_dir" || return
  [[ -d "$canonical_runtime" && ! -L "$canonical_runtime" ]] || runtime_die "Runtime is not a canonical directory: $runtime_dir" || return
  canonical_entry="$(readlink -f -- "$canonical_runtime/openclaw.mjs")" || runtime_die "Runtime entrypoint is missing." || return
  canonical_health="$(readlink -f -- "$health_bin")" || runtime_die "Health CLI cannot be canonicalized: $health_bin" || return
  [[ "$canonical_entry" == "$canonical_runtime/openclaw.mjs" ]] || runtime_die "Runtime entrypoint escapes the runtime directory." || return
  [[ "$canonical_health" == "$canonical_entry" ]] || runtime_die "Health CLI is not bound to the runtime being archived: $canonical_health != $canonical_entry" || return
  [[ -x "$canonical_entry" ]] || runtime_die "Bound runtime health entrypoint is not executable." || return
  RUNTIME_BOUND_ENTRYPOINT="$canonical_entry"
}

runtime_tree_digest() {
  local directory="$1"
  tar --sort=name --mtime='UTC 1970-01-01' --owner=0 --group=0 --numeric-owner -C "$directory" -cf - . | sha256sum | awk '{print $1}'
}

runtime_restore_service_state() {
  local desired="$1"
  runtime_capture_service_state || return 1
  if [[ "$desired" == active ]]; then
    if [[ "$RUNTIME_SERVICE_STATE" == inactive ]]; then
      "$RUNTIME_SYSTEMCTL_BIN" --user start "$RUNTIME_SERVICE" || return 1
      runtime_require_service_state active || return 1
    fi
    runtime_wait_for_structured_health
  else
    if [[ "$RUNTIME_SERVICE_STATE" == active ]]; then
      "$RUNTIME_SYSTEMCTL_BIN" --user stop "$RUNTIME_SERVICE" || return 1
      runtime_require_service_state inactive || return 1
    fi
    [[ "$RUNTIME_SERVICE_STATE" == inactive ]]
  fi
}

runtime_acquire_lock() {
  local lock_file="$1" requested_fd="${2:-}"
  mkdir -p "$(dirname "$lock_file")"
  lock_file="$(readlink -m "$lock_file")"
  if [[ -n "$requested_fd" ]]; then
    [[ "$requested_fd" =~ ^[0-9]+$ && -e "/proc/$$/fd/$requested_fd" ]] || runtime_die "Invalid inherited lock descriptor." || return
    [[ "$(readlink -f "/proc/$$/fd/$requested_fd")" == "$lock_file" ]] || runtime_die "Inherited lock does not match $lock_file." || return
    flock -n "$requested_fd" || runtime_die "Shared runtime lock is not held." || return
    RUNTIME_LOCK_FD="$requested_fd"
    return 0
  fi
  exec {RUNTIME_LOCK_FD}>"$lock_file"
  flock -n "$RUNTIME_LOCK_FD" || runtime_die "Another runtime backup, install, or rollback is already running." || return
}

runtime_test_hook() {
  local phase="$1" mode="${OPENCLAW_TEST_HOOK_MODE:-}" wanted="${OPENCLAW_TEST_HOOK_PHASE:-}"
  [[ -n "$mode" && "$phase" == "$wanted" ]] || return 0
  [[ "${OPENCLAW_TEST_MODE:-}" == 1 && -n "${OPENCLAW_TEST_ROOT:-}" ]] || runtime_die "Refusing test hook outside explicit test mode." || return
  local test_root runtime_path
  test_root="$(readlink -m "$OPENCLAW_TEST_ROOT")"
  runtime_path="$(readlink -m "$RUNTIME_DIR")"
  [[ "$test_root" == /tmp/* && "$runtime_path" == "$test_root"/* ]] || runtime_die "Refusing test hook outside an isolated /tmp root." || return
  echo "TEST HOOK: $mode at $phase" >&2
  case "$mode" in
    ERR) return 97 ;;
    INT) kill -INT "$$"; return 97 ;;
    TERM) kill -TERM "$$"; return 97 ;;
    EXIT) exit 97 ;;
    *) runtime_die "Unknown test hook mode: $mode" ;;
  esac
}

runtime_test_repeated_recovery_signals() {
  [[ "${OPENCLAW_TEST_RECOVERY_SIGNALS:-}" == repeated ]] || return 0
  [[ "${OPENCLAW_TEST_MODE:-}" == 1 && "$(readlink -m "${OPENCLAW_TEST_ROOT:-/}")" == /tmp/* ]] ||
    runtime_die "Refusing recovery signal hook outside explicit test mode." || return
  kill -INT "$$"
  kill -TERM "$$"
}
