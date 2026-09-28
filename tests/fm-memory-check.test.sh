#!/usr/bin/env bash
# Tests for fm-memory-check.sh, the host low-memory early-warning check.
# vm_stat, memory_pressure, and ps are PATH fakes so no assertion depends on
# the host's live memory numbers.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-memory-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-memory-check)

# 16 KiB pages: 65536 pages is exactly 1 GiB.
PAGES_PER_GB=65536

make_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state" "$home/config" "$home/fakebin"
  cat > "$home/fakebin/vm_stat" <<'SH'
#!/usr/bin/env bash
[ -z "${FM_TEST_VM_SLEEP:-}" ] || sleep "$FM_TEST_VM_SLEEP"
printf 'Mach Virtual Memory Statistics: (page size of %s bytes)\n' "${FM_TEST_PAGE_SIZE:-16384}"
printf 'Pages free:                               %s.\n' "${FM_TEST_FREE_PAGES:?}"
printf 'Pages active:                             1398998.\n'
printf 'Pages speculative:                        %s.\n' "${FM_TEST_SPEC_PAGES:-0}"
SH
  cat > "$home/fakebin/memory_pressure" <<'SH'
#!/usr/bin/env bash
printf 'The system has 68719476736 (4194304 pages with a page size of 16384).\n'
printf 'System-wide memory free percentage: %s%%\n' "${FM_TEST_FREE_PERCENT:?}"
SH
  cat > "$home/fakebin/ps" <<'SH'
#!/usr/bin/env bash
printf '%s\n' \
  '  1048576 /usr/sbin/small' \
  ' 40265318 /opt/homebrew/bin/ollama' \
  '   524288 /usr/libexec/tiny' \
  ' 12582912 /Applications/Docker.app/Contents/MacOS/com.docker.virtualization' \
  '  3250585 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome' \
  '  2097152 node' \
  '  4194304 /Users/me/.local/bin/claude'
SH
  chmod 0755 "$home/fakebin/vm_stat" "$home/fakebin/memory_pressure" "$home/fakebin/ps"
  printf '%s\n' "$home"
}

# run_check <home> <out> [VAR=value ...] - one watcher-style poll.
run_check() {
  local home=$1 out=$2
  shift 2
  local status=0
  env FM_HOME="$home" PATH="$home/fakebin:$PATH" \
    FM_TEST_FREE_PAGES="${FM_TEST_FREE_PAGES:?}" FM_TEST_FREE_PERCENT="${FM_TEST_FREE_PERCENT:?}" \
    "$@" "$CHECK" check >"$out" 2>"$out.err" || status=$?
  expect_code 0 "$status" "check exit"
  [ ! -s "$out.err" ] || fail "check wrote stderr: $(cat "$out.err")"
}

LOW_PAGES=$((4 * PAGES_PER_GB))
HIGH_PAGES=$((20 * PAGES_PER_GB))

# Regression: one low-memory observation must not page, the second consecutive
# one must emit exactly one line that already names the top consumers, and an
# unchanged episode stays silent afterwards.
test_low_free_memory_reports_once_after_the_streak() {
  local home out report
  home=$(make_home low)
  out="$home/out"
  FM_TEST_FREE_PAGES=$LOW_PAGES FM_TEST_FREE_PERCENT=40 run_check "$home" "$out" FM_TEST_SPEC_PAGES=$((PAGES_PER_GB / 2))
  [ ! -s "$out" ] || fail "the first low-memory poll woke early: $(cat "$out")"

  FM_TEST_FREE_PAGES=$LOW_PAGES FM_TEST_FREE_PERCENT=40 run_check "$home" "$out" FM_TEST_SPEC_PAGES=$((PAGES_PER_GB / 2))
  report=$(cat "$out")
  [ "$(wc -l < "$out" | tr -d '[:space:]')" = 1 ] || fail "the low-memory report must be exactly one line: $report"
  assert_contains "$report" "4.5 GB free" "the report does not count free plus speculative pages"
  assert_contains "$report" "40% free" "the report does not name the free percentage"
  assert_contains "$report" "ollama 38.4 GB, com.docker.virtualization 12.0 GB, claude 4.0 GB, Google Chrome 3.1 GB, node 2.0 GB" \
    "the report does not list the top five processes by resident memory"
  assert_not_contains "$report" "small" "the report listed more than five processes"

  FM_TEST_FREE_PAGES=$LOW_PAGES FM_TEST_FREE_PERCENT=40 run_check "$home" "$out"
  [ ! -s "$out" ] || fail "an unchanged low-memory episode was reported again: $(cat "$out")"
  pass "low free memory reports once after two consecutive polls and then stays silent"
}

# The free-percentage predicate is independent of the gigabyte predicate.
test_low_free_percentage_alone_reports() {
  local home out
  home=$(make_home percent)
  out="$home/out"
  FM_TEST_FREE_PAGES=$HIGH_PAGES FM_TEST_FREE_PERCENT=12 run_check "$home" "$out"
  FM_TEST_FREE_PAGES=$HIGH_PAGES FM_TEST_FREE_PERCENT=12 run_check "$home" "$out"
  [ ! -s "$out" ] || fail "a free percentage equal to the threshold qualified: $(cat "$out")"
  FM_TEST_FREE_PAGES=$HIGH_PAGES FM_TEST_FREE_PERCENT=11 run_check "$home" "$out"
  FM_TEST_FREE_PAGES=$HIGH_PAGES FM_TEST_FREE_PERCENT=11 run_check "$home" "$out"
  assert_contains "$(cat "$out")" "11% free" "a low free percentage with plenty of free gigabytes was not reported"
  pass "a low free percentage alone reports"
}

# A clear poll separates episodes and resets the consecutive-poll streak.
test_clear_poll_resets_streak_and_episode() {
  local home out
  home=$(make_home reset)
  out="$home/out"
  FM_TEST_FREE_PAGES=$LOW_PAGES FM_TEST_FREE_PERCENT=40 run_check "$home" "$out"
  FM_TEST_FREE_PAGES=$LOW_PAGES FM_TEST_FREE_PERCENT=40 run_check "$home" "$out"
  assert_contains "$(cat "$out")" "4.0 GB free" "the first episode was not reported"
  FM_TEST_FREE_PAGES=$((6 * PAGES_PER_GB)) FM_TEST_FREE_PERCENT=40 run_check "$home" "$out"
  [ ! -s "$out" ] || fail "a clear poll at exactly the gigabyte threshold printed: $(cat "$out")"
  FM_TEST_FREE_PAGES=$LOW_PAGES FM_TEST_FREE_PERCENT=40 run_check "$home" "$out"
  [ ! -s "$out" ] || fail "a streak crossed a clear poll: $(cat "$out")"
  FM_TEST_FREE_PAGES=$LOW_PAGES FM_TEST_FREE_PERCENT=40 run_check "$home" "$out"
  assert_contains "$(cat "$out")" "4.0 GB free" "a new episode after a clear poll was not reported"
  pass "a clear poll resets both the streak and the reported episode"
}

# Thresholds are local operator policy.
test_config_overrides_thresholds() {
  local home out
  home=$(make_home config)
  out="$home/out"
  cat > "$home/config/memory-check" <<'EOF'
# local policy
FREE_GB_THRESHOLD=10

FREE_PERCENT_THRESHOLD=5
CONSECUTIVE_POLLS=1
EOF
  FM_TEST_FREE_PAGES=$((9 * PAGES_PER_GB)) FM_TEST_FREE_PERCENT=40 run_check "$home" "$out"
  assert_contains "$(cat "$out")" "9.0 GB free" "the configured gigabyte and one-poll thresholds were not honoured"
  pass "config/memory-check overrides the thresholds"
}

# Unknown keys, duplicates, and malformed or out-of-range values are reported
# rather than silently defaulted, and an unchanged problem is reported once.
test_config_validation_rejects_bad_input() {
  local home out bad
  for bad in 'UNKNOWN_KEY=1' 'FREE_GB_THRESHOLD=0' 'FREE_GB_THRESHOLD=1001' \
    'FREE_PERCENT_THRESHOLD=101' 'CONSECUTIVE_POLLS=0' 'CONSECUTIVE_POLLS=abc' \
    'FREE_GB_THRESHOLD' $'FREE_GB_THRESHOLD=6\nFREE_GB_THRESHOLD=7'; do
    home=$(make_home "config-bad-$RANDOM")
    out="$home/out"
    printf '%s\n' "$bad" > "$home/config/memory-check"
    FM_TEST_FREE_PAGES=$HIGH_PAGES FM_TEST_FREE_PERCENT=40 run_check "$home" "$out"
    assert_contains "$(cat "$out")" "memory check failed:" "bad config line '$bad' was not reported"
    FM_TEST_FREE_PAGES=$HIGH_PAGES FM_TEST_FREE_PERCENT=40 run_check "$home" "$out"
    [ ! -s "$out" ] || fail "an unchanged config problem for '$bad' was reported again"
  done
  pass "config validation reports unknown keys, duplicates, and malformed values once"
}

# A host without vm_stat or memory_pressure leaves the detector blind, which is
# reported once per episode instead of passing silently.
test_missing_tool_reports_blind_once() {
  local home out tool sans
  for tool in vm_stat memory_pressure; do
    home=$(make_home "blind-$tool")
    out="$home/out"
    rm -f "$home/fakebin/$tool"
    sans=$(fm_test_base_path_sans "$PATH" "$tool")
    FM_TEST_FREE_PAGES=$LOW_PAGES FM_TEST_FREE_PERCENT=5 run_check "$home" "$out" PATH="$home/fakebin:$sans"
    assert_contains "$(cat "$out")" "cannot measure" "a missing $tool was not reported as a blind detector"
    assert_contains "$(cat "$out")" "$tool" "the blind report does not name the missing $tool"
    FM_TEST_FREE_PAGES=$LOW_PAGES FM_TEST_FREE_PERCENT=5 run_check "$home" "$out" PATH="$home/fakebin:$sans"
    [ ! -s "$out" ] || fail "an unchanged missing $tool was reported again: $(cat "$out")"
  done
  pass "a missing vm_stat or memory_pressure reports a blind detector once"
}

test_invalid_host_readings_are_rejected() {
  local home out
  for case_name in page-size percent; do
    home=$(make_home "invalid-$case_name")
    out="$home/out"
    if [ "$case_name" = page-size ]; then
      FM_TEST_PAGE_SIZE=0 FM_TEST_FREE_PAGES=$LOW_PAGES FM_TEST_FREE_PERCENT=40 run_check "$home" "$out"
    else
      FM_TEST_FREE_PAGES=$LOW_PAGES FM_TEST_FREE_PERCENT=101 run_check "$home" "$out"
    fi
    assert_contains "$(cat "$out")" "memory readings were out of range" \
      "invalid $case_name was not rejected"
    [ "$(wc -l < "$out" | tr -d '[:space:]')" = 1 ] || \
      fail "invalid $case_name produced an unexpected report: $(cat "$out")"
  done
  pass "invalid page size and free percentage readings are rejected"
}

# A hung probe cannot consume the watcher's own check deadline.
test_slow_probe_finishes_inside_the_watcher_bound() {
  local home out started elapsed
  home=$(make_home timeout)
  out="$home/out"
  started=$(date +%s)
  FM_TEST_FREE_PAGES=$LOW_PAGES FM_TEST_FREE_PERCENT=40 \
    run_check "$home" "$out" FM_CHECK_TIMEOUT=4 FM_TEST_VM_SLEEP=20
  elapsed=$(($(date +%s) - started))
  [ "$elapsed" -lt 4 ] || fail "a hung vm_stat took ${elapsed}s, not less than FM_CHECK_TIMEOUT"
  assert_contains "$(cat "$out")" "timed out" "a bounded probe did not report its timeout"
  pass "a hung probe is stopped before the watcher check timeout"
}

# Arm is the public setup path: it must create the owner-only generated shim and
# the byte binding, and the shim must keep its home when run elsewhere.
test_arm_writes_registers_and_runs_the_shim() {
  local home out status=0 mode
  home=$(make_home arm)
  out="$home/out"
  FM_HOME="$home" "$CHECK" arm >"$out" 2>"$out.err" || status=$?
  expect_code 0 "$status" "arm exit"
  assert_present "$home/state/memory.check.sh" "arm did not write the check shim"
  assert_present "$home/state/memory.check-trust" "arm did not register the check shim"
  mode=$(bash -c '. "$1"; fm_pr_file_mode "$2"' _ \
    "$ROOT/bin/fm-pr-lib.sh" "$home/state/memory.check.sh")
  [ "$mode" = 700 ] || fail "armed shim mode is $mode, expected 700"

  status=0
  (cd / && env PATH="$home/fakebin:$PATH" FM_TEST_FREE_PAGES=$LOW_PAGES FM_TEST_FREE_PERCENT=40 \
    "$home/state/memory.check.sh" >"$out" 2>"$out.err") || status=$?
  expect_code 0 "$status" "armed shim first run exit"
  [ ! -s "$out" ] || fail "armed shim ignored the two-poll default"
  status=0
  (cd / && env PATH="$home/fakebin:$PATH" FM_TEST_FREE_PAGES=$LOW_PAGES FM_TEST_FREE_PERCENT=40 \
    "$home/state/memory.check.sh" >"$out" 2>"$out.err") || status=$?
  expect_code 0 "$status" "armed shim second run exit"
  assert_contains "$(cat "$out")" "4.0 GB free" "armed shim did not run against its embedded home"

  status=0
  FM_HOME="$home" "$CHECK" disarm >"$out" 2>"$out.err" || status=$?
  expect_code 0 "$status" "disarm exit"
  assert_absent "$home/state/memory.check.sh" "disarm left the check shim"
  assert_absent "$home/state/.memory-check" "disarm left the poll record"
  pass "arm writes a mode-0700 registered shim that keeps its home, and disarm removes it"
}

test_low_free_memory_reports_once_after_the_streak
test_low_free_percentage_alone_reports
test_clear_poll_resets_streak_and_episode
test_config_overrides_thresholds
test_config_validation_rejects_bad_input
test_missing_tool_reports_blind_once
test_invalid_host_readings_are_rejected
test_slow_probe_finishes_inside_the_watcher_bound
test_arm_writes_registers_and_runs_the_shim
