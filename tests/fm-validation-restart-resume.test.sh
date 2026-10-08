#!/usr/bin/env bash
# tests/fm-validation-restart-resume.test.sh - automatic recovery of validation
# runs ended by a shared no-mistakes daemon restart.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RESUME="$ROOT/bin/fm-validation-restart-resume.sh"
TMP_ROOT=$(fm_test_tmproot fm-validation-restart-resume-tests)
FM_TEST_CLEANUP_DIRS+=("$TMP_ROOT")
trap fm_test_cleanup EXIT
fm_git_identity fmtest fmtest@example.invalid

new_case() {  # <name>
  local name=$1 dir wt
  dir="$TMP_ROOT/$name"
  wt="$dir/wt"
  mkdir -p "$dir/home/state" "$dir/home/config" "$dir/home/data" "$dir/fakebin" "$wt"
  git init -q -b fm/restart-task "$wt"
  printf 'fixture\n' > "$wt/file.txt"
  git -C "$wt" add file.txt
  git -C "$wt" commit -q -m fixture
  cat > "$dir/home/state/restart-task.meta" <<EOF
window=fixture:restart-task
worktree=$wt
kind=ship
mode=no-mistakes
harness=pi
spawn_gen=generation-one
EOF
  cat > "$dir/fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
if [ "${1:-} ${2:-}" = 'axi status' ]; then
  cat "$FM_FAKE_NM_STATUS_FILE"
  exit 0
fi
exit 1
SH
  cat > "$dir/fakebin/endpoint-state" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${FM_FAKE_ENDPOINT_STATE:-alive}"
SH
  cat > "$dir/fakebin/fm-send" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "$FM_FAKE_SEND_LOG"
SH
  chmod +x "$dir/fakebin/no-mistakes" "$dir/fakebin/endpoint-state" "$dir/fakebin/fm-send"
  : > "$dir/send.log"
  printf '%s\n' "$dir"
}

write_restart_status() {  # <path> [run-id]
  local path=$1 run_id=${2:-01RESTARTEDRUN0000000000000} wt head
  wt="${path%/status.toon}/wt"
  head=$(git -C "$wt" rev-parse HEAD)
  cat > "$path" <<EOF
run:
  id: "$run_id"
  branch: fm/restart-task
  status: failed
  head: ${head:0:8}
  head_sha: $head
  steps[2]{step,status,findings,duration_ms}:
    review,completed,0,100
    test,failed,0,200
outcome: failed
error: "daemon shutting down"
EOF
}

run_resume() {  # <case-dir>
  local dir=$1
  FM_HOME="$dir/home" \
  FM_STATE_OVERRIDE="$dir/home/state" \
  FM_VALIDATION_RESTART_SEND_BIN="$dir/fakebin/fm-send" \
  FM_VALIDATION_RESTART_ENDPOINT_STATE_BIN="$dir/fakebin/endpoint-state" \
  FM_FAKE_SEND_LOG="$dir/send.log" \
  FM_FAKE_NM_STATUS_FILE="$dir/status.toon" \
  PATH="$dir/fakebin:${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}" \
    "$RESUME"
}

assert_send_count() {  # <expected> <log> <message>
  local expected=$1 log=$2 message=$3 count
  count=$(grep -c '^restart-task$' "$log" 2>/dev/null || true)
  [ "$count" -eq "$expected" ] || fail "$message (expected $expected, got $count)"
}

test_restart_signature_is_detected() {
  local dir out
  dir=$(new_case signature)
  write_restart_status "$dir/status.toon"

  out=$(run_resume "$dir")

  [ "$out" = restart-task ] || fail "restart signature did not report the resumed task: '$out'"
  assert_send_count 1 "$dir/send.log" "restart signature did not steer exactly once"
  pass "daemon-restart signature is detected for a live no-mistakes worker"
}

test_ordinary_park_is_not_detected() {
  local dir out
  dir=$(new_case parked)
  cat > "$dir/status.toon" <<'EOF'
run:
  id: "01PARKEDRUN000000000000000"
  branch: fm/restart-task
  status: running
  head: deadbee
  findings: "1 ask-user"
  gate:
    step: review
    status: awaiting_approval
outcome:
EOF

  out=$(run_resume "$dir")

  [ -z "$out" ] || fail "ordinary review park was reported as resumed: '$out'"
  assert_send_count 0 "$dir/send.log" "ordinary review park was steered"
  pass "ordinary review-fix park is not a daemon-restart signature"
}

test_worker_failure_is_not_detected() {
  local dir out
  dir=$(new_case worker-failure)
  cat > "$dir/status.toon" <<'EOF'
run:
  id: "01WORKERFAIL000000000000000"
  branch: fm/restart-task
  status: failed
  head: deadbee
outcome: failed
error: "step review failed: agent review: pi exited: exit status 1"
EOF

  out=$(run_resume "$dir")

  [ -z "$out" ] || fail "worker-side failure was reported as resumed: '$out'"
  assert_send_count 0 "$dir/send.log" "worker-side failure was steered"
  pass "worker-side validation failure is not a daemon-restart signature"
}

test_repeat_scan_is_idempotent() {
  local dir first second
  dir=$(new_case idempotent)
  write_restart_status "$dir/status.toon" 01SAMEEPISODE00000000000000

  first=$(run_resume "$dir")
  second=$(run_resume "$dir")

  [ "$first" = restart-task ] || fail "first scan did not resume the task"
  [ -z "$second" ] || fail "repeat scan reported the same episode again: '$second'"
  assert_send_count 1 "$dir/send.log" "repeat scan sent a duplicate steer"
  pass "repeat scan sends no second steer for the same restart episode"
}

test_steer_text_names_recovery_action() {
  local dir expected
  dir=$(new_case steer-text)
  write_restart_status "$dir/status.toon" 01STEERTEXTRUN0000000000000

  run_resume "$dir" >/dev/null

  expected='The validation daemon restarted and ended no-mistakes run 01STEERTEXTRUN0000000000000 with "daemon shutting down". Resume validation now by invoking /no-mistakes again, then follow the current axi gate help until the PR is ready. This restart is not a code failure.'
  grep -Fx "$expected" "$dir/send.log" >/dev/null \
    || fail "automatic steer did not carry the required recovery text"
  pass "automatic steer tells the worker to resume through current gate help"
}

write_restart_status_with_pr() {  # <path> <run-id> <test-step-status> <ci-step-line>
  local path=$1 run_id=$2 test_status=$3 ci_line=$4
  write_restart_status "$path" "$run_id"
  awk -v test_status="$test_status" -v ci_line="$ci_line" '
    { print }
    /^  branch: fm\/restart-task$/ { print "  pr: \"https://github.com/o/r/pull/2\"" }
  ' "$path" | awk -v test_status="$test_status" -v ci_line="$ci_line" '
    /^    test,failed,0,200$/ { print "    test," test_status ",0,200"; if (ci_line != "") print "    " ci_line; next }
    { print }
  ' > "$path.new"
  mv "$path.new" "$path"
}

test_delivered_pr_with_orphaned_ci_is_not_steered() {
  local dir out
  dir=$(new_case delivered-ci)
  write_restart_status_with_pr "$dir/status.toon" 01DELIVEREDCI00000000000000 completed 'ci,failed,0,300'

  out=$(run_resume "$dir")

  [ -z "$out" ] || fail "delivered PR with an orphaned ci monitor was reported as resumed: '$out'"
  assert_send_count 0 "$dir/send.log" "delivered PR was steered into a new pipeline"
  pass "delivered PR whose only failed step is ci is left to merge monitoring"
}

test_pr_with_failed_earlier_step_is_still_steered() {
  local dir out
  dir=$(new_case pr-earlier-step)
  write_restart_status_with_pr "$dir/status.toon" 01PRTESTFAILED0000000000000 failed ''

  out=$(run_resume "$dir")

  [ "$out" = restart-task ] || fail "run with a PR but a failed earlier step was not resumed: '$out'"
  assert_send_count 1 "$dir/send.log" "run with a PR but a failed earlier step was not steered"
  pass "a PR alone does not stop the steer when an earlier step failed"
}

test_restart_signature_is_detected
test_delivered_pr_with_orphaned_ci_is_not_steered
test_pr_with_failed_earlier_step_is_still_steered
test_ordinary_park_is_not_detected
test_worker_failure_is_not_detected
test_repeat_scan_is_idempotent
test_steer_text_names_recovery_action

echo "# fm-validation-restart-resume.test.sh: all assertions passed"
