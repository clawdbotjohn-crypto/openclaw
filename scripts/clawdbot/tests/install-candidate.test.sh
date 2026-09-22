#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
installer="$repo_root/scripts/clawdbot/install-candidate.sh"
real_npm="$(command -v npm)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_file() { [[ -f "$1" ]] || fail "expected file: $1"; }
assert_contains() { grep -Fq "$2" "$1" || fail "expected '$2' in $1"; }

make_artifact() {
  local root="$1"
  mkdir -p "$root/package"
  cat > "$root/package/package.json" <<'JSON'
{"name":"openclaw","version":"9.9.9-test","bin":{"openclaw":"openclaw.mjs"}}
JSON
  cat > "$root/package/openclaw.mjs" <<'JS'
#!/usr/bin/env node
if (process.argv.includes("--version")) console.log("9.9.9-test");
else if (process.argv.includes("--help")) console.log("test help");
JS
  chmod +x "$root/package/openclaw.mjs"
  echo candidate > "$root/package/runtime-marker"
  tar -C "$root" -czf "$root/openclaw-test.tgz" package
  sha256sum "$root/openclaw-test.tgz" > "$root/openclaw-test.tgz.sha256"
}

make_runtime() {
  local prefix="$1"
  local runtime="$prefix/lib/node_modules/openclaw"
  mkdir -p "$runtime" "$prefix/bin"
  cat > "$runtime/package.json" <<'JSON'
{"name":"openclaw","version":"1.0.0","bin":{"openclaw":"openclaw.mjs"}}
JSON
  cat > "$runtime/openclaw.mjs" <<'JS'
#!/usr/bin/env node
if (process.argv.includes("--version")) console.log("1.0.0");
JS
  chmod +x "$runtime/openclaw.mjs"
  echo original > "$runtime/runtime-marker"
  ln -sfn ../lib/node_modules/openclaw/openclaw.mjs "$prefix/bin/openclaw"
}

make_fakes() {
  local root="$1"
  mkdir -p "$root/bin"
  cat > "$root/bin/npm" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == prefix && "\${2:-}" == --global ]]; then
  printf '%s\\n' "\$FAKE_GLOBAL_PREFIX"
  exit 0
fi
exec "$real_npm" "\$@"
EOF
  cat > "$root/bin/systemctl" <<'SH'
#!/usr/bin/env bash
set -u
args=("$@")
action=""
for arg in "${args[@]}"; do
  case "$arg" in start|stop|is-active) action="$arg"; break ;; esac
done
case "$action" in
  start) echo active > "$FAKE_SERVICE_STATE"; exit 0 ;;
  stop) echo inactive > "$FAKE_SERVICE_STATE"; exit 0 ;;
  is-active) [[ "$(cat "$FAKE_SERVICE_STATE" 2>/dev/null || true)" == active ]] ;;
  *) echo "unexpected fake systemctl args: $*" >&2; exit 2 ;;
esac
SH
  cat > "$root/bin/curl" <<'SH'
#!/usr/bin/env bash
if [[ "${FAKE_HEALTH_MODE:-success}" == success ]]; then
  exit 0
fi
[[ "$(cat "$FAKE_RUNTIME_DIR/runtime-marker" 2>/dev/null || true)" == original ]]
SH
  chmod +x "$root/bin/npm" "$root/bin/systemctl" "$root/bin/curl"
}

run_case() {
  local name="$1"
  local mode="$2"
  local root="$tmp/$name"
  local prefix="$root/prefix"
  local releases="$root/releases"
  mkdir -p "$root"
  make_artifact "$root"
  make_runtime "$prefix"
  make_fakes "$root"
  export FAKE_GLOBAL_PREFIX="$root/unrelated-global"
  export FAKE_SERVICE_STATE="$root/service-state"
  export FAKE_RUNTIME_DIR="$prefix/lib/node_modules/openclaw"
  export FAKE_HEALTH_MODE="$mode"
  export OPENCLAW_NPM_BIN="$root/bin/npm"
  export OPENCLAW_SYSTEMCTL_BIN="$root/bin/systemctl"
  export OPENCLAW_CURL_BIN="$root/bin/curl"
  export OPENCLAW_HEALTH_ATTEMPTS=2
  export OPENCLAW_HEALTH_INTERVAL_SECONDS=0
  echo active > "$FAKE_SERVICE_STATE"
  CASE_ROOT="$root"
  CASE_PREFIX="$prefix"
  CASE_RELEASES="$releases"
}

chmod +x "$installer"

run_case dry-run success
before="$(sha256sum "$CASE_PREFIX/lib/node_modules/openclaw/runtime-marker")"
"$installer" --artifact "$CASE_ROOT/openclaw-test.tgz" --prefix "$CASE_PREFIX" \
  --release-dir "$CASE_RELEASES" > "$CASE_ROOT/output"
after="$(sha256sum "$CASE_PREFIX/lib/node_modules/openclaw/runtime-marker")"
[[ "$before" == "$after" ]] || fail "dry run changed runtime"
[[ ! -e "$CASE_RELEASES" ]] || fail "dry run created release directory"
assert_contains "$CASE_ROOT/output" "DRY RUN ONLY"

echo "PASS: dry run validates without mutation"

run_case confirmation success
if "$installer" --artifact "$CASE_ROOT/openclaw-test.tgz" --prefix "$CASE_PREFIX" \
  --release-dir "$CASE_RELEASES" --apply > "$CASE_ROOT/output" 2>&1; then
  fail "--apply without --yes unexpectedly succeeded"
fi
assert_contains "$CASE_ROOT/output" "requires --yes"
[[ "$(cat "$CASE_PREFIX/lib/node_modules/openclaw/runtime-marker")" == original ]] || fail "confirmation guard changed runtime"
echo "PASS: mutation requires --apply and --yes"

run_case live-guard success
export FAKE_GLOBAL_PREFIX="$CASE_PREFIX"
if "$installer" --artifact "$CASE_ROOT/openclaw-test.tgz" --prefix "$CASE_PREFIX" \
  --release-dir "$CASE_RELEASES" --apply --yes > "$CASE_ROOT/output" 2>&1; then
  fail "active global runtime mutation unexpectedly succeeded without explicit override"
fi
assert_contains "$CASE_ROOT/output" "without --allow-live-runtime"
[[ ! -e "$CASE_RELEASES" ]] || fail "live target refusal created release directory"
[[ "$(cat "$CASE_PREFIX/lib/node_modules/openclaw/runtime-marker")" == original ]] || fail "live target refusal changed runtime"
echo "PASS: active global runtime requires --allow-live-runtime"

run_case success success
"$installer" --artifact "$CASE_ROOT/openclaw-test.tgz" --prefix "$CASE_PREFIX" \
  --release-dir "$CASE_RELEASES" --apply --yes > "$CASE_ROOT/output" 2>&1
[[ "$(cat "$CASE_PREFIX/lib/node_modules/openclaw/runtime-marker")" == candidate ]] || fail "candidate not installed"
[[ "$(cat "$FAKE_SERVICE_STATE")" == active ]] || fail "service not active after successful install"
previous="$(find "$CASE_PREFIX/lib/node_modules" -maxdepth 1 -type d -name 'openclaw.previous-*' -print -quit)"
[[ -n "$previous" && "$(cat "$previous/runtime-marker")" == original ]] || fail "previous runtime not preserved"
backup="$(find "$CASE_RELEASES" -maxdepth 1 -type f -name 'openclaw-1.0.0-*.tgz' -print -quit)"
assert_file "$backup"
assert_file "$backup.sha256"
assert_contains "$CASE_ROOT/output" "Candidate installation succeeded"
echo "PASS: staged candidate installs after verified backup and health check"

run_case rollback failure
set +e
"$installer" --artifact "$CASE_ROOT/openclaw-test.tgz" --prefix "$CASE_PREFIX" \
  --release-dir "$CASE_RELEASES" --apply --yes > "$CASE_ROOT/output" 2>&1
rc=$?
set -e
[[ $rc -eq 1 ]] || fail "failed candidate returned $rc instead of 1"
[[ "$(cat "$CASE_PREFIX/lib/node_modules/openclaw/runtime-marker")" == original ]] || fail "original runtime not restored"
[[ "$(cat "$FAKE_SERVICE_STATE")" == active ]] || fail "service not active after rollback"
failed="$(find "$CASE_PREFIX/lib/node_modules" -maxdepth 1 -type d -name 'openclaw.failed-*' -print -quit)"
[[ -n "$failed" && "$(cat "$failed/runtime-marker")" == candidate ]] || fail "failed candidate not preserved"
backup="$(find "$CASE_RELEASES" -maxdepth 1 -type f -name 'openclaw-1.0.0-*.tgz' -print -quit)"
assert_file "$backup"
assert_contains "$CASE_ROOT/output" "Automatic rollback succeeded"
echo "PASS: unhealthy candidate rolls back and is preserved for diagnosis"

echo "All install-candidate integration tests passed."
