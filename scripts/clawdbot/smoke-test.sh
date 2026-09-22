#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'USAGE'
Usage: smoke-test.sh [--binary PATH] [--expect-version VERSION] [--gateway]

Run read-only OpenClaw CLI checks in an isolated state/config. With --gateway,
also verify the live user service and local Gateway health endpoint.
USAGE
}

BINARY="${OPENCLAW_BINARY:-$(command -v openclaw 2>/dev/null || true)}"
EXPECT_VERSION=""
CHECK_GATEWAY=false
while (($#)); do
  case "$1" in
    --binary) BINARY="${2:?missing value for --binary}"; shift 2 ;;
    --expect-version) EXPECT_VERSION="${2:?missing value for --expect-version}"; shift 2 ;;
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
  systemctl --user is-active --quiet openclaw-gateway.service || {
    echo "Gateway service is not active." >&2
    exit 1
  }
  health_ok=false
  for endpoint in healthz readyz; do
    if curl --silent --show-error --fail --max-time 3 "http://127.0.0.1:18789/$endpoint" >/dev/null 2>&1; then
      echo "Gateway /$endpoint: OK"
      health_ok=true
      break
    fi
  done
  $health_ok || { echo "Gateway health endpoint failed." >&2; exit 1; }
fi
