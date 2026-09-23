#!/usr/bin/env bash
set -Eeuo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=runtime-common.sh
source "$script_dir/runtime-common.sh"

usage() {
  cat <<'USAGE'
Usage: backup-runtime.sh [options] --yes

Snapshot and archive the complete installed OpenClaw runtime. Promotable backup
health is fail-closed: --health-bin must canonically resolve to that runtime's
own openclaw.mjs, the private immutable snapshot is probed, and only that exact
snapshot is archived. A CLI from another runtime can never promote pointers.

Options:
  --output-dir DIR       Archive directory (default: ~/.openclaw/releases)
  --runtime-dir DIR      Installed OpenClaw directory (auto-detected)
  --service NAME         User service (default: openclaw-gateway.service)
  --health-bin PATH      Active CLI symlink bound to RUNTIME/openclaw.mjs
  --no-promote-current-good
                         Create a pre-change archive but preserve known-good
                         pointers (used only for an explicitly stopped service)
  --yes                  Required acknowledgement
  -h, --help             Show this help
USAGE
}

OUTPUT_DIR="${OPENCLAW_RELEASE_DIR:-$HOME/.openclaw/releases}"
RUNTIME_DIR="${OPENCLAW_RUNTIME_DIR:-}"
RUNTIME_SERVICE="openclaw-gateway.service"
RUNTIME_SYSTEMCTL_BIN="${OPENCLAW_SYSTEMCTL_BIN:-systemctl}"
RUNTIME_HEALTH_BIN="${OPENCLAW_HEALTH_BIN:-}"
RUNTIME_HEALTH_TIMEOUT_MS="${OPENCLAW_HEALTH_TIMEOUT_MS:-10000}"
RUNTIME_HEALTH_ATTEMPTS=1
RUNTIME_HEALTH_INTERVAL_SECONDS=0
CONFIRMED=false
PROMOTE=true
LOCK_FD=""
while (($#)); do
  case "$1" in
    --output-dir) OUTPUT_DIR="${2:?missing value for --output-dir}"; shift 2 ;;
    --runtime-dir) RUNTIME_DIR="${2:?missing value for --runtime-dir}"; shift 2 ;;
    --service) RUNTIME_SERVICE="${2:?missing value for --service}"; shift 2 ;;
    --health-bin) RUNTIME_HEALTH_BIN="${2:?missing value for --health-bin}"; shift 2 ;;
    --no-promote-current-good) PROMOTE=false; shift ;;
    --lock-fd) LOCK_FD="${2:?missing value for --lock-fd}"; shift 2 ;;
    --yes) CONFIRMED=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done
$CONFIRMED || { echo "Refusing to create a large archive without --yes." >&2; exit 2; }

if [[ -z "$RUNTIME_DIR" ]]; then
  prefix="$(npm prefix --global)"
  RUNTIME_DIR="$prefix/lib/node_modules/openclaw"
else
  RUNTIME_DIR="$(readlink -f -- "$RUNTIME_DIR")"
  prefix="$(dirname "$(dirname "$(dirname "$RUNTIME_DIR")")")"
fi
RUNTIME_DIR="$(readlink -f -- "$RUNTIME_DIR")"
RUNTIME_HEALTH_BIN="${RUNTIME_HEALTH_BIN:-$prefix/bin/openclaw}"
[[ -d "$RUNTIME_DIR" && ! -L "$RUNTIME_DIR" && -f "$RUNTIME_DIR/package.json" && -f "$RUNTIME_DIR/openclaw.mjs" ]] || {
  echo "Directory does not look like a canonical OpenClaw runtime: $RUNTIME_DIR" >&2
  exit 1
}
[[ "$RUNTIME_HEALTH_TIMEOUT_MS" =~ ^[1-9][0-9]*$ ]] || { echo "Invalid health timeout." >&2; exit 2; }
runtime_bind_health_to_runtime "$RUNTIME_DIR" "$RUNTIME_HEALTH_BIN"
source_health_bin="$RUNTIME_HEALTH_BIN"

mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd -P)"
runtime_validate_owned_directory "$OUTPUT_DIR"
runtime_acquire_lock "$OUTPUT_DIR/.runtime.lock" "$LOCK_FD"
runtime_capture_service_state
initial_service_state="$RUNTIME_SERVICE_STATE"
if $PROMOTE && [[ "$initial_service_state" != active ]]; then
  echo "Promotable backup requires an explicitly active service; preserving current-good pointers." >&2
  exit 1
fi
if ! $PROMOTE && [[ "$initial_service_state" != inactive ]]; then
  echo "Non-promotable stopped-state backup requires an explicitly inactive service." >&2
  exit 1
fi

runtime_bytes="$(du -sb "$RUNTIME_DIR" | awk '{print $1}')"
available_bytes="$(df -PB1 "$OUTPUT_DIR" | awk 'NR==2 {print $4}')"
required_bytes=$((runtime_bytes * 3))
if (( available_bytes < required_bytes )); then
  echo "Insufficient free space: need at least $required_bytes bytes; have $available_bytes." >&2
  exit 1
fi

version="$(node -e 'const p=require(process.argv[1]); process.stdout.write(String(p.version||"unknown"))' "$RUNTIME_DIR/package.json")"
timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
tx_dir="$(runtime_make_private_tx_dir "$OUTPUT_DIR" openclaw-backup-tx)"
script_pid="$BASHPID"
archive=""; checksum=""; manifest=""
trap 'rc=$?; if [[ "$BASHPID" == "$script_pid" && "$rc" != 0 ]]; then rm -rf -- "$tx_dir"; [[ -z "$archive" ]] || rm -f -- "$archive" "$checksum" "$manifest"; fi' EXIT
snapshot_parent="$tx_dir/snapshot"
snapshot_runtime="$snapshot_parent/openclaw"
mkdir -m 700 "$snapshot_parent"
source_digest_before="$(runtime_tree_digest "$RUNTIME_DIR")"
cp -a -- "$RUNTIME_DIR" "$snapshot_runtime"
runtime_test_hook after-runtime-snapshot
source_digest_after="$(runtime_tree_digest "$RUNTIME_DIR")"
snapshot_digest_before="$(runtime_tree_digest "$snapshot_runtime")"
[[ "$source_digest_before" == "$source_digest_after" && "$source_digest_before" == "$snapshot_digest_before" ]] || {
  echo "Runtime changed while its private snapshot was captured; refusing backup." >&2
  rm -rf -- "$tx_dir"
  exit 1
}

# The executable actually probed is inside the immutable tree that will be archived.
RUNTIME_HEALTH_BIN="$snapshot_runtime/openclaw.mjs"
if $PROMOTE; then
  runtime_structured_health_once || {
    echo "Snapshot is not proven healthy by its bound structured CLI/RPC probe; preserving current-good pointers." >&2
    rm -rf -- "$tx_dir"
    exit 1
  }
fi
snapshot_digest_after_health="$(runtime_tree_digest "$snapshot_runtime")"
[[ "$snapshot_digest_before" == "$snapshot_digest_after_health" ]] || {
  echo "Runtime snapshot mutated during health validation; refusing backup." >&2
  rm -rf -- "$tx_dir"
  exit 1
}

archive="$(mktemp "$OUTPUT_DIR/openclaw-${version}-${timestamp}.XXXXXX.tgz")"
chmod 600 "$archive"
partial="$tx_dir/archive.partial"
checksum="${archive}.sha256"
manifest="${archive}.manifest.txt"
list_file="$tx_dir/archive.list"
pointer_dir="$tx_dir/pointers"
pointer_names=(current-good.tgz current-good.tgz.sha256 current-good.tgz.manifest.txt)
pointer_targets=("$(basename "$archive")" "$(basename "$checksum")" "$(basename "$manifest")")
pointer_tx_active=false
recovering=false

pointer_matches_new() {
  local index="$1" link="$OUTPUT_DIR/${pointer_names[$index]}"
  [[ -L "$link" && "$(readlink "$link")" == "${pointer_targets[$index]}" ]]
}
restore_pointers() {
  local index name link old temp ok=true
  $recovering && return 1
  recovering=true
  trap - ERR EXIT
  trap '' INT TERM
  runtime_test_repeated_recovery_signals || true
  echo "Recovering known-good pointers from transaction journal: $pointer_dir" >&2
  for index in "${!pointer_names[@]}"; do
    name="${pointer_names[$index]}"
    link="$OUTPUT_DIR/$name"
    old="$pointer_dir/old/$name"
    runtime_test_hook "before-pointer-restore-$name" || ok=false
    if [[ -e "$old" || -L "$old" ]]; then
      temp="$pointer_dir/restore-$index"
      rm -f -- "$temp"
      cp -a --no-dereference "$old" "$temp" || { ok=false; continue; }
      mv -Tf -- "$temp" "$link" || { ok=false; continue; }
      if [[ -L "$old" ]]; then
        [[ -L "$link" && "$(readlink "$link")" == "$(readlink "$old")" ]] || ok=false
      elif [[ -f "$old" ]]; then
        [[ -f "$link" && ! -L "$link" ]] && cmp -s -- "$old" "$link" || ok=false
      else
        ok=false
      fi
    elif [[ -f "$pointer_dir/absent/$name" ]]; then
      rm -f -- "$link" || ok=false
      [[ ! -e "$link" && ! -L "$link" ]] || ok=false
    else
      ok=false
    fi
    runtime_test_hook "after-pointer-restore-$name" || ok=false
  done
  $ok
}
finish_or_recover_pointer_tx() {
  local source="$1" rc="$2" ok=true
  [[ "$BASHPID" == "$script_pid" ]] || return 0
  trap - ERR INT TERM EXIT
  trap '' INT TERM
  if $pointer_tx_active; then
    if [[ -f "$pointer_dir/committed" ]]; then
      local index
      for index in "${!pointer_names[@]}"; do pointer_matches_new "$index" || ok=false; done
    else
      restore_pointers || ok=false
    fi
  fi
  if ! $ok; then
    echo "CRITICAL: known-good pointer recovery/verification failed. Recovery journal and copies retained at: $tx_dir" >&2
    exit 3
  fi
  rm -rf -- "$tx_dir"
  case "$source" in INT) exit 130 ;; TERM) exit 143 ;; EXIT) exit "$rc" ;; *) exit "$rc" ;; esac
}
echo "Archiving private snapshot of $RUNTIME_DIR ($runtime_bytes bytes)..."
tar -C "$snapshot_parent" -czf "$partial" openclaw
snapshot_digest_after_tar="$(runtime_tree_digest "$snapshot_runtime")"
[[ "$snapshot_digest_before" == "$snapshot_digest_after_tar" ]] || { echo "Runtime snapshot mutated while archived." >&2; false; }
mv -Tf -- "$partial" "$archive"
( umask 077; cd "$OUTPUT_DIR" && sha256sum "$(basename "$archive")" > "$(basename "$checksum")" )
runtime_validate_checksum "$archive" "$checksum"
runtime_archive_list "$archive" "$list_file"
grep -Fxq 'openclaw/package.json' "$list_file" && grep -Fxq 'openclaw/openclaw.mjs' "$list_file" || {
  echo "Validated archive is missing required runtime entries." >&2
  false
}
{
  echo "created_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "hostname=$(hostname)"
  echo "openclaw_version=$version"
  echo "source_runtime=$RUNTIME_DIR"
  echo "bound_health_source=$(readlink -f -- "$source_health_bin")"
  echo "probed_snapshot_entrypoint=openclaw/openclaw.mjs"
  echo "snapshot_tree_sha256=$snapshot_digest_before"
  echo "archive=$archive"
  echo "archive_bytes=$(stat -c %s "$archive")"
  echo "archive_sha256=$RUNTIME_VALIDATED_SHA256"
  echo "node=$(node --version)"
  echo "npm=$(npm --version)"
  echo "known_good_promoted=$PROMOTE"
} > "$manifest"
chmod 600 "$checksum" "$manifest"

if $PROMOTE; then
  trap 'finish_or_recover_pointer_tx ERR $?' ERR
  trap 'finish_or_recover_pointer_tx INT 130' INT
  trap 'finish_or_recover_pointer_tx TERM 143' TERM
  trap 'rc=$?; finish_or_recover_pointer_tx EXIT "$rc"' EXIT
  mkdir -m 700 "$pointer_dir" "$pointer_dir/old" "$pointer_dir/absent" "$pointer_dir/new"
  for index in "${!pointer_names[@]}"; do
    name="${pointer_names[$index]}"
    link="$OUTPUT_DIR/$name"
    if [[ -e "$link" || -L "$link" ]]; then
      cp -a --no-dereference "$link" "$pointer_dir/old/$name"
    else
      : > "$pointer_dir/absent/$name"
    fi
    ln -s "${pointer_targets[$index]}" "$pointer_dir/new/$name"
  done
  pointer_tx_active=true
  runtime_test_hook before-pointer-promotion
  for index in "${!pointer_names[@]}"; do
    name="${pointer_names[$index]}"
    runtime_test_hook "before-pointer-$name"
    mv -Tf -- "$pointer_dir/new/$name" "$OUTPUT_DIR/$name"
    runtime_test_hook "after-pointer-$name"
  done
  for index in "${!pointer_names[@]}"; do pointer_matches_new "$index"; done
  ( umask 077; : > "$pointer_dir/committed" )
  runtime_test_hook after-pointer-commit
  pointer_tx_active=false
  echo "Known-good pointers updated after bound snapshot health and archive validation."
else
  echo "Known-good pointers preserved because the prior service was explicitly stopped."
fi

trap - ERR INT TERM EXIT
rm -rf -- "$tx_dir"
echo "Backup complete: $archive"
echo "Checksum: $RUNTIME_VALIDATED_SHA256"
