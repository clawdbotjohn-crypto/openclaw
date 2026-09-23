#!/usr/bin/env bash
set -Eeuo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=runtime-common.sh
source "$script_dir/runtime-common.sh"

usage() {
  cat <<'USAGE'
Usage: smoke-test.sh [--binary PATH] [--expect-version VERSION] [--gateway]

Run read-only CLI checks in isolated state/config. With --gateway, separately
query the configured running Gateway using `openclaw health --json` and validate
the structured RPC response; no HTTP endpoint is used.
USAGE
}

BINARY="${OPENCLAW_BINARY:-$(command -v openclaw 2>/dev/null || true)}"
EXPECT_VERSION=""; CHECK_GATEWAY=false
RUNTIME_SERVICE="${OPENCLAW_SERVICE:-openclaw-gateway.service}"
RUNTIME_SYSTEMCTL_BIN="${OPENCLAW_SYSTEMCTL_BIN:-systemctl}"
RUNTIME_HEALTH_TIMEOUT_MS="${OPENCLAW_HEALTH_TIMEOUT_MS:-10000}"
RUNTIME_HEALTH_ATTEMPTS=1; RUNTIME_HEALTH_INTERVAL_SECONDS=0
while (($#)); do
  case "$1" in
    --binary) BINARY="${2:?missing value}"; shift 2 ;;
    --expect-version) EXPECT_VERSION="${2:?missing value}"; shift 2 ;;
    --gateway) CHECK_GATEWAY=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done
[[ -n "$BINARY" && -x "$BINARY" ]] || { echo "OpenClaw binary not executable: $BINARY" >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
printf '{}\n' > "$tmp/openclaw.json"
mkdir -p "$tmp/state"
version="$(OPENCLAW_STATE_DIR="$tmp/state" OPENCLAW_CONFIG_PATH="$tmp/openclaw.json" "$BINARY" --version)"
OPENCLAW_STATE_DIR="$tmp/state" OPENCLAW_CONFIG_PATH="$tmp/openclaw.json" "$BINARY" --help >/dev/null
printf 'CLI: OK (%s)\n' "$version"
if [[ -n "$EXPECT_VERSION" && "$version" != *"$EXPECT_VERSION"* ]]; then
  echo "Version mismatch: expected $EXPECT_VERSION, got $version" >&2
  exit 1
fi

if $CHECK_GATEWAY; then
  RUNTIME_HEALTH_BIN="$BINARY"
  runtime_structured_health_once || {
    echo "Gateway structured CLI/RPC health failed or returned malformed/unhealthy content." >&2
    exit 1
  }
  echo "Gateway structured CLI/RPC health: OK"
fi
