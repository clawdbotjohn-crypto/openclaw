#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'USAGE'
Usage: backup-runtime.sh [--output-dir DIR] [--runtime-dir DIR] --yes

Archive the complete currently installed OpenClaw runtime without stopping or
restarting the Gateway. The successful archive becomes current-good.tgz.

Options:
  --output-dir DIR  Archive directory (default: ~/.openclaw/releases)
  --runtime-dir DIR Installed OpenClaw directory (auto-detected from npm prefix)
  --yes             Required acknowledgement for the potentially large archive
  -h, --help        Show this help
USAGE
}

OUTPUT_DIR="${OPENCLAW_RELEASE_DIR:-$HOME/.openclaw/releases}"
RUNTIME_DIR="${OPENCLAW_RUNTIME_DIR:-}"
CONFIRMED=false
while (($#)); do
  case "$1" in
    --output-dir) OUTPUT_DIR="${2:?missing value for --output-dir}"; shift 2 ;;
    --runtime-dir) RUNTIME_DIR="${2:?missing value for --runtime-dir}"; shift 2 ;;
    --yes) CONFIRMED=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done
$CONFIRMED || { echo "Refusing to create a large archive without --yes." >&2; exit 2; }

if [[ -z "$RUNTIME_DIR" ]]; then
  prefix="$(npm prefix --global)"
  RUNTIME_DIR="$prefix/lib/node_modules/openclaw"
fi
[[ -d "$RUNTIME_DIR" ]] || { echo "Runtime not found: $RUNTIME_DIR" >&2; exit 1; }
[[ -f "$RUNTIME_DIR/package.json" && -f "$RUNTIME_DIR/openclaw.mjs" ]] || {
  echo "Directory does not look like an OpenClaw runtime: $RUNTIME_DIR" >&2
  exit 1
}

mkdir -p "$OUTPUT_DIR"
exec 9>"$OUTPUT_DIR/.runtime.lock"
flock -n 9 || { echo "Another runtime backup or rollback is already running." >&2; exit 1; }

runtime_bytes="$(du -sb "$RUNTIME_DIR" | awk '{print $1}')"
available_bytes="$(df -PB1 "$OUTPUT_DIR" | awk 'NR==2 {print $4}')"
required_bytes=$((runtime_bytes * 2))
if (( available_bytes < required_bytes )); then
  echo "Insufficient free space: need at least $required_bytes bytes; have $available_bytes." >&2
  exit 1
fi

version="$(node -e 'const p=require(process.argv[1]); process.stdout.write(String(p.version||"unknown"))' "$RUNTIME_DIR/package.json")"
timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
archive="$OUTPUT_DIR/openclaw-${version}-${timestamp}.tgz"
partial="${archive}.partial"
checksum="${archive}.sha256"
manifest="${archive}.manifest.txt"
runtime_parent="$(dirname "$RUNTIME_DIR")"
runtime_name="$(basename "$RUNTIME_DIR")"
cleanup() { rm -f "$partial"; }
trap cleanup EXIT

echo "Archiving $RUNTIME_DIR ($runtime_bytes bytes)..."
tar -C "$runtime_parent" -czf "$partial" "$runtime_name"
mv "$partial" "$archive"
sha256sum "$archive" > "$checksum"
{
  echo "created_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "hostname=$(hostname)"
  echo "openclaw_version=$version"
  echo "source_runtime=$RUNTIME_DIR"
  echo "archive=$archive"
  echo "archive_bytes=$(stat -c %s "$archive")"
  echo "archive_sha256=$(awk '{print $1}' "$checksum")"
  echo "node=$(node --version)"
  echo "npm=$(npm --version)"
  if command -v openclaw >/dev/null 2>&1; then
    echo "binary=$(command -v openclaw)"
    echo "binary_target=$(readlink -f "$(command -v openclaw)")"
  fi
} > "$manifest"
ln -sfn "$(basename "$archive")" "$OUTPUT_DIR/current-good.tgz"
ln -sfn "$(basename "$checksum")" "$OUTPUT_DIR/current-good.tgz.sha256"
ln -sfn "$(basename "$manifest")" "$OUTPUT_DIR/current-good.tgz.manifest.txt"
trap - EXIT

echo "Backup complete: $archive"
echo "Checksum: $(awk '{print $1}' "$checksum")"
