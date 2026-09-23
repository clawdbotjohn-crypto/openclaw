#!/usr/bin/env bash
set -Eeuo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=runtime-common.sh
source "$script_dir/runtime-common.sh"

usage() {
  cat <<'USAGE'
Usage: backup-runtime.sh [options] --yes

Archive the complete currently installed OpenClaw runtime. By default, the
running service and structured `openclaw health --json` RPC must both be healthy
before the validated archive atomically replaces current-good.tgz.

Options:
  --output-dir DIR       Archive directory (default: ~/.openclaw/releases)
  --runtime-dir DIR      Installed OpenClaw directory (auto-detected)
  --service NAME         User service (default: openclaw-gateway.service)
  --health-bin PATH      Active OpenClaw CLI (default: PREFIX/bin/openclaw)
  --no-promote-current-good
                         Create a pre-change archive but preserve known-good
                         pointers (used when the prior service was stopped)
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
  prefix="$(cd "$(dirname "$(dirname "$(dirname "$RUNTIME_DIR")")")" && pwd)"
fi
RUNTIME_DIR="$(readlink -f "$RUNTIME_DIR")"
RUNTIME_HEALTH_BIN="${RUNTIME_HEALTH_BIN:-$prefix/bin/openclaw}"
[[ -d "$RUNTIME_DIR" && -f "$RUNTIME_DIR/package.json" && -f "$RUNTIME_DIR/openclaw.mjs" ]] || {
  echo "Directory does not look like an OpenClaw runtime: $RUNTIME_DIR" >&2
  exit 1
}
[[ -x "$RUNTIME_HEALTH_BIN" ]] || { echo "Health CLI is not executable: $RUNTIME_HEALTH_BIN" >&2; exit 1; }
[[ "$RUNTIME_HEALTH_TIMEOUT_MS" =~ ^[1-9][0-9]*$ ]] || { echo "Invalid health timeout." >&2; exit 2; }

mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"
runtime_acquire_lock "$OUTPUT_DIR/.runtime.lock" "$LOCK_FD"

if $PROMOTE; then
  runtime_structured_health_once || {
    echo "Baseline is not proven healthy by the structured CLI/RPC probe; preserving current-good pointers." >&2
    exit 1
  }
fi

runtime_bytes="$(du -sb "$RUNTIME_DIR" | awk '{print $1}')"
available_bytes="$(df -PB1 "$OUTPUT_DIR" | awk 'NR==2 {print $4}')"
required_bytes=$((runtime_bytes * 2))
if (( available_bytes < required_bytes )); then
  echo "Insufficient free space: need at least $required_bytes bytes; have $available_bytes." >&2
  exit 1
fi

version="$(node -e 'const p=require(process.argv[1]); process.stdout.write(String(p.version||"unknown"))' "$RUNTIME_DIR/package.json")"
timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
archive="$OUTPUT_DIR/openclaw-${version}-${timestamp}-$$.tgz"
partial="${archive}.partial"
checksum="${archive}.sha256"
manifest="${archive}.manifest.txt"
runtime_parent="$(dirname "$RUNTIME_DIR")"
runtime_name="$(basename "$RUNTIME_DIR")"
pointer_tx_active=false
pointer_names=(current-good.tgz current-good.tgz.sha256 current-good.tgz.manifest.txt)
pointer_installed=()
pointer_temps=()
cleanup() {
  local name old installed temp
  rm -f "$partial" 2>/dev/null || true
  if $pointer_tx_active; then
    for name in "${pointer_names[@]}"; do
      old="$OUTPUT_DIR/.${name}.pointer-old.$$"
      if [[ -e "$old" || -L "$old" ]]; then
        mv -Tf "$old" "$OUTPUT_DIR/$name" || true
      else
        for installed in "${pointer_installed[@]:-}"; do
          [[ "$installed" == "$name" ]] && rm -f "$OUTPUT_DIR/$name"
        done
      fi
    done
  fi
  for temp in "${pointer_temps[@]:-}"; do [[ -n "$temp" ]] && rm -f "$temp"; done
  for name in "${pointer_names[@]}"; do rm -f "$OUTPUT_DIR/.${name}.pointer-old.$$"; done
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

echo "Archiving $RUNTIME_DIR ($runtime_bytes bytes)..."
tar -C "$runtime_parent" -czf "$partial" "$runtime_name"
mv "$partial" "$archive"
(cd "$OUTPUT_DIR" && sha256sum "$(basename "$archive")" > "$(basename "$checksum")")
runtime_validate_checksum "$archive" "$checksum"
tar -tzf "$archive" >/dev/null
{
  echo "created_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "hostname=$(hostname)"
  echo "openclaw_version=$version"
  echo "source_runtime=$RUNTIME_DIR"
  echo "archive=$archive"
  echo "archive_bytes=$(stat -c %s "$archive")"
  echo "archive_sha256=$RUNTIME_VALIDATED_SHA256"
  echo "node=$(node --version)"
  echo "npm=$(npm --version)"
  echo "known_good_promoted=$PROMOTE"
} > "$manifest"

if $PROMOTE; then
  pointer_targets=("$(basename "$archive")" "$(basename "$checksum")" "$(basename "$manifest")")
  for index in "${!pointer_names[@]}"; do
    temp="$OUTPUT_DIR/.${pointer_names[$index]}.$RANDOM.$$"
    ln -s "${pointer_targets[$index]}" "$temp"
    pointer_temps+=("$temp")
  done
  for index in "${!pointer_names[@]}"; do
    link="$OUTPUT_DIR/${pointer_names[$index]}"
    old="$OUTPUT_DIR/.${pointer_names[$index]}.pointer-old.$$"
    if [[ -e "$link" || -L "$link" ]]; then cp -a --no-dereference "$link" "$old"; fi
  done
  pointer_tx_active=true
  runtime_test_hook before-pointer-promotion
  for index in "${!pointer_names[@]}"; do
    link="$OUTPUT_DIR/${pointer_names[$index]}"
    mv -Tf "${pointer_temps[$index]}" "$link"
    pointer_installed+=("${pointer_names[$index]}")
    runtime_test_hook "after-pointer-${pointer_names[$index]}"
  done
  pointer_tx_active=false
  for name in "${pointer_names[@]}"; do rm -f "$OUTPUT_DIR/.${name}.pointer-old.$$"; done
  echo "Known-good pointers updated after structured baseline health and archive validation."
else
  echo "Known-good pointers preserved because the prior service was stopped."
fi
trap - EXIT INT TERM

echo "Backup complete: $archive"
echo "Checksum: $RUNTIME_VALIDATED_SHA256"
