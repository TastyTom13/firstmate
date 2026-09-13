#!/usr/bin/env bash
# Behavior tests for the context-budget estimator and its once-per-step nudge.
#
# Two layers:
#   ESTIMATOR - bin/fm-context-budget.sh reading a synthetic Claude transcript:
#               the usage-record path, the byte fallback, the verdict bands, and
#               the once-per-20-percent-step throttle with its session reset and
#               post-compaction step-down.
#   HOOK      - bin/fm-turnend-guard.sh printing that line exactly once from its
#               idle allow path, and staying silent whenever the moment is not a
#               low-disruption one (docs/configuration.md "Context budget nudge").
# All hermetic over temp dirs; no real agent session is invoked.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BUDGET="$ROOT/bin/fm-context-budget.sh"
TMP_ROOT=$(fm_test_tmproot fm-context-budget)
fm_git_identity fmtest fmtest@example.invalid

# A transcript whose newest usage record carries exactly <tokens> of context.
# The older record deliberately carries a different total so a test that reads
# the wrong record cannot accidentally agree with the right one.
write_transcript() {  # <path> <tokens>
  local path=$1 tokens=$2
  mkdir -p "$(dirname "$path")"
  {
    printf '{"type":"user","message":{"role":"user","content":"hello"}}\n'
    printf '{"type":"assistant","message":{"usage":{"input_tokens":7,"cache_read_input_tokens":11,"cache_creation_input_tokens":0,"output_tokens":0}}}\n'
    printf 'not json at all\n'
    printf '{"type":"assistant","message":{"usage":{"input_tokens":1,"cache_read_input_tokens":%s,"cache_creation_input_tokens":0,"output_tokens":0}}}\n' \
      "$((tokens - 1))"
  } > "$path"
}

make_state() {  # <name>
  local state="$TMP_ROOT/$1/state"
  mkdir -p "$state"
  printf '%s\n' "$state"
}

# --- ESTIMATOR ---------------------------------------------------------------

test_percent_comes_from_the_newest_usage_record() {
  local t percent
  t="$TMP_ROOT/usage/transcript.jsonl"
  write_transcript "$t" 50000
  percent=$("$BUDGET" --transcript "$t" --window 200000 --percent) \
    || fail "estimator exited non-zero on a readable transcript"
  [ "$percent" = 25 ] || fail "expected 25 percent of a 200000 window, got $percent"
  pass "estimator: percentage comes from the newest usage record, not the first"
}

test_verdict_bands() {
  local t line
  t="$TMP_ROOT/bands/transcript.jsonl"

  write_transcript "$t" 78000   # 39 percent
  line=$("$BUDGET" --transcript "$t" --window 200000)
  assert_contains "$line" "39%" "39 percent line lost its percentage"
  assert_contains "$line" "quiet" "under 40 percent must read quiet"

  write_transcript "$t" 80000   # 40 percent
  line=$("$BUDGET" --transcript "$t" --window 200000)
  assert_contains "$line" "suggest /stow at the next quiet moment" \
    "40 percent must suggest /stow at the next quiet moment"

  write_transcript "$t" 120000  # 60 percent
  line=$("$BUDGET" --transcript "$t" --window 200000)
  assert_contains "$line" "suggest /stow at the next quiet moment" \
    "60 percent is still the next-quiet-moment band"

  write_transcript "$t" 122000  # 61 percent
  line=$("$BUDGET" --transcript "$t" --window 200000)
  assert_contains "$line" "suggest /stow now" "over 60 percent must suggest /stow now"

  pass "estimator: verdict bands are quiet under 40, next quiet moment to 60, now above 60"
}

test_byte_fallback_when_no_usage_record() {
  local t percent expected bytes
  t="$TMP_ROOT/fallback/transcript.jsonl"
  mkdir -p "$(dirname "$t")"
  : > "$t"
  # 40000 bytes with no usage record anywhere: bytes / 4 is the coarse estimate.
  head -c 40000 /dev/zero | tr '\0' 'x' > "$t"
  bytes=$(wc -c < "$t" | tr -d ' ')
  expected=$(( (bytes / 4) * 100 / 20000 ))
  percent=$("$BUDGET" --transcript "$t" --window 20000 --percent) \
    || fail "byte fallback exited non-zero"
  [ "$percent" = "$expected" ] || fail "byte fallback expected $expected percent, got $percent"
  pass "estimator: falls back to transcript bytes / 4 when no usage record is readable"
}

test_missing_transcript_is_silent() {
  local out status
  status=0
  out=$("$BUDGET" --transcript "$TMP_ROOT/absent/none.jsonl" 2>&1) || status=$?
  expect_code 1 "$status" "an unreadable transcript"
  [ -z "$out" ] || fail "an unreadable transcript must print nothing, got: $out"
  pass "estimator: an unreadable transcript prints nothing and exits 1"
}

# --- THROTTLE ----------------------------------------------------------------

nudge() {  # <state> <transcript> <session>
  FM_STATE_OVERRIDE="$1" "$BUDGET" --nudge --transcript "$2" --session "$3" --window 200000
}

test_nudge_is_quiet_below_forty_percent() {
  local state t out status
  state=$(make_state throttle-quiet)
  t="$TMP_ROOT/throttle-quiet/transcript.jsonl"
  write_transcript "$t" 78000
  status=0
  out=$(nudge "$state" "$t" s1) || status=$?
  expect_code 1 "$status" "a 39 percent session"
  [ -z "$out" ] || fail "under 40 percent must print nothing, got: $out"
  assert_absent "$state/.context-budget-nudged" "a quiet session must not record a step"
  pass "nudge: silent below 40 percent and records nothing"
}

test_nudge_announces_each_step_once() {
  local state t out status
  state=$(make_state throttle-steps)
  t="$TMP_ROOT/throttle-steps/transcript.jsonl"

  write_transcript "$t" 88000   # 44 percent, step 2
  out=$(nudge "$state" "$t" s1) || fail "the first crossing of step 2 must announce"
  assert_contains "$out" "suggest /stow at the next quiet moment" "step 2 line lost its verdict"

  write_transcript "$t" 100000  # 50 percent, still step 2
  status=0
  out=$(nudge "$state" "$t" s1) || status=$?
  expect_code 1 "$status" "a second turn inside the same step"
  [ -z "$out" ] || fail "the same step must announce at most once, got: $out"

  write_transcript "$t" 130000  # 65 percent, step 3
  out=$(nudge "$state" "$t" s1) || fail "crossing into step 3 must announce again"
  assert_contains "$out" "suggest /stow now" "step 3 line lost its verdict"

  pass "nudge: announces at most once per 20 percent step and again on the next step"
}

test_nudge_resets_for_a_new_session() {
  local state t out
  state=$(make_state throttle-session)
  t="$TMP_ROOT/throttle-session/transcript.jsonl"
  write_transcript "$t" 88000
  out=$(nudge "$state" "$t" s1) || fail "the first session must announce"
  [ -n "$out" ] || fail "the first session announced an empty line"
  out=$(nudge "$state" "$t" s2) || fail "a different session id must announce again"
  assert_contains "$out" "suggest /stow" "the new session's line lost its verdict"
  pass "nudge: a different session id starts its own step count"
}

test_nudge_steps_down_after_compaction() {
  local state t out status
  state=$(make_state throttle-compact)
  t="$TMP_ROOT/throttle-compact/transcript.jsonl"

  write_transcript "$t" 130000  # 65 percent, step 3
  nudge "$state" "$t" s1 >/dev/null || fail "step 3 must announce"

  write_transcript "$t" 40000   # 20 percent after compaction, step 1
  status=0
  out=$(nudge "$state" "$t" s1) || status=$?
  expect_code 1 "$status" "the turn right after compaction"
  [ -z "$out" ] || fail "a shrunken context must stay silent, got: $out"
  assert_exact_line "$state/.context-budget-nudged" "s1 1" \
    "compaction must rewrite the recorded step down"

  write_transcript "$t" 88000   # 44 percent again, step 2
  out=$(nudge "$state" "$t" s1) || fail "step 2 must announce again after a compaction reset"
  assert_contains "$out" "suggest /stow" "the post-compaction line lost its verdict"

  pass "nudge: compaction steps the record down and the next real crossing announces again"
}

# --- HOOK --------------------------------------------------------------------

install_guard_scripts() {
  local dir=$1 f
  mkdir -p "$dir/bin" "$dir/state"
  for f in fm-turnend-guard.sh fm-context-budget.sh fm-primary-scope-lib.sh \
           fm-supervision-lib.sh fm-wake-lib.sh fm-hook-host-lib.sh; do
    cp "$ROOT/bin/$f" "$dir/bin/$f"
  done
  chmod +x "$dir/bin/fm-turnend-guard.sh" "$dir/bin/fm-context-budget.sh"
}

make_primary_dir() {  # <dir> <transcript-tokens>
  local dir=$1 tokens=$2
  mkdir -p "$dir"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  install_guard_scripts "$dir"
  write_transcript "$dir/transcript.jsonl" "$tokens"
  printf '%s\n' "$dir"
}

run_claude_stop() {  # <dir>
  local dir=$1 home
  home=$(cd "$dir" && pwd)
  printf '{"stop_hook_active":false,"session_id":"hook-s1","transcript_path":"%s/transcript.jsonl"}' "$home" \
    | CLAUDECODE=1 FM_HOME="$home" FM_CONTEXT_WINDOW=200000 \
      bash "$dir/bin/fm-turnend-guard.sh" --claude 2>&1
}

run_default_stop() {  # <dir>
  local dir=$1 home
  home=$(cd "$dir" && pwd)
  printf '{"stop_hook_active":false,"session_id":"hook-s1","transcript_path":"%s/transcript.jsonl"}' "$home" \
    | CLAUDECODE=1 FM_HOME="$home" FM_CONTEXT_WINDOW=200000 \
      bash "$dir/bin/fm-turnend-guard.sh" 2>&1
}

test_hook_prints_the_suggestion_once_on_an_idle_turn_end() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/hook-idle" 130000)

  status=0
  out=$(run_claude_stop "$dir") || status=$?
  expect_code 2 "$status" "an idle Claude turn end above the nudge threshold"
  assert_contains "$out" "suggest /stow now" "the turn-end nudge lost its verdict"

  status=0
  out=$(run_claude_stop "$dir") || status=$?
  expect_code 0 "$status" "the next idle Claude turn end inside the same step"
  [ -z "$out" ] || fail "the guard must nudge at most once per step, got: $out"

  pass "hook: an idle Claude turn end prints the suggestion once per step"
}

test_hook_is_silent_below_the_threshold() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/hook-below" 40000)
  status=0
  out=$(run_claude_stop "$dir") || status=$?
  expect_code 0 "$status" "an idle Claude turn end at 20 percent"
  [ -z "$out" ] || fail "a 20 percent session must end its turn silently, got: $out"
  pass "hook: no suggestion below 40 percent of the context window"
}

test_hook_stays_silent_when_the_moment_is_not_quiet() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/hook-busy" 130000)

  printf '1\t1\tcheck\tk\tpayload\n' > "$dir/state/.wake-queue"
  status=0
  out=$(run_claude_stop "$dir") || status=$?
  expect_code 0 "$status" "a turn end with a wake in hand"
  [ -z "$out" ] || fail "a queued wake must suppress the nudge, got: $out"
  rm -f "$dir/state/.wake-queue"

  printf 'working: on it\n' > "$dir/state/task1.status"
  status=0
  out=$(run_claude_stop "$dir") || status=$?
  expect_code 0 "$status" "a turn end with a live task record"
  [ -z "$out" ] || fail "a task status record must suppress the nudge, got: $out"
  rm -f "$dir/state/task1.status"

  mkdir -p "$dir/state/inbox"
  printf 'captain note\n' > "$dir/state/inbox/n1.note"
  status=0
  out=$(run_claude_stop "$dir") || status=$?
  expect_code 0 "$status" "a turn end with a captain note still waiting"
  [ -z "$out" ] || fail "an unhandled captain note must suppress the nudge, got: $out"
  rm -rf "$dir/state/inbox"

  : > "$dir/state/.afk"
  status=0
  out=$(run_claude_stop "$dir") || status=$?
  expect_code 0 "$status" "a turn end while away mode is on"
  [ -z "$out" ] || fail "away mode must suppress the nudge, got: $out"
  rm -f "$dir/state/.afk"

  status=0
  out=$(run_claude_stop "$dir") || status=$?
  expect_code 2 "$status" "the first genuinely quiet turn end afterwards"
  assert_contains "$out" "suggest /stow" "the deferred nudge lost its verdict"

  pass "hook: the nudge waits for a low-disruption moment and then lands"
}

test_hook_nudges_only_in_claude_mode() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/hook-other-harness" 130000)
  status=0
  out=$(run_default_stop "$dir") || status=$?
  expect_code 0 "$status" "an idle turn end on a non-Claude harness"
  [ -z "$out" ] || fail "only the Claude Stop hook prints the nudge, got: $out"
  assert_absent "$dir/state/.context-budget-nudged" \
    "a non-Claude turn end must not consume a step"
  pass "hook: only the Claude Stop path prints the suggestion"
}

test_percent_comes_from_the_newest_usage_record
test_verdict_bands
test_byte_fallback_when_no_usage_record
test_missing_transcript_is_silent
test_nudge_is_quiet_below_forty_percent
test_nudge_announces_each_step_once
test_nudge_resets_for_a_new_session
test_nudge_steps_down_after_compaction
test_hook_prints_the_suggestion_once_on_an_idle_turn_end
test_hook_is_silent_below_the_threshold
test_hook_stays_silent_when_the_moment_is_not_quiet
test_hook_nudges_only_in_claude_mode
