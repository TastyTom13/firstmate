#!/usr/bin/env bash
# Tests for fm-hp-runner-check.sh, the Scout queue and self-hosted runner outage detector.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-hp-runner-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-hp-runner-check)

make_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state" "$home/config" "$home/fakebin"
  cat > "$home/fakebin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_TEST_GH_LOG:?}"
[ -z "${FM_TEST_GH_SLEEP:-}" ] || sleep "$FM_TEST_GH_SLEEP"
case "$*" in
  *'/actions/runners'*)
    [ "${FM_TEST_RUNNERS_FAIL:-0}" = 0 ] || { printf 'runner api failed\n' >&2; exit 1; }
    printf '%s\n' "${FM_TEST_RUNNERS_JSON:?}"
    ;;
  *'/actions/runs'*)
    [ "${FM_TEST_RUNS_FAIL:-0}" = 0 ] || { printf 'runs api failed\n' >&2; exit 1; }
    printf '{"total_count":%s,"workflow_runs":[]}\n' "${FM_TEST_QUEUE_COUNT:?}"
    ;;
  *)
    printf 'unexpected gh call: %s\n' "$*" >&2
    exit 2
    ;;
esac
SH
  chmod 0755 "$home/fakebin/gh"
  printf '%s\n' "$home"
}

run_check() {
  local home=$1 out=$2
  shift 2
  local status=0
  env FM_HOME="$home" PATH="$home/fakebin:$PATH" FM_TEST_GH_LOG="$home/gh.log" \
    FM_TEST_RUNNERS_JSON="${FM_TEST_RUNNERS_JSON:?}" FM_TEST_QUEUE_COUNT="${FM_TEST_QUEUE_COUNT:?}" \
    "$@" "$CHECK" check >"$out" 2>"$out.err" || status=$?
  expect_code 0 "$status" "check exit"
  [ ! -s "$out.err" ] || fail "check wrote stderr: $(cat "$out.err")"
}

RUNNERS_HP_OFFLINE='{"total_count":2,"runners":[{"name":"hp-scout-1","status":"offline","busy":false},{"name":"github-hosted-fixture","status":"online","busy":true}]}'
RUNNERS_HP_BUSY='{"total_count":2,"runners":[{"name":"hp-scout-1","status":"online","busy":true},{"name":"other-fixture","status":"online","busy":false}]}'
RUNNERS_ALL_IDLE='{"total_count":2,"runners":[{"name":"hp-scout-1","status":"online","busy":false},{"name":"other-fixture","status":"online","busy":false}]}'

# Regression: one high-queue observation must not page, but the second consecutive
# observation while the named runner is offline must emit exactly one line.
test_two_consecutive_offline_polls_wake_once() {
  local home out report
  home=$(make_home offline)
  out="$home/out"
  FM_TEST_RUNNERS_JSON=$RUNNERS_HP_OFFLINE FM_TEST_QUEUE_COUNT=4 run_check "$home" "$out"
  [ ! -s "$out" ] || fail "the first qualifying poll woke early: $(cat "$out")"
  assert_contains "$(cat "$home/gh.log")" "repos/TastyTom13/Scout/actions/runners?per_page=100" "the check did not read Scout's runners"
  assert_contains "$(cat "$home/gh.log")" "repos/TastyTom13/Scout/actions/runs?status=queued&per_page=1" "the check did not read Scout's queued workflow runs"

  FM_TEST_RUNNERS_JSON=$RUNNERS_HP_OFFLINE FM_TEST_QUEUE_COUNT=4 run_check "$home" "$out"
  report=$(cat "$out")
  assert_contains "$report" "hp-scout-1 is offline" "the outage report does not name the offline runner"
  assert_contains "$report" "4 queued Scout runs" "the outage report does not name the queue depth"
  [ "$(wc -l < "$out" | tr -d '[:space:]')" = 1 ] || fail "the outage report must be exactly one line"

  FM_TEST_RUNNERS_JSON=$RUNNERS_HP_OFFLINE FM_TEST_QUEUE_COUNT=4 run_check "$home" "$out"
  [ ! -s "$out" ] || fail "an unchanged outage was reported again: $(cat "$out")"
  pass "two consecutive high-queue polls with hp-scout-1 offline wake once"
}

# A clear poll separates episodes and resets the consecutive-poll streak.
test_clear_poll_resets_streak_and_episode() {
  local home out
  home=$(make_home reset)
  out="$home/out"
  FM_TEST_RUNNERS_JSON=$RUNNERS_ALL_IDLE FM_TEST_QUEUE_COUNT=4 run_check "$home" "$out"
  FM_TEST_RUNNERS_JSON=$RUNNERS_ALL_IDLE FM_TEST_QUEUE_COUNT=3 run_check "$home" "$out"
  FM_TEST_RUNNERS_JSON=$RUNNERS_ALL_IDLE FM_TEST_QUEUE_COUNT=4 run_check "$home" "$out"
  [ ! -s "$out" ] || fail "a streak crossed a non-qualifying queue poll: $(cat "$out")"
  FM_TEST_RUNNERS_JSON=$RUNNERS_ALL_IDLE FM_TEST_QUEUE_COUNT=4 run_check "$home" "$out"
  assert_contains "$(cat "$out")" "every online runner is idle" "the idle-runner outage was not reported after a fresh two-poll streak"
  pass "a clear poll resets both the streak and the reported outage episode"
}

# A busy online runner means work can run, unless the specifically watched HP
# runner is offline - the two outage predicates are deliberately independent.
test_busy_capacity_and_offline_hp_are_distinguished() {
  local home out
  home=$(make_home capacity)
  out="$home/out"
  FM_TEST_RUNNERS_JSON=$RUNNERS_HP_BUSY FM_TEST_QUEUE_COUNT=9 run_check "$home" "$out"
  FM_TEST_RUNNERS_JSON=$RUNNERS_HP_BUSY FM_TEST_QUEUE_COUNT=9 run_check "$home" "$out"
  [ ! -s "$out" ] || fail "a busy online runner was reported as an outage: $(cat "$out")"

  FM_TEST_RUNNERS_JSON=$RUNNERS_HP_OFFLINE FM_TEST_QUEUE_COUNT=9 run_check "$home" "$out"
  FM_TEST_RUNNERS_JSON=$RUNNERS_HP_OFFLINE FM_TEST_QUEUE_COUNT=9 run_check "$home" "$out"
  assert_contains "$(cat "$out")" "hp-scout-1 is offline" "the watched runner being offline was hidden by another busy runner"
  pass "busy capacity suppresses the idle predicate but never hides hp-scout-1 being offline"
}

# Both threshold values are local operator policy, while the defaults remain a
# queue depth greater than three over two consecutive polls.
test_config_overrides_queue_and_poll_thresholds() {
  local home out
  home=$(make_home config)
  out="$home/out"
  cat > "$home/config/hp-runner-check" <<'EOF'
QUEUE_THRESHOLD=7
CONSECUTIVE_POLLS=3
EOF
  FM_TEST_RUNNERS_JSON=$RUNNERS_ALL_IDLE FM_TEST_QUEUE_COUNT=7 run_check "$home" "$out"
  [ ! -s "$out" ] || fail "queue depth equal to the configured threshold qualified"
  FM_TEST_RUNNERS_JSON=$RUNNERS_ALL_IDLE FM_TEST_QUEUE_COUNT=8 run_check "$home" "$out"
  FM_TEST_RUNNERS_JSON=$RUNNERS_ALL_IDLE FM_TEST_QUEUE_COUNT=8 run_check "$home" "$out"
  [ ! -s "$out" ] || fail "the configured three-poll threshold woke after two polls"
  FM_TEST_RUNNERS_JSON=$RUNNERS_ALL_IDLE FM_TEST_QUEUE_COUNT=8 run_check "$home" "$out"
  assert_contains "$(cat "$out")" "8 queued Scout runs" "the configured threshold did not wake on its third poll"
  pass "config/hp-runner-check overrides the queue and consecutive-poll thresholds"
}

# An unreadable API result is itself actionable because otherwise the detector
# could go silently blind, and it must break a qualifying streak.
test_api_failure_wakes_and_breaks_streak() {
  local home out
  home=$(make_home api-failure)
  out="$home/out"
  FM_TEST_RUNNERS_JSON=$RUNNERS_ALL_IDLE FM_TEST_QUEUE_COUNT=4 run_check "$home" "$out"
  FM_TEST_RUNNERS_JSON=$RUNNERS_ALL_IDLE FM_TEST_QUEUE_COUNT=4 run_check "$home" "$out" FM_TEST_RUNNERS_FAIL=1
  assert_contains "$(cat "$out")" "hp runner check failed" "a runner API failure was silent"
  FM_TEST_RUNNERS_JSON=$RUNNERS_ALL_IDLE FM_TEST_QUEUE_COUNT=4 run_check "$home" "$out"
  [ ! -s "$out" ] || fail "an API failure did not break the consecutive successful poll streak"
  pass "an API failure wakes and breaks the qualifying streak"
}

# A hung GitHub CLI cannot consume the watcher's own check deadline.
test_slow_github_read_finishes_inside_the_watcher_bound() {
  local home out started elapsed
  home=$(make_home timeout)
  out="$home/out"
  started=$(date +%s)
  FM_TEST_RUNNERS_JSON=$RUNNERS_ALL_IDLE FM_TEST_QUEUE_COUNT=4 \
    run_check "$home" "$out" FM_CHECK_TIMEOUT=4 FM_HP_RUNNER_PROBE_SECS=10 FM_TEST_GH_SLEEP=20
  elapsed=$(($(date +%s) - started))
  [ "$elapsed" -lt 4 ] || fail "a timed-out GitHub read took ${elapsed}s, not less than FM_CHECK_TIMEOUT"
  assert_contains "$(cat "$out")" "timed out" "a bounded GitHub read did not report its timeout"
  pass "a slow GitHub read is stopped before the watcher check timeout"
}

# Arm is the public setup path: it must create the owner-only generated shim and
# the byte binding, and the shim must retain its home when run elsewhere.
test_arm_writes_registers_and_runs_the_shim() {
  local home out status=0 mode
  home=$(make_home arm)
  out="$home/out"
  FM_HOME="$home" "$CHECK" arm >"$out" 2>"$out.err" || status=$?
  expect_code 0 "$status" "arm exit"
  assert_present "$home/state/hp-runner.check.sh" "arm did not write the check shim"
  assert_present "$home/state/hp-runner.check-trust" "arm did not register the check shim"
  mode=$(bash -c '. "$1"; fm_pr_file_mode "$2"' _ \
    "$ROOT/bin/fm-pr-lib.sh" "$home/state/hp-runner.check.sh")
  [ "$mode" = 700 ] || fail "armed shim mode is $mode, expected 700"

  status=0
  (cd / && env PATH="$home/fakebin:$PATH" FM_TEST_GH_LOG="$home/gh.log" \
    FM_TEST_RUNNERS_JSON="$RUNNERS_HP_OFFLINE" FM_TEST_QUEUE_COUNT=4 \
    "$home/state/hp-runner.check.sh" >"$out" 2>"$out.err") || status=$?
  expect_code 0 "$status" "armed shim first run exit"
  [ ! -s "$out" ] || fail "armed shim ignored the two-poll default"
  status=0
  (cd / && env PATH="$home/fakebin:$PATH" FM_TEST_GH_LOG="$home/gh.log" \
    FM_TEST_RUNNERS_JSON="$RUNNERS_HP_OFFLINE" FM_TEST_QUEUE_COUNT=4 \
    "$home/state/hp-runner.check.sh" >"$out" 2>"$out.err") || status=$?
  expect_code 0 "$status" "armed shim second run exit"
  assert_contains "$(cat "$out")" "hp-scout-1 is offline" "armed shim did not run against its embedded home"
  pass "arm writes a mode-0700 registered shim that keeps its resolved home"
}

test_two_consecutive_offline_polls_wake_once
test_clear_poll_resets_streak_and_episode
test_busy_capacity_and_offline_hp_are_distinguished
test_config_overrides_queue_and_poll_thresholds
test_api_failure_wakes_and_breaks_streak
test_slow_github_read_finishes_inside_the_watcher_bound
test_arm_writes_registers_and_runs_the_shim
