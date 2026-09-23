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

runtime_tree_digest() {
  tar --sort=name --mtime='UTC 1970-01-01' --owner=0 --group=0 --numeric-owner -C "$1" -cf - . | sha256sum | awk '{print $1}'
}

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
  mkdir -p "$PREFIX/bin" "$RELEASES" "$FAKES" "$case_root/tmp"
  make_cli "$RUNTIME" 1.0.0 "original-exact-$RANDOM-$RANDOM"
  ORIGINAL_MARKER="$(cat "$RUNTIME/exact-runtime-marker")"
  ORIGINAL_RUNTIME_DIGEST="$(runtime_tree_digest "$RUNTIME")"
  ORIGINAL_RUNTIME_ID="$(stat -c '%d:%i' "$RUNTIME")"
  ln -s ../lib/node_modules/openclaw/openclaw.mjs "$PREFIX/bin/openclaw"
  ORIGINAL_BIN_TARGET="$(readlink "$PREFIX/bin/openclaw")"
  SERVICE_STATE="$case_root/service-state"; echo "${1:-active}" > "$SERVICE_STATE"
  cat > "$FAKES/systemctl" <<'SYSTEMCTL'
#!/usr/bin/env bash
set -euo pipefail
state="${FAKE_SERVICE_STATE:?}"
action="${2:-}"
bump_and_maybe_fail() {
  local kind="$1" fail_at_var counter count=0 fail_at
  fail_at_var="FAKE_SYSTEMCTL_FAIL_${kind^^}_AT"
  counter="$state.${kind}-count"
  [[ ! -f "$counter" ]] || count="$(cat "$counter")"
  count=$((count + 1)); echo "$count" > "$counter"
  fail_at="${!fail_at_var:-0}"
  [[ "$count" != "$fail_at" ]]
}
case "$action" in
  show)
    value="$(cat "$state")"
    case "$value" in
      unknown-unit) echo not-found; exit 0 ;;
      timeout) exit 124 ;;
      query-error|permission) exit 1 ;;
      *) echo loaded; exit 0 ;;
    esac
    ;;
  is-active)
    value="$(cat "$state")"
    case "$value" in
      active) echo active; exit 0 ;;
      inactive) echo inactive; exit 3 ;;
      stopped) echo stopped; exit 3 ;;
      failed|activating|deactivating) echo "$value"; exit 3 ;;
      unknown-unit) echo inactive; exit 3 ;;
      malformed) echo nonsense; exit 0 ;;
      timeout) exit 124 ;;
      query-error) exit 1 ;;
      permission) exit 1 ;;
      *) echo "$value"; exit 9 ;;
    esac
    ;;
  stop) bump_and_maybe_fail stop || exit 40; echo inactive > "$state" ;;
  start) bump_and_maybe_fail start || exit 41; echo active > "$state" ;;
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
  local real_sha256sum
  real_sha256sum="$(command -v sha256sum)"
  cat > "$FAKES/sha256sum" <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [[ -n "\${FAKE_SNAPSHOT_SOURCE:-}" && -n "\${FAKE_REPLACEMENT_ARCHIVE:-}" && -n "\${FAKE_SNAPSHOT_REPLACED_MARKER:-}" && \$# -eq 1 ]]; then
  source_path="\$(readlink -f -- "\$FAKE_SNAPSHOT_SOURCE")"
  input_path="\$(readlink -f -- "\$1")"
  if [[ "\$input_path" != "\$source_path" && "\$(basename "\$input_path")" == "\$(basename "\$source_path")" && ! -e "\$FAKE_SNAPSHOT_REPLACED_MARKER" ]]; then
    cp -- "\$FAKE_REPLACEMENT_ARCHIVE" "\${source_path}.replacement.\$\$"
    mv -- "\${source_path}.replacement.\$\$" "\$source_path"
    : > "\$FAKE_SNAPSHOT_REPLACED_MARKER"
  fi
fi
exec "$real_sha256sum" "\$@"
EOF
  chmod +x "$FAKES"/*
  create_candidate_artifact "$case_root"
  create_restore_archive "$case_root"
  EVIL_CANDIDATE="$case_root/evil-candidate.tgz"
  mkdir -p "$case_root/evil-candidate/package"
  make_cli "$case_root/evil-candidate/package" 9.9.1 attacker-candidate
  tar -C "$case_root/evil-candidate" -czf "$EVIL_CANDIDATE" package
  EVIL_RESTORE_ARCHIVE="$case_root/evil-restore.tgz"
  mkdir -p "$case_root/evil-restore/openclaw"
  make_cli "$case_root/evil-restore/openclaw" 9.9.2 attacker-restore
  tar -C "$case_root/evil-restore" -czf "$EVIL_RESTORE_ARCHIVE" openclaw
}

common_env() {
  env PATH="$FAKES:$PATH" TMPDIR="$case_root/tmp" \
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
assert_snapshot_staging_cleaned() {
  assert test -z "$(find "$case_root/tmp" -mindepth 1 -maxdepth 1 -type d \( -name 'openclaw-install-artifact.*' -o -name 'openclaw-rollback-archive.*' \) -print -quit)"
}

assert_original_restored() {
  assert test "$(cat "$RUNTIME/exact-runtime-marker")" = "$ORIGINAL_MARKER" || return
  assert test "$(runtime_tree_digest "$RUNTIME")" = "$ORIGINAL_RUNTIME_DIGEST" || return
  assert test "$(stat -c '%d:%i' "$RUNTIME")" = "$ORIGINAL_RUNTIME_ID" || return
  assert test "$(readlink "$PREFIX/bin/openclaw")" = "$ORIGINAL_BIN_TARGET" || return
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
  assert test "$before" = "$after" || return
  assert_snapshot_staging_cleaned
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

test_install_source_replacement_uses_snapshot() {
  setup_case active
  local replaced="$case_root/install-source-replaced"
  FAKE_SNAPSHOT_SOURCE="$ARTIFACT" FAKE_REPLACEMENT_ARCHIVE="$EVIL_CANDIDATE" \
    FAKE_SNAPSHOT_REPLACED_MARKER="$replaced" install_cmd >/dev/null
  assert test -e "$replaced" || return
  assert test "$(tar -xOzf "$ARTIFACT" package/exact-runtime-marker)" = attacker-candidate || return
  assert test "$(cat "$RUNTIME/exact-runtime-marker")" = candidate-exact || return
  assert test "$(cat "$SERVICE_STATE")" = active || return
  assert_snapshot_staging_cleaned
}

test_rollback_source_replacement_uses_snapshot() {
  setup_case active
  local replaced="$case_root/rollback-source-replaced"
  FAKE_SNAPSHOT_SOURCE="$RESTORE_ARCHIVE" FAKE_REPLACEMENT_ARCHIVE="$EVIL_RESTORE_ARCHIVE" \
    FAKE_SNAPSHOT_REPLACED_MARKER="$replaced" rollback_cmd >/dev/null
  assert test -e "$replaced" || return
  assert test "$(tar -xOzf "$RESTORE_ARCHIVE" openclaw/exact-runtime-marker)" = attacker-restore || return
  assert test "$(cat "$RUNTIME/exact-runtime-marker")" = known-good-exact || return
  assert test "$(cat "$SERVICE_STATE")" = active || return
  assert_snapshot_staging_cleaned
}

test_hook_matrix() {
  local tool="$1" phase="$2" mode="$3" initial_state="${4:-active}"
  setup_case "$initial_state"
  local rc=0
  if [[ "$tool" == install ]]; then
    OPENCLAW_TEST_HOOK_PHASE="$phase" OPENCLAW_TEST_HOOK_MODE="$mode" install_cmd >/dev/null 2>&1 || rc=$?
  else
    OPENCLAW_TEST_HOOK_PHASE="$phase" OPENCLAW_TEST_HOOK_MODE="$mode" rollback_cmd >/dev/null 2>&1 || rc=$?
  fi
  (( rc != 0 )) || return 1
  assert_original_restored "$initial_state" || return
  case "$mode" in INT) assert test "$rc" -eq 130 || return ;; TERM) assert test "$rc" -eq 143 || return ;; esac
  assert_snapshot_staging_cleaned
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

backup_cmd() {
  common_env "$backup" --output-dir "$RELEASES" --runtime-dir "$RUNTIME" --health-bin "$PREFIX/bin/openclaw" --yes
}

assert_runtime_identity() {
  assert test "$(cat "$RUNTIME/exact-runtime-marker")" = "$ORIGINAL_MARKER" || return
  assert test "$(runtime_tree_digest "$RUNTIME")" = "$ORIGINAL_RUNTIME_DIGEST" || return
  assert test "$(stat -c '%d:%i' "$RUNTIME")" = "$ORIGINAL_RUNTIME_ID" || return
  assert test "$(readlink "$PREFIX/bin/openclaw")" = "$ORIGINAL_BIN_TARGET" || return
  assert test "$(readlink -f "$PREFIX/bin/openclaw")" = "$(readlink -f "$RUNTIME/openclaw.mjs")"
}

assert_lock_released() {
  ( exec {check_fd}>"$RELEASES/.runtime.lock"; flock -n "$check_fd" )
}

assert_no_runtime_tx() {
  assert test -z "$(find "$(dirname "$RUNTIME")" -mindepth 1 -maxdepth 1 -type d \( -name '.openclaw-install-tx.*' -o -name '.openclaw-rollback-tx.*' \) -print -quit)"
}

install_fake_corrupt_tar() {
  local real_tar
  real_tar="$(command -v tar)"
  cat > "$FAKES/tar" <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [[ "\${FAKE_CORRUPT_TAR_LIST:-}" == package && " \$* " == *" -tzf "* ]]; then
  printf 'package/package.json\\npackage/openclaw.mjs\\n'
  exit 77
fi
if [[ "\${FAKE_CORRUPT_TAR_LIST:-}" == runtime && " \$* " == *" -tzf "* ]]; then
  printf 'openclaw/package.json\\nopenclaw/openclaw.mjs\\n'
  exit 77
fi
exec "$real_tar" "\$@"
EOF
  chmod +x "$FAKES/tar"
}

test_backup_health_binding_positive() {
  setup_case active
  local alias="$case_root/runtime-alias"
  ln -s "$RUNTIME" "$alias"
  common_env "$backup" --output-dir "$RELEASES" --runtime-dir "$alias" --health-bin "$PREFIX/bin/openclaw" --yes >/dev/null
  assert test -L "$RELEASES/current-good.tgz" || return
  local archived
  archived="$(readlink -f "$RELEASES/current-good.tgz")"
  assert test "$(tar -xOzf "$archived" openclaw/exact-runtime-marker)" = "$ORIGINAL_MARKER" || return
  assert grep -Fxq 'probed_snapshot_entrypoint=openclaw/openclaw.mjs' "${archived}.manifest.txt" || return
  assert_lock_released
}

test_backup_health_binding_mismatch() {
  setup_case active
  local runtime_b="$case_root/runtime-b" health_b="$case_root/health-b"
  make_cli "$runtime_b" 8.0.0 unrelated-healthy-runtime
  ln -s "$runtime_b/openclaw.mjs" "$health_b"
  echo old > "$RELEASES/old"; ln -s old "$RELEASES/current-good.tgz"
  local rc=0
  common_env "$backup" --output-dir "$RELEASES" --runtime-dir "$RUNTIME" --health-bin "$health_b" --yes >/dev/null 2>&1 || rc=$?
  assert test "$rc" -ne 0 || return
  assert_runtime_identity || return
  assert test "$(readlink "$RELEASES/current-good.tgz")" = old || return
  assert test -z "$(find "$RELEASES" -name 'openclaw-*.tgz' -print -quit)" || return
  assert_lock_released
}

test_backup_health_alias_escape() {
  setup_case active
  local runtime_b="$case_root/runtime-b" alias_dir="$case_root/alias-dir"
  make_cli "$runtime_b" 8.0.0 unrelated-healthy-runtime
  mkdir "$alias_dir"
  ln -s "$runtime_b/openclaw.mjs" "$alias_dir/openclaw"
  if common_env "$backup" --output-dir "$RELEASES" --runtime-dir "$RUNTIME" --health-bin "$alias_dir/openclaw" --yes >/dev/null 2>&1; then return 1; fi
  assert_runtime_identity || return
  assert test ! -e "$RELEASES/current-good.tgz"
}

test_backup_rejects_source_mutation() {
  setup_case active
  local real_cp
  real_cp="$(command -v cp)"
  cat > "$FAKES/cp" <<EOF
#!/usr/bin/env bash
set -euo pipefail
"$real_cp" "\$@"
if [[ "\${FAKE_MUTATE_BACKUP_SOURCE:-}" == 1 && "\${*: -1}" == */snapshot/openclaw ]]; then
  printf 'mutated-during-snapshot\\n' > "\${FAKE_MUTATE_SOURCE_PATH:?}/exact-runtime-marker"
fi
EOF
  chmod +x "$FAKES/cp"
  echo old > "$RELEASES/old"; ln -s old "$RELEASES/current-good.tgz"
  local rc=0
  FAKE_MUTATE_BACKUP_SOURCE=1 FAKE_MUTATE_SOURCE_PATH="$RUNTIME" backup_cmd >/dev/null 2>&1 || rc=$?
  assert test "$rc" -ne 0 || return
  assert test "$(readlink "$RELEASES/current-good.tgz")" = old || return
  assert test "$(cat "$RUNTIME/exact-runtime-marker")" = mutated-during-snapshot || return
  assert test -z "$(find "$RELEASES" -name 'openclaw-*.tgz' -print -quit)"
}

test_service_state_fail_closed() {
  local tool="$1" state="$2"
  setup_case "$state"
  local before rc=0
  before="$(find "$RELEASES" -mindepth 1 ! -name .runtime.lock -printf '%P %y %l\n' | sort | sha256sum | awk '{print $1}')"
  if [[ "$tool" == install ]]; then install_cmd >/dev/null 2>&1 || rc=$?; else rollback_cmd >/dev/null 2>&1 || rc=$?; fi
  assert test "$rc" -ne 0 || return
  assert_runtime_identity || return
  assert test "$(cat "$SERVICE_STATE")" = "$state" || return
  assert test "$before" = "$(find "$RELEASES" -mindepth 1 ! -name .runtime.lock -printf '%P %y %l\n' | sort | sha256sum | awk '{print $1}')" || return
  assert_no_runtime_tx || return
  assert_snapshot_staging_cleaned || return
  assert_lock_released
}

test_action_failure_recovers() {
  local tool="$1" action="$2"
  setup_case active
  local rc=0
  if [[ "$action" == stop ]]; then
    if [[ "$tool" == install ]]; then FAKE_SYSTEMCTL_FAIL_STOP_AT=1 install_cmd >/dev/null 2>&1 || rc=$?; else FAKE_SYSTEMCTL_FAIL_STOP_AT=1 rollback_cmd >/dev/null 2>&1 || rc=$?; fi
  else
    if [[ "$tool" == install ]]; then FAKE_SYSTEMCTL_FAIL_START_AT=1 install_cmd >/dev/null 2>&1 || rc=$?; else FAKE_SYSTEMCTL_FAIL_START_AT=1 rollback_cmd >/dev/null 2>&1 || rc=$?; fi
  fi
  assert test "$rc" -ne 0 || return
  assert_original_restored active || return
  assert test -n "$(find "$(dirname "$RUNTIME")" -mindepth 1 -maxdepth 1 -type d -name ".openclaw-${tool}-tx.*" -print -quit)" || return
  assert_lock_released
}

test_recovery_start_failure_retains() {
  local tool="$1"
  setup_case active
  local rc=0
  if [[ "$tool" == install ]]; then
    FAKE_UNHEALTHY_VERSION=2.0.0 FAKE_SYSTEMCTL_FAIL_START_AT=2 install_cmd >/dev/null 2>&1 || rc=$?
  else
    FAKE_UNHEALTHY_VERSION=0.9.0 FAKE_SYSTEMCTL_FAIL_START_AT=2 rollback_cmd >/dev/null 2>&1 || rc=$?
  fi
  assert test "$rc" -eq 3 || return
  assert_runtime_identity || return
  assert test "$(cat "$SERVICE_STATE")" = inactive || return
  local tx
  tx="$(find "$(dirname "$RUNTIME")" -mindepth 1 -maxdepth 1 -type d -name ".openclaw-${tool}-tx.*" -print -quit)"
  if [[ -z "$tx" ]]; then find "$(dirname "$RUNTIME")" -mindepth 1 -maxdepth 1 -printf 'unexpected transaction entry: %f\n' >&2; fi
  assert test -n "$tx" || return
  assert test "$(stat -c %a "$tx")" = 700 || return
  if [[ "$tool" == install ]]; then
    assert test -n "$(find "$RELEASES" -name 'openclaw-*.tgz' -print -quit)" || return
  else
    assert test -f "$RESTORE_ARCHIVE" || return
  fi
  assert_lock_released
}

test_recovery_stop_failure_retains() {
  local tool="$1"
  setup_case active
  local rc=0 expected_marker tx original_path
  if [[ "$tool" == install ]]; then
    expected_marker=candidate-exact
    FAKE_UNHEALTHY_VERSION=2.0.0 FAKE_SYSTEMCTL_FAIL_STOP_AT=2 install_cmd >/dev/null 2>&1 || rc=$?
    tx="$(find "$(dirname "$RUNTIME")" -mindepth 1 -maxdepth 1 -type d -name '.openclaw-install-tx.*' -print -quit)"
    original_path="$tx/previous-runtime"
  else
    expected_marker=known-good-exact
    FAKE_UNHEALTHY_VERSION=0.9.0 FAKE_SYSTEMCTL_FAIL_STOP_AT=2 rollback_cmd >/dev/null 2>&1 || rc=$?
    tx="$(find "$(dirname "$RUNTIME")" -mindepth 1 -maxdepth 1 -type d -name '.openclaw-rollback-tx.*' -print -quit)"
    original_path="$tx/replaced-runtime"
  fi
  assert test "$rc" -eq 3 || return
  assert test "$(cat "$SERVICE_STATE")" = active || return
  assert test "$(cat "$RUNTIME/exact-runtime-marker")" = "$expected_marker" || return
  assert test -d "$original_path" || return
  assert test "$(runtime_tree_digest "$original_path")" = "$ORIGINAL_RUNTIME_DIGEST" || return
  assert test "$(stat -c '%d:%i' "$original_path")" = "$ORIGINAL_RUNTIME_ID" || return
  assert test "$(stat -c %a "$tx")" = 700 || return
  assert_lock_released
}

test_corrupt_partial_archive_list() {
  local tool="$1"
  setup_case active
  install_fake_corrupt_tar
  local rc=0
  case "$tool" in
    install) FAKE_CORRUPT_TAR_LIST=package install_cmd >/dev/null 2>&1 || rc=$? ;;
    rollback) FAKE_CORRUPT_TAR_LIST=runtime rollback_cmd >/dev/null 2>&1 || rc=$? ;;
    backup)
      echo old > "$RELEASES/old"; ln -s old "$RELEASES/current-good.tgz"
      FAKE_CORRUPT_TAR_LIST=runtime backup_cmd >/dev/null 2>&1 || rc=$?
      ;;
  esac
  assert test "$rc" -ne 0 || return
  assert_runtime_identity || return
  assert test "$(cat "$SERVICE_STATE")" = active || return
  if [[ "$tool" == backup ]]; then assert test "$(readlink "$RELEASES/current-good.tgz")" = old || return; fi
  assert_lock_released
}

setup_pointer_baseline() {
  echo symlink-old-bytes > "$RELEASES/old-runtime.tgz"
  ln -s old-runtime.tgz "$RELEASES/current-good.tgz"
  printf 'regular checksum pointer bytes\n' > "$RELEASES/current-good.tgz.sha256"
  rm -f "$RELEASES/current-good.tgz.manifest.txt"
}

assert_pointer_baseline() {
  assert test -L "$RELEASES/current-good.tgz" || return
  assert test "$(readlink "$RELEASES/current-good.tgz")" = old-runtime.tgz || return
  assert test -f "$RELEASES/current-good.tgz.sha256" || return
  assert test ! -L "$RELEASES/current-good.tgz.sha256" || return
  assert test "$(cat "$RELEASES/current-good.tgz.sha256")" = 'regular checksum pointer bytes' || return
  assert test ! -e "$RELEASES/current-good.tgz.manifest.txt" || return
}

test_pointer_atomic_hook() {
  local phase="$1" mode="$2"
  setup_case active
  setup_pointer_baseline
  local rc=0
  OPENCLAW_TEST_HOOK_PHASE="$phase" OPENCLAW_TEST_HOOK_MODE="$mode" backup_cmd >/dev/null 2>&1 || rc=$?
  assert test "$rc" -ne 0 || return
  case "$mode" in INT) assert test "$rc" -eq 130 || return ;; TERM) assert test "$rc" -eq 143 || return ;; esac
  assert_pointer_baseline || return
  assert_runtime_identity || return
  assert test "$(cat "$SERVICE_STATE")" = active || return
  assert test -z "$(find "$RELEASES" -mindepth 1 -maxdepth 1 -type d -name '.openclaw-backup-tx.*' -print -quit)" || return
  assert_lock_released
}

test_pointer_restore_failure_retains_journal() {
  setup_case active
  setup_pointer_baseline
  local real_mv rc=0
  real_mv="$(command -v mv)"
  # Source operand is not position-stable because options precede it.
  cat > "$FAKES/mv" <<EOF
#!/usr/bin/env bash
set -euo pipefail
for arg in "\$@"; do
  if [[ "\${FAKE_FAIL_POINTER_RESTORE:-}" == 1 && "\$arg" == */restore-* ]]; then exit 88; fi
done
exec "$real_mv" "\$@"
EOF
  chmod +x "$FAKES/mv"
  FAKE_FAIL_POINTER_RESTORE=1 OPENCLAW_TEST_HOOK_PHASE=after-pointer-current-good.tgz OPENCLAW_TEST_HOOK_MODE=ERR \
    backup_cmd >/dev/null 2>&1 || rc=$?
  assert test "$rc" -eq 3 || return
  local tx="$RELEASES/$(find "$RELEASES" -mindepth 1 -maxdepth 1 -type d -name '.openclaw-backup-tx.*' -printf '%f\n' | head -1)"
  assert test -d "$tx/pointers/old" || return
  assert test -L "$tx/pointers/old/current-good.tgz" || return
  assert test "$(readlink "$tx/pointers/old/current-good.tgz")" = old-runtime.tgz || return
  assert test -f "$tx/pointers/old/current-good.tgz.sha256" || return
  assert test -f "$tx/pointers/absent/current-good.tgz.manifest.txt" || return
  assert_lock_released
}

test_pointer_repeated_signal_recovery() {
  setup_case active
  setup_pointer_baseline
  local rc=0
  OPENCLAW_TEST_RECOVERY_SIGNALS=repeated OPENCLAW_TEST_HOOK_PHASE=after-pointer-current-good.tgz \
    OPENCLAW_TEST_HOOK_MODE=ERR backup_cmd >/dev/null 2>&1 || rc=$?
  assert test "$rc" -ne 0 || return
  assert_pointer_baseline || return
  assert test -z "$(find "$RELEASES" -mindepth 1 -maxdepth 1 -type d -name '.openclaw-backup-tx.*' -print -quit)"
}

test_pointer_post_commit_is_complete() {
  setup_case active
  setup_pointer_baseline
  local rc=0
  OPENCLAW_TEST_HOOK_PHASE=after-pointer-commit OPENCLAW_TEST_HOOK_MODE=ERR backup_cmd >/dev/null 2>&1 || rc=$?
  assert test "$rc" -ne 0 || return
  for name in current-good.tgz current-good.tgz.sha256 current-good.tgz.manifest.txt; do assert test -L "$RELEASES/$name" || return; done
  assert test -f "$(readlink -f "$RELEASES/current-good.tgz")" || return
  assert test -z "$(find "$RELEASES" -mindepth 1 -maxdepth 1 -type d -name '.openclaw-backup-tx.*' -print -quit)"
}

test_collision_proof_transaction_paths() {
  local tool="$1"
  setup_case active
  local parent="$(dirname "$RUNTIME")" collision
  if [[ "$tool" == install ]]; then collision="$parent/openclaw.previous-20260923T000000Z-1"; else collision="$parent/openclaw.replaced-20260923T000000Z-1"; fi
  mkdir -p "$collision/nested"; echo collision-sentinel > "$collision/nested/value"
  if [[ "$tool" == install ]]; then install_cmd >/dev/null; else rollback_cmd >/dev/null; fi
  assert test "$(cat "$collision/nested/value")" = collision-sentinel || return
  local tx
  tx="$(find "$parent" -mindepth 1 -maxdepth 1 -type d -name ".openclaw-${tool}-tx.*" -print -quit)"
  assert test -n "$tx" || return
  assert test "$(stat -c %a "$tx")" = 700 || return
  if [[ "$tool" == install ]]; then
    assert test -f "$tx/previous-runtime/exact-runtime-marker" || return
    assert test ! -e "$tx/previous-runtime/openclaw" || return
  else
    assert test -f "$tx/replaced-runtime/exact-runtime-marker" || return
    assert test ! -e "$tx/replaced-runtime/openclaw" || return
  fi
  assert test "$(cat "$SERVICE_STATE")" = active || return
  assert_lock_released
}

run_case "dry run is non-mutating" test_dry_run
run_case "running install succeeds with structured health" test_install_success_running
run_case "stopped install stays stopped and preserves known-good" test_install_success_stopped_preserves_good
run_case "unhealthy baseline preserves known-good" test_baseline_unhealthy_preserves_good
run_case "backup creation failure preserves known-good" test_backup_failure_preserves_good
run_case "candidate health failure restores exact runtime" test_install_health_failure_recovers
run_case "rollback health failure restores exact runtime" test_rollback_health_failure_recovers
run_case "stopped rollback succeeds without starting service" test_rollback_success_stopped
run_case "installer consumes validated snapshot after source replacement" test_install_source_replacement_uses_snapshot
run_case "rollback consumes validated snapshot after source replacement" test_rollback_source_replacement_uses_snapshot
run_case "shared lock blocks installer and rollback" test_shared_lock_contention
run_case "smoke test requires structured health schema" test_smoke_structured_health
run_case "standalone backup refuses unhealthy baseline" test_backup_refuses_unhealthy_baseline
run_case "pointer promotion failure restores all known-good pointers" test_backup_pointer_failure_restores_all_pointers
run_case "standalone backup accepts canonical same-runtime health binding" test_backup_health_binding_positive
run_case "standalone backup rejects runtime A health from runtime B" test_backup_health_binding_mismatch
run_case "standalone backup rejects symlink alias escape to runtime B" test_backup_health_alias_escape
run_case "standalone backup rejects source mutation during snapshot" test_backup_rejects_source_mutation
for tool in install rollback; do
  for state in failed activating deactivating unknown-unit malformed timeout query-error permission; do
    run_case "$tool aborts before mutation for service state $state" test_service_state_fail_closed "$tool" "$state"
  done
  run_case "$tool stop failure recovers exact original" test_action_failure_recovers "$tool" stop
  run_case "$tool start failure recovers exact original" test_action_failure_recovers "$tool" start
  run_case "$tool recovery-start failure retains transaction" test_recovery_start_failure_retains "$tool"
  run_case "$tool recovery-stop failure retains exact original material" test_recovery_stop_failure_retains "$tool"
done
for tool in install rollback backup; do
  run_case "$tool rejects plausible partial archive list with producer failure" test_corrupt_partial_archive_list "$tool"
done
pointer_names_for_test=(current-good.tgz current-good.tgz.sha256 current-good.tgz.manifest.txt)
for mode in ERR INT TERM EXIT; do
  for pointer_name in "${pointer_names_for_test[@]}"; do
    run_case "pointer transaction recovers $mode immediately before $pointer_name rename" test_pointer_atomic_hook "before-pointer-$pointer_name" "$mode"
    run_case "pointer transaction recovers $mode immediately after $pointer_name rename" test_pointer_atomic_hook "after-pointer-$pointer_name" "$mode"
  done
done
run_case "pointer restore failure is loud and retains complete journal" test_pointer_restore_failure_retains_journal
run_case "repeated recovery signals are deterministic and nonrecursive" test_pointer_repeated_signal_recovery
run_case "post-commit interruption leaves a complete pointer set" test_pointer_post_commit_is_complete
run_case "installer transaction paths are private and collision-proof" test_collision_proof_transaction_paths install
run_case "rollback transaction paths are private and collision-proof" test_collision_proof_transaction_paths rollback

install_phases=(before-stop after-stop after-move-original after-activate-candidate after-link after-start after-health)
rollback_phases=(before-stop after-stop after-move-original after-activate-restored after-link after-start after-health)
install_stopped_phases=(before-stop after-stop after-move-original after-activate-candidate after-link after-stopped-verify)
rollback_stopped_phases=(before-stop after-stop after-move-original after-activate-restored after-link after-stopped-verify)
for mode in ERR INT TERM EXIT; do
  for phase in "${install_phases[@]}"; do run_case "installer recovers $mode at $phase" test_hook_matrix install "$phase" "$mode" active; done
  for phase in "${rollback_phases[@]}"; do run_case "rollback recovers $mode at $phase" test_hook_matrix rollback "$phase" "$mode" active; done
  for phase in "${install_stopped_phases[@]}"; do run_case "stopped installer recovers $mode at $phase" test_hook_matrix install "$phase" "$mode" inactive; done
  for phase in "${rollback_stopped_phases[@]}"; do run_case "stopped rollback recovers $mode at $phase" test_hook_matrix rollback "$phase" "$mode" inactive; done
done
for tool in install rollback; do
  for kind in missing malformed ambiguous mismatch misnamed; do run_case "$tool rejects $kind checksum" test_checksum_failure "$kind" "$tool"; done
done
for kind in repository ref sha event package-checksum duplicate; do run_case "installer rejects provenance $kind" test_provenance_failure "$kind"; done

cleanup_case
echo "1..$((pass + fail))"
echo "passed=$pass failed=$fail"
(( fail == 0 ))
