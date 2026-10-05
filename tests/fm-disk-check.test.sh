#!/usr/bin/env bash
# Tests for fm-disk-check.sh, the standing disk leak watch.
# df, docker, and du are PATH fakes and HOME points at a scratch ~/.treehouse,
# so no assertion depends on the host's live disk, and the fake docker logs
# every call so the never-prune guarantee is checked, not assumed.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-disk-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-disk-check)

DAY=86400
T0=1790000000
# The check names the folder literally, as the captain reads it.
# shellcheck disable=SC2088
TH="~/.treehouse"

# kb <gb> - KiB for a whole number of decimal GB, the unit the check reports.
kb() {
  printf '%s\n' $(($1 * 1000000000 / 1024))
}

make_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state" "$home/config" "$home/fakebin" "$home/h/.treehouse/pool/1" "$home/h/.treehouse/pool/2"
  printf '%s\n' "$(kb 10)" > "$home/h/.treehouse/pool/1/.fake-kb"
  printf '%s\n' "$(kb 5)" > "$home/h/.treehouse/pool/2/.fake-kb"
  cat > "$home/fakebin/df" <<'SH'
#!/usr/bin/env bash
[ -z "${FM_TEST_DF_FAIL:-}" ] || exit 1
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
printf '/dev/disk3s5 1948404040 100 %s 41%% %s\n' "${FM_TEST_FREE_KB:?}" "${2:-/}"
SH
  cat > "$home/fakebin/docker" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_DOCKER_LOG"
[ -z "${FM_TEST_DOCKER_DOWN:-}" ] || { echo 'Cannot connect to the Docker daemon' >&2; exit 1; }
case "$1 $2" in
  'volume ls')
    i=0
    while [ "$i" -lt "${FM_TEST_DANGLING:-0}" ]; do printf 'dangling%s\n' "$i"; i=$((i + 1)); done
    ;;
  'system df')
    printf 'inuse0 9GB\n'
    i=0
    while [ "$i" -lt "${FM_TEST_DANGLING:-0}" ]; do printf 'dangling%s %s\n' "$i" "${FM_TEST_VOLUME_SIZE:-1MB}"; i=$((i + 1)); done
    ;;
  *) exit 1 ;;
esac
SH
  cat > "$home/fakebin/du" <<'SH'
#!/usr/bin/env bash
path=$2
[ -z "${FM_TEST_DU_SLEEP:-}" ] || sleep "$FM_TEST_DU_SLEEP"
[ -z "${FM_TEST_DU_NOSIZE:-}" ] || exit 1
if [ -f "$path" ]; then
  printf '%s\t%s\n' "$(cat "$path")" "$path"
elif [ -f "$path/.fake-kb" ]; then
  printf '%s\t%s\n' "$(cat "$path/.fake-kb")" "$path"
else
  printf '0\t%s\n' "$path"
fi
exit "${FM_TEST_DU_EXIT:-0}"
SH
  chmod +x "$home/fakebin/df" "$home/fakebin/docker" "$home/fakebin/du"
  printf '%s\n' "$home"
}

# run_check <home> <now> [VAR=value...] - stdout of one check run.
run_check() {
  local home=$1 now=$2 status=0 out
  shift 2
  out=$(env FM_CHECK_TIMEOUT=30 FM_TEST_FREE_KB="$(kb 500)" \
    FM_TEST_DOCKER_LOG="$home/docker.log" \
    "$@" HOME="$home/h" FM_HOME="$home" FM_DISK_CHECK_NOW="$now" \
    PATH="$home/fakebin:$PATH" "$CHECK" check 2>&1) || status=$?
  expect_code 0 "$status" "check exit"
  printf '%s' "$out"
}

test_help_and_usage() {
  local out rc=0
  out=$("$CHECK" --help 2>&1) || rc=$?
  expect_code 0 "$rc" "--help must exit 0"
  assert_contains "$out" "arm" "--help lists the arm action"
  assert_contains "$out" "never prunes" "--help states the check never prunes"
  rc=0
  out=$("$CHECK" bogus 2>&1) || rc=$?
  expect_code 2 "$rc" "an unknown action is a usage error"
  pass "fm-disk-check: help and usage"
}

test_arm_writes_and_binds_the_check_and_disarm_removes_it() {
  local home out
  home=$(make_home arm)
  out=$(FM_HOME="$home" "$CHECK" arm 2>&1) || fail "arm must succeed: $out"
  assert_contains "$out" "armed: state/disk.check.sh" "arm names the shim it wrote"
  assert_present "$home/state/disk.check-trust" "arm binds the shim for the watcher"
  assert_contains "$(cat "$home/state/disk.check.sh")" "fm-disk-check.sh check" "shim dispatches the check action"
  assert_contains "$(cat "$home/state/disk.check.sh")" "FM_HOME=$home" "shim pins the absolute home"
  out=$(FM_HOME="$home" "$CHECK" arm 2>&1) || fail "re-arm must succeed: $out"
  run_check "$home" "$T0" >/dev/null
  assert_present "$home/state/.disk-watch-history" "a run keeps its history"
  out=$(FM_HOME="$home" "$CHECK" disarm 2>&1) || fail "disarm must succeed: $out"
  assert_absent "$home/state/disk.check.sh" "disarm removes the shim"
  assert_absent "$home/state/disk.check-trust" "disarm removes the trust binding"
  assert_absent "$home/state/.disk-watch-history" "disarm removes the history"
  assert_absent "$home/state/.disk-watch" "disarm removes the report record"
  pass "fm-disk-check: arm writes and binds, re-arm is idempotent, disarm removes"
}

test_healthy_disk_is_silent_and_sampled() {
  local home out sample
  home=$(make_home healthy)
  out=$(run_check "$home" "$T0" FM_TEST_DANGLING=3)
  assert_equals "" "$out" "a healthy disk prints nothing"
  assert_equals fm-disk-watch-history-v1 "$(sed -n 1p "$home/state/.disk-watch-history")" "history carries its schema"
  sample=$(sed -n 2p "$home/state/.disk-watch-history")
  assert_contains "$sample" "$T0 $(kb 500) ok 3 " "the sample records the epoch, free space, and dangling count"
  assert_contains "$sample" " $(($(kb 10) + $(kb 5)))" "the sample records ~/.treehouse summed over its entries"
  out=$(run_check "$home" $((T0 + 300)) FM_TEST_DOCKER_DOWN=1)
  assert_equals "" "$out" "an unreachable docker is recorded, not woken on"
  assert_contains "$(sed -n 3p "$home/state/.disk-watch-history")" " unreachable - - " "the sample says docker was unreachable"
  pass "fm-disk-check: a healthy disk is silent and still sampled"
}

test_low_free_space_reports_once_per_day() {
  local home out
  home=$(make_home low)
  out=$(run_check "$home" "$T0" FM_TEST_FREE_KB="$(kb 299)")
  assert_contains "$out" "disk: free space below 300 GB" "free space under 300 GB wakes"
  assert_contains "$out" "free 299.0 GB" "the line names the free space"
  out=$(run_check "$home" $((T0 + 300)) FM_TEST_FREE_KB="$(kb 298)")
  assert_equals "" "$out" "an unchanged episode is reported once"
  out=$(run_check "$home" $((T0 + DAY)) FM_TEST_FREE_KB="$(kb 298)")
  assert_contains "$out" "free space below 300 GB" "a day-old unchanged episode is reported again"
  out=$(run_check "$home" $((T0 + DAY + 300)))
  assert_equals "" "$out" "a clear run is silent"
  out=$(run_check "$home" $((T0 + DAY + 600)) FM_TEST_FREE_KB="$(kb 299)")
  assert_contains "$out" "free space below 300 GB" "a new episode after a clear run wakes at once"
  pass "fm-disk-check: low free space reports once, then daily"
}

test_free_space_drop_over_a_day_wakes() {
  local home out
  home=$(make_home drop)
  run_check "$home" "$T0" FM_TEST_FREE_KB="$(kb 900)" >/dev/null
  out=$(run_check "$home" $((T0 + DAY - 60)) FM_TEST_FREE_KB="$(kb 800)")
  assert_equals "" "$out" "a drop with no sample 24 hours old yet stays silent"
  out=$(run_check "$home" $((T0 + DAY)) FM_TEST_FREE_KB="$(kb 871)")
  assert_equals "" "$out" "a 29 GB drop in 24 hours stays silent"
  out=$(run_check "$home" $((T0 + DAY + 60)) FM_TEST_FREE_KB="$(kb 868)")
  assert_contains "$out" "free space fell 32.0 GB in 24 hours" "a 32 GB drop in 24 hours wakes"
  pass "fm-disk-check: a fast fall in free space wakes"
}

test_dangling_docker_volumes_wake() {
  local home out
  home=$(make_home dangling)
  out=$(run_check "$home" "$T0" FM_TEST_DANGLING=50)
  assert_equals "" "$out" "50 small dangling volumes stay silent"
  out=$(run_check "$home" $((T0 + 300)) FM_TEST_DANGLING=51)
  assert_contains "$out" "dangling Docker volumes over 50 or 5 GB" "51 dangling volumes wake"
  assert_contains "$out" "51 dangling Docker volumes (0.1 GB)" "the line names the count and size"
  home=$(make_home dangling-size)
  out=$(run_check "$home" "$T0" FM_TEST_DANGLING=2 FM_TEST_VOLUME_SIZE=2.6GB)
  assert_contains "$out" "2 dangling Docker volumes (5.2 GB)" "dangling volumes over 5 GB wake"
  pass "fm-disk-check: dangling Docker volumes over the count or size wake"
}

test_treehouse_growth_over_a_week_wakes() {
  local home out
  home=$(make_home growth)
  run_check "$home" "$T0" >/dev/null
  printf '%s\n' "$(kb 39)" > "$home/h/.treehouse/pool/1/.fake-kb"
  mkdir -p "$home/h/.treehouse/other/1"
  printf '%s\n' "$(kb 2)" > "$home/h/.treehouse/other/1/.fake-kb"
  out=$(run_check "$home" $((T0 + 7 * DAY - 60)))
  assert_equals "" "$out" "growth with no sample a week old yet stays silent"
  out=$(run_check "$home" $((T0 + 7 * DAY)))
  assert_contains "$out" "$TH grew 31.0 GB in 7 days" "31 GB of growth in a week wakes"
  assert_contains "$out" "$TH 46.0 GB" "the line names the summed size"
  pass "fm-disk-check: ~/.treehouse growth over a week wakes"
}

test_config_thresholds_apply_and_bad_config_is_reported() {
  local home out
  home=$(make_home config)
  printf '# tighter\nFREE_MIN_GB=600\nDANGLING_MAX_COUNT=0\n' > "$home/config/disk-watch"
  out=$(run_check "$home" "$T0" FM_TEST_DANGLING=1)
  assert_contains "$out" "free space below 600 GB" "FREE_MIN_GB comes from config/disk-watch"
  assert_contains "$out" "dangling Docker volumes over 0 or 5 GB" "DANGLING_MAX_COUNT comes from config/disk-watch"
  printf 'FREE_MIN_GB=lots\n' > "$home/config/disk-watch"
  out=$(run_check "$home" $((T0 + 300)))
  assert_contains "$out" "disk: check failed: FREE_MIN_GB must be a whole number" "a malformed value is reported"
  out=$(run_check "$home" $((T0 + 600)))
  assert_equals "" "$out" "an unchanged config problem is reported once"
  printf 'SOMETHING=1\n' > "$home/config/disk-watch"
  out=$(FM_HOME="$home" "$CHECK" arm 2>&1) && fail "arm must refuse an invalid config"
  assert_contains "$out" "unknown key" "arm names the config problem"
  pass "fm-disk-check: config thresholds apply and a bad config is reported"
}

test_unreadable_df_is_reported() {
  local home out
  home=$(make_home df)
  out=$(run_check "$home" "$T0" FM_TEST_DF_FAIL=1)
  assert_contains "$out" "disk: cannot read free space with df" "a blind free-space reading wakes"
  pass "fm-disk-check: an unreadable df is reported"
}

test_unmeasurable_treehouse_entry_is_reported() {
  local home out
  home=$(make_home slow)
  out=$(run_check "$home" "$T0" FM_CHECK_TIMEOUT=5 FM_TEST_DU_SLEEP=10)
  assert_contains "$out" "cannot measure $home/h/.treehouse/pool/" "an entry du cannot finish in the budget wakes"
  assert_contains "$out" "$TH unknown" "no partial ~/.treehouse total is reported"
  pass "fm-disk-check: an unmeasurable ~/.treehouse entry is reported"
}

test_loose_treehouse_files_are_summed() {
  local home sample
  home=$(make_home loose)
  printf '%s\n' "$(kb 3)" > "$home/h/.treehouse/loose.bin"
  run_check "$home" "$T0" >/dev/null
  sample=$(sed -n 2p "$home/state/.disk-watch-history")
  assert_contains "$sample" " $(($(kb 10) + $(kb 5) + $(kb 3)))" "a loose file directly under ~/.treehouse is in the total"
  pass "fm-disk-check: loose files directly under ~/.treehouse are summed"
}

test_partial_du_total_is_used_and_no_size_is_reported() {
  local home out sample
  home=$(make_home partial)
  out=$(run_check "$home" "$T0" FM_TEST_DU_EXIT=1)
  assert_equals "" "$out" "a du that prints a total but exits 1 stays silent"
  sample=$(sed -n 2p "$home/state/.disk-watch-history")
  assert_contains "$sample" " $(($(kb 10) + $(kb 5)))" "the printed total is used when du exits non-zero"
  home=$(make_home nosize)
  out=$(run_check "$home" "$T0" FM_TEST_DU_NOSIZE=1)
  assert_contains "$out" "cannot measure $home/h/.treehouse/pool/" "an entry du gives no size for wakes"
  assert_contains "$out" "$TH unknown" "no partial ~/.treehouse total is reported"
  pass "fm-disk-check: a failing du uses its printed total or reports the entry"
}

test_check_never_prunes() {
  local home
  home=$(make_home never)
  run_check "$home" "$T0" FM_TEST_DANGLING=4000 FM_TEST_VOLUME_SIZE=100MB FM_TEST_FREE_KB="$(kb 10)" >/dev/null
  assert_grep 'volume ls -q -f dangling=true' "$home/docker.log" "the check asked docker for dangling volumes"
  ! grep -Ew 'prune|rm|remove|kill|stop' "$home/docker.log" >/dev/null || fail "the check only reads from docker"
  assert_present "$home/h/.treehouse/pool/1/.fake-kb" "the check removes nothing under ~/.treehouse"
  pass "fm-disk-check: the check never prunes or removes"
}

test_help_and_usage
test_arm_writes_and_binds_the_check_and_disarm_removes_it
test_healthy_disk_is_silent_and_sampled
test_low_free_space_reports_once_per_day
test_free_space_drop_over_a_day_wakes
test_dangling_docker_volumes_wake
test_treehouse_growth_over_a_week_wakes
test_config_thresholds_apply_and_bad_config_is_reported
test_unreadable_df_is_reported
test_unmeasurable_treehouse_entry_is_reported
test_loose_treehouse_files_are_summed
test_partial_du_total_is_used_and_no_size_is_reported
test_check_never_prunes
