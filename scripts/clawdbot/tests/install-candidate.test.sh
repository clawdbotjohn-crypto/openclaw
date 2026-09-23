#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
installer="$repo_root/scripts/clawdbot/install-candidate.sh"
rollback="$repo_root/scripts/clawdbot/rollback-runtime.sh"
backup="$repo_root/scripts/clawdbot/backup-runtime.sh"
smoke="$repo_root/scripts/clawdbot/smoke-test.sh"
pass=0; fail=0; case_root=""
pass_case() { echo "ok - $1"; ((pass+=1)); }
fail_case() { echo "not ok - $1" >&2; ((fail+=1)); }
assert() { "$@" || { echo "assertion failed: $*" >&2; return 1; }; }
cleanup_case() { [[ -n "$case_root" ]] && rm -rf "$case_root"; case_root=""; }
trap cleanup_case EXIT

make_cli() {
  local runtime="$1" version="$2" marker="$3"
  mkdir -p "$runtime"
  printf '{"name":"openclaw","version":"%s"}\n' "$version" > "$runtime/package.json"
  printf '%s\n' "$marker" > "$runtime/exact-runtime-marker"
  cat > "$runtime/openclaw.mjs" <<'CLI'
#!/usr/bin/env bash
set -euo pipefail
self="$(readlink -f "$0")"; dir="$(dirname "$self")"
version="$(node -e 'process.stdout.write(require(process.argv[1]).version)' "$dir/package.json")"
case "${1:-}" in
  --version) echo "$version" ;;
  --help) echo "fake openclaw help" ;;
  health)
    [[ "${FAKE_HEALTH_TRANSPORT_FAIL:-}" != 1 ]] || exit 8
    if [[ "${FAKE_UNHEALTHY_VERSION:-}" == "$version" ]]; then echo '<html>fake SPA</html>'; exit 0; fi
    if [[ "${FAKE_MALFORMED_HEALTH_VERSION:-}" == "$version" ]]; then echo '{"ok":true}'; exit 0; fi
    printf '{"ok":true,"ts":1,"durationMs":1,"channels":{},"channelOrder":[],"channelLabels":{},"defaultAgentId":"main","agents":[{"agentId":"main"}],"sessions":{"path":"/fake/sessions.json","count":0,"recent":[]}}\n'
    ;;
  *) exit 0 ;;
esac
CLI
  chmod +x "$runtime/openclaw.mjs"
}

create_candidate_artifact() {
  local root="$1" version="${2:-2.0.0}" marker="${3:-candidate-exact}"
  local pkg="$root/pkg/package"
  make_cli "$pkg" "$version" "$marker"
  ARTIFACT="$root/openclaw-candidate.tgz"
  tar -C "$root/pkg" -czf "$ARTIFACT" package
  (cd "$root" && sha256sum "$(basename "$ARTIFACT")" > "$(basename "$ARTIFACT").sha256")
  ARTIFACT_SHA="$(sha256sum "$ARTIFACT" | awk '{print $1}')"
  METADATA="$root/build-metadata.txt"
  write_metadata
}

write_metadata() {
  cat > "$METADATA" <<EOF
repository=${META_REPOSITORY:-clawdbotjohn-crypto/openclaw}
ref=${META_REF:-refs/heads/clawdbot-stable}
sha=${META_SHA:-1111111111111111111111111111111111111111}
event_name=${META_EVENT:-push}
tarball=$(basename "$ARTIFACT")
package_sha256=${META_PACKAGE_SHA:-$ARTIFACT_SHA}
node=v22
pnpm=10.23.0
built_at=2026-09-23T00:00:00Z
EOF
}

create_restore_archive() {
  local root="$1" version="${2:-0.9.0}" marker="${3:-known-good-exact}"
  local tree="$root/restore-tree/openclaw"
  make_cli "$tree" "$version" "$marker"
  RESTORE_ARCHIVE="$root/releases/manual-good.tgz"
  mkdir -p "$root/releases"
  tar -C "$root/restore-tree" -czf "$RESTORE_ARCHIVE" openclaw
  (cd "$(dirname "$RESTORE_ARCHIVE")" && sha256sum "$(basename "$RESTORE_ARCHIVE")" > "$(basename "$RESTORE_ARCHIVE").sha256")
}

setup_case() {
  cleanup_case
  unset META_REPOSITORY META_REF META_SHA META_EVENT META_PACKAGE_SHA || true
  case_root="$(mktemp -d /tmp/openclaw-transaction-test.XXXXXX)"
  PREFIX="$case_root/prefix"; RUNTIME="$PREFIX/lib/node_modules/openclaw"; RELEASES="$case_root/releases"; FAKES="$case_root/fakes"
  mkdir -p "$PREFIX/bin" "$RELEASES" "$FAKES"
  make_cli "$RUNTIME" 1.0.0 "original-exact-$RANDOM-$RANDOM"
  ORIGINAL_MARKER="$(cat "$RUNTIME/exact-runtime-marker")"
  ln -s ../lib/node_modules/openclaw/openclaw.mjs "$PREFIX/bin/openclaw"
  SERVICE_STATE="$case_root/service-state"; echo "${1:-active}" > "$SERVICE_STATE"
  cat > "$FAKES/systemctl" <<'SYSTEMCTL'
#!/usr/bin/env bash
set -euo pipefail
state="${FAKE_SERVICE_STATE:?}"
action="${2:-}"
case "$action" in
  is-active) [[ "$(cat "$state")" == active ]] ;;
  stop) [[ "${FAKE_SYSTEMCTL_FAIL_STOP:-}" != 1 ]] || exit 40; echo inactive > "$state" ;;
  start)
    [[ "${FAKE_SYSTEMCTL_FAIL_START:-}" != 1 ]] || exit 41
    echo active > "$state"
    ;;
  *) exit 42 ;;
esac
SYSTEMCTL
  cat > "$FAKES/npm" <<'NPM'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == prefix && "${2:-}" == --global ]]; then echo "${FAKE_GLOBAL_PREFIX:?}"; exit 0; fi
prefix=""; artifact=""
while (($#)); do case "$1" in --prefix) prefix="$2"; shift 2 ;; *.tgz) artifact="$1"; shift ;; *) shift ;; esac; done
[[ -n "$prefix" && -n "$artifact" ]]
mkdir -p "$prefix/lib/node_modules/openclaw" "$prefix/bin"
tar -xzf "$artifact" --strip-components=1 -C "$prefix/lib/node_modules/openclaw"
ln -s ../lib/node_modules/openclaw/openclaw.mjs "$prefix/bin/openclaw"
NPM
  cat > "$FAKES/curl" <<'CURL'
#!/usr/bin/env bash
echo "TEST FAILURE: curl must never be called" >&2
exit 99
CURL
  chmod +x "$FAKES"/*
  create_candidate_artifact "$case_root"
  create_restore_archive "$case_root"
}

common_env() {
  env PATH="$FAKES:$PATH" \
    OPENCLAW_SYSTEMCTL_BIN="$FAKES/systemctl" OPENCLAW_NPM_BIN="$FAKES/npm" \
    OPENCLAW_HEALTH_BIN="$PREFIX/bin/openclaw" OPENCLAW_HEALTH_ATTEMPTS=1 OPENCLAW_HEALTH_INTERVAL_SECONDS=0 \
    FAKE_SERVICE_STATE="$SERVICE_STATE" FAKE_GLOBAL_PREFIX="$case_root/not-global" \
    OPENCLAW_TEST_MODE=1 OPENCLAW_TEST_ROOT="$case_root" "$@"
}

install_cmd() {
  common_env "$installer" --artifact "$ARTIFACT" --checksum "$ARTIFACT.sha256" --metadata "$METADATA" \
    --expected-repository clawdbotjohn-crypto/openclaw --expected-ref refs/heads/clawdbot-stable \
    --expected-sha 1111111111111111111111111111111111111111 --prefix "$PREFIX" --runtime-dir "$RUNTIME" \
    --release-dir "$RELEASES" --apply --yes
}
rollback_cmd() {
  common_env "$rollback" --archive "$RESTORE_ARCHIVE" --runtime-dir "$RUNTIME" --release-dir "$RELEASES" --yes
}
assert_original_restored() {
  assert test "$(cat "$RUNTIME/exact-runtime-marker")" = "$ORIGINAL_MARKER" || return
  assert test "$(readlink -f "$PREFIX/bin/openclaw")" = "$(readlink -f "$RUNTIME/openclaw.mjs")" || return
  assert test "$(cat "$SERVICE_STATE")" = "$1" || return
}

run_case() {
  local name="$1" rc; shift
  if [[ -n "${TEST_FILTER:-}" && "$name" != *"$TEST_FILTER"* ]]; then return 0; fi
  set +e
  ( set -Eeuo pipefail; "$@" )
  rc=$?
  set -e
  if (( rc == 0 )); then pass_case "$name"; else fail_case "$name"; fi
}

test_dry_run() {
  setup_case active
  local before after
  before="$(find "$RELEASES" -name '*.tgz' | wc -l)"
  common_env "$installer" --artifact "$ARTIFACT" --metadata "$METADATA" --expected-repository clawdbotjohn-crypto/openclaw \
    --expected-ref refs/heads/clawdbot-stable --expected-sha 1111111111111111111111111111111111111111 \
    --prefix "$PREFIX" --runtime-dir "$RUNTIME" --release-dir "$RELEASES" >/dev/null
  assert_original_restored active || return
  after="$(find "$RELEASES" -name '*.tgz' | wc -l)"
  assert test "$before" = "$after"
}

test_install_success_running() {
  setup_case active
  install_cmd >/dev/null
  assert test "$(cat "$RUNTIME/exact-runtime-marker")" = candidate-exact
  assert test "$(cat "$SERVICE_STATE")" = active
  assert test -L "$RELEASES/current-good.tgz"
  local good="$(readlink -f "$RELEASES/current-good.tgz")"
  assert test -f "$good"
  assert grep -q '^openclaw/exact-runtime-marker$' <(tar -tzf "$good")
}

test_install_success_stopped_preserves_good() {
  setup_case inactive
  echo sentinel > "$RELEASES/sentinel.tgz"; ln -s sentinel.tgz "$RELEASES/current-good.tgz"
  install_cmd >/dev/null
  assert test "$(cat "$RUNTIME/exact-runtime-marker")" = candidate-exact
  assert test "$(cat "$SERVICE_STATE")" = inactive
  assert test "$(readlink "$RELEASES/current-good.tgz")" = sentinel.tgz
}

test_baseline_unhealthy_preserves_good() {
  setup_case active
  echo sentinel > "$RELEASES/sentinel.tgz"; ln -s sentinel.tgz "$RELEASES/current-good.tgz"
  if FAKE_UNHEALTHY_VERSION=1.0.0 install_cmd >/dev/null 2>&1; then return 1; fi
  assert_original_restored active
  assert test "$(readlink "$RELEASES/current-good.tgz")" = sentinel.tgz
}

test_backup_failure_preserves_good() {
  setup_case active
  echo sentinel > "$RELEASES/sentinel.tgz"; ln -s sentinel.tgz "$RELEASES/current-good.tgz"
  local real_tar="$(command -v tar)"
  cat > "$FAKES/tar" <<EOF
#!/usr/bin/env bash
for arg in "\$@"; do [[ "\$arg" == *.partial ]] && exit 55; done
exec "$real_tar" "\$@"
EOF
  chmod +x "$FAKES/tar"
  if install_cmd >/dev/null 2>&1; then return 1; fi
  assert_original_restored active
  assert test "$(readlink "$RELEASES/current-good.tgz")" = sentinel.tgz
}

test_install_health_failure_recovers() {
  setup_case active
  if FAKE_UNHEALTHY_VERSION=2.0.0 install_cmd >/dev/null 2>&1; then return 1; fi
  assert_original_restored active
}

test_rollback_health_failure_recovers() {
  setup_case active
  if FAKE_UNHEALTHY_VERSION=0.9.0 rollback_cmd >/dev/null 2>&1; then return 1; fi
  assert_original_restored active
}

test_rollback_success_stopped() {
  setup_case inactive
  rollback_cmd >/dev/null
  assert test "$(cat "$RUNTIME/exact-runtime-marker")" = known-good-exact
  assert test "$(cat "$SERVICE_STATE")" = inactive
  assert test "$(readlink -f "$PREFIX/bin/openclaw")" = "$(readlink -f "$RUNTIME/openclaw.mjs")"
}

test_stopped_failure_recovers_stopped() {
  setup_case inactive
  if OPENCLAW_TEST_HOOK_PHASE=after-link OPENCLAW_TEST_HOOK_MODE=ERR install_cmd >/dev/null 2>&1; then return 1; fi
  assert_original_restored inactive
}

test_hook_matrix() {
  local tool="$1" phase="$2" mode="$3"
  setup_case active
  local rc=0
  if [[ "$tool" == install ]]; then
    OPENCLAW_TEST_HOOK_PHASE="$phase" OPENCLAW_TEST_HOOK_MODE="$mode" install_cmd >/dev/null 2>&1 || rc=$?
  else
    OPENCLAW_TEST_HOOK_PHASE="$phase" OPENCLAW_TEST_HOOK_MODE="$mode" rollback_cmd >/dev/null 2>&1 || rc=$?
  fi
  (( rc != 0 )) || return 1
  assert_original_restored active
  case "$mode" in INT) assert test "$rc" -eq 130 ;; TERM) assert test "$rc" -eq 143 ;; esac
}

test_shared_lock_contention() {
  setup_case active
  exec {fd}>"$RELEASES/.runtime.lock"; flock -n "$fd"
  if install_cmd >/dev/null 2>&1; then return 1; fi
  if rollback_cmd >/dev/null 2>&1; then return 1; fi
  if common_env "$backup" --output-dir "$RELEASES" --runtime-dir "$RUNTIME" --health-bin "$PREFIX/bin/openclaw" --yes >/dev/null 2>&1; then return 1; fi
  assert_original_restored active
  exec {fd}>&-
}

test_checksum_failure() {
  local kind="$1" tool="$2"
  setup_case active
  local file
  if [[ "$tool" == install ]]; then file="$ARTIFACT.sha256"; else file="$RESTORE_ARCHIVE.sha256"; fi
  case "$kind" in
    missing) rm "$file" ;;
    malformed) echo nope > "$file" ;;
    ambiguous) line="$(cat "$file")"; printf '%s\n%s\n' "$line" "$line" > "$file" ;;
    mismatch) printf '%064d  %s\n' 0 "$(basename "${file%.sha256}")" > "$file" ;;
    misnamed) printf '%s  wrong.tgz\n' "$(sha256sum "${file%.sha256}" | awk '{print $1}')" > "$file" ;;
  esac
  if [[ "$tool" == install ]]; then install_cmd >/dev/null 2>&1 && return 1; else rollback_cmd >/dev/null 2>&1 && return 1; fi
  assert_original_restored active
}

test_provenance_failure() {
  local kind="$1"
  setup_case active
  case "$kind" in
    repository) META_REPOSITORY=evil/fork ;;
    ref) META_REF=refs/pull/3/merge ;;
    sha) META_SHA=2222222222222222222222222222222222222222 ;;
    event) META_EVENT=pull_request ;;
    package-checksum) META_PACKAGE_SHA="$(printf '%064d' 0)" ;;
    duplicate) echo 'repository=duplicate/repo' >> "$METADATA"; install_cmd >/dev/null 2>&1 && return 1; assert_original_restored active; return ;;
  esac
  write_metadata
  install_cmd >/dev/null 2>&1 && return 1
  assert_original_restored active
}

test_smoke_structured_health() {
  setup_case active
  common_env "$smoke" --binary "$PREFIX/bin/openclaw" --expect-version 1.0.0 --gateway >/dev/null
  if FAKE_MALFORMED_HEALTH_VERSION=1.0.0 common_env "$smoke" --binary "$PREFIX/bin/openclaw" --gateway >/dev/null 2>&1; then return 1; fi
}

test_backup_refuses_unhealthy_baseline() {
  setup_case active
  echo sentinel > "$RELEASES/sentinel.tgz"; ln -s sentinel.tgz "$RELEASES/current-good.tgz"
  if FAKE_UNHEALTHY_VERSION=1.0.0 common_env "$backup" --output-dir "$RELEASES" --runtime-dir "$RUNTIME" --health-bin "$PREFIX/bin/openclaw" --yes >/dev/null 2>&1; then return 1; fi
  assert test "$(readlink "$RELEASES/current-good.tgz")" = sentinel.tgz
}

test_backup_pointer_failure_restores_all_pointers() {
  setup_case active
  for name in current-good.tgz current-good.tgz.sha256 current-good.tgz.manifest.txt; do
    echo "$name old" > "$RELEASES/old-$name"
    ln -s "old-$name" "$RELEASES/$name"
  done
  if OPENCLAW_TEST_HOOK_PHASE=after-pointer-current-good.tgz OPENCLAW_TEST_HOOK_MODE=ERR \
    common_env "$backup" --output-dir "$RELEASES" --runtime-dir "$RUNTIME" --health-bin "$PREFIX/bin/openclaw" --yes >/dev/null 2>&1; then return 1; fi
  for name in current-good.tgz current-good.tgz.sha256 current-good.tgz.manifest.txt; do
    assert test "$(readlink "$RELEASES/$name")" = "old-$name"
  done
}

run_case "dry run is non-mutating" test_dry_run
run_case "running install succeeds with structured health" test_install_success_running
run_case "stopped install stays stopped and preserves known-good" test_install_success_stopped_preserves_good
run_case "unhealthy baseline preserves known-good" test_baseline_unhealthy_preserves_good
run_case "backup creation failure preserves known-good" test_backup_failure_preserves_good
run_case "candidate health failure restores exact runtime" test_install_health_failure_recovers
run_case "rollback health failure restores exact runtime" test_rollback_health_failure_recovers
run_case "stopped rollback succeeds without starting service" test_rollback_success_stopped
run_case "stopped-state failure restores stopped state" test_stopped_failure_recovers_stopped
run_case "shared lock blocks installer and rollback" test_shared_lock_contention
run_case "smoke test requires structured health schema" test_smoke_structured_health
run_case "standalone backup refuses unhealthy baseline" test_backup_refuses_unhealthy_baseline
run_case "pointer promotion failure restores all known-good pointers" test_backup_pointer_failure_restores_all_pointers

install_phases=(before-stop after-stop after-move-original after-activate-candidate after-link after-start after-health)
rollback_phases=(before-stop after-stop after-move-original after-activate-restored after-link after-start after-health)
for mode in ERR INT TERM EXIT; do
  for phase in "${install_phases[@]}"; do run_case "installer recovers $mode at $phase" test_hook_matrix install "$phase" "$mode"; done
  for phase in "${rollback_phases[@]}"; do run_case "rollback recovers $mode at $phase" test_hook_matrix rollback "$phase" "$mode"; done
done
for tool in install rollback; do
  for kind in missing malformed ambiguous mismatch misnamed; do run_case "$tool rejects $kind checksum" test_checksum_failure "$kind" "$tool"; done
done
for kind in repository ref sha event package-checksum duplicate; do run_case "installer rejects provenance $kind" test_provenance_failure "$kind"; done

cleanup_case
echo "1..$((pass + fail))"
echo "passed=$pass failed=$fail"
(( fail == 0 ))
