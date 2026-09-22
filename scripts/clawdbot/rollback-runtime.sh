#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'USAGE'
Usage: rollback-runtime.sh [--archive FILE] [--runtime-dir DIR] --yes

Emergency manual rollback of the global OpenClaw runtime. The script validates
an archive, stops the user Gateway, preserves the failed runtime, restores the
archive, restarts the Gateway, and reverts automatically if health checks fail.

Options:
  --archive FILE    Known-good .tgz (default: ~/.openclaw/releases/current-good.tgz)
  --runtime-dir DIR Installed OpenClaw directory (auto-detected from npm prefix)
  --yes             Required acknowledgement
  -h, --help        Show this help
USAGE
}

ARCHIVE="${OPENCLAW_ROLLBACK_ARCHIVE:-$HOME/.openclaw/releases/current-good.tgz}"
RUNTIME_DIR="${OPENCLAW_RUNTIME_DIR:-}"
CONFIRMED=false
while (($#)); do
  case "$1" in
    --archive) ARCHIVE="${2:?missing value for --archive}"; shift 2 ;;
    --runtime-dir) RUNTIME_DIR="${2:?missing value for --runtime-dir}"; shift 2 ;;
    --yes) CONFIRMED=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done
$CONFIRMED || { echo "Refusing rollback without --yes." >&2; exit 2; }
[[ -f "$ARCHIVE" ]] || { echo "Archive not found: $ARCHIVE" >&2; exit 1; }
ARCHIVE="$(readlink -f "$ARCHIVE")"

if [[ -z "$RUNTIME_DIR" ]]; then
  prefix="$(npm prefix --global)"
  RUNTIME_DIR="$prefix/lib/node_modules/openclaw"
else
  prefix="$(cd "$(dirname "$(dirname "$(dirname "$RUNTIME_DIR")")")" && pwd)"
fi
runtime_parent="$(dirname "$RUNTIME_DIR")"
bin_link="$prefix/bin/openclaw"
mkdir -p "$HOME/.openclaw/releases"
exec 9>"$HOME/.openclaw/releases/.runtime.lock"
flock -n 9 || { echo "Another runtime backup or rollback is running." >&2; exit 1; }

checksum="${ARCHIVE}.sha256"
if [[ -f "$checksum" ]]; then
  (cd "$(dirname "$ARCHIVE")" && sha256sum -c "$(basename "$checksum")")
else
  echo "Warning: checksum file not found for $ARCHIVE" >&2
fi

while IFS= read -r entry; do
  case "$entry" in
    openclaw|openclaw/|openclaw/*) ;;
    *) echo "Unsafe archive entry: $entry" >&2; exit 1 ;;
  esac
  [[ "$entry" != *"../"* && "$entry" != ../* ]] || {
    echo "Unsafe traversal entry: $entry" >&2
    exit 1
  }
done < <(tar -tzf "$ARCHIVE")

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
stage="$runtime_parent/.openclaw-restore-$stamp"
failed="$runtime_parent/openclaw.failed-$stamp"
restored_failed="$runtime_parent/openclaw.restore-failed-$stamp"
mkdir -p "$stage"
cleanup() { [[ -d "$stage" ]] && rm -rf "$stage"; }
trap cleanup EXIT

tar -xzf "$ARCHIVE" --strip-components=1 -C "$stage"
[[ -f "$stage/package.json" && -f "$stage/openclaw.mjs" ]] || {
  echo "Archive does not contain a valid OpenClaw runtime." >&2
  exit 1
}

restore_original() {
  echo "Restored archive failed health checks; reverting to the pre-rollback runtime." >&2
  systemctl --user stop openclaw-gateway.service || true
  [[ -d "$RUNTIME_DIR" ]] && mv "$RUNTIME_DIR" "$restored_failed"
  [[ -d "$failed" ]] && mv "$failed" "$RUNTIME_DIR"
  ln -sfn ../lib/node_modules/openclaw/openclaw.mjs "$bin_link"
  systemctl --user start openclaw-gateway.service || true
}

systemctl --user stop openclaw-gateway.service
if [[ -e "$RUNTIME_DIR" ]]; then
  mv "$RUNTIME_DIR" "$failed"
fi
mv "$stage" "$RUNTIME_DIR"
ln -sfn ../lib/node_modules/openclaw/openclaw.mjs "$bin_link"

if ! systemctl --user start openclaw-gateway.service; then
  restore_original
  exit 1
fi

healthy=false
for _ in {1..12}; do
  if systemctl --user is-active --quiet openclaw-gateway.service && \
     curl --silent --fail --max-time 3 http://127.0.0.1:18789/healthz >/dev/null 2>&1; then
    healthy=true
    break
  fi
  sleep 5
done
if ! $healthy; then
  restore_original
  exit 1
fi

trap - EXIT
echo "Rollback succeeded. Preserved replaced runtime at: $failed"
echo "Restored archive: $ARCHIVE"
