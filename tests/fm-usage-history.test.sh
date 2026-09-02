#!/usr/bin/env bash
# Behavior tests for bin/fm-usage-history.sh: the burn-history object it
# reduces from quota samples and the pipeline's own call record, the way a
# window reset is separated from spend, and the way an unreadable source
# reports its reason instead of vanishing or failing the whole read.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HISTORY_SH="$ROOT/bin/fm-usage-history.sh"
TMP_ROOT=$(fm_test_tmproot fm-usage-history)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

make_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/data"
  fm_fakebin "$home" >/dev/null
  printf '%s\n' "$home"
}

# One quota sample line, with a Claude session percent and a ChatGPT five-hour
# percent, in exactly the two shapes the real readers write.
sample() {  # <ts> <claude-pct|-> <gpt-pct|->
  local ts=$1 claude=$2 gpt=$3
  jq -nc --arg ts "$ts" --arg claude "$claude" --arg gpt "$gpt" '
    {ts: $ts,
     claude: (if $claude == "-" then null else
       {providers: [{provider: "claude",
         windows: [{id: "five_hour", label: "session",
                    percentRemaining: ($claude | tonumber)}]}]} end),
     gpt: (if $gpt == "-" then {status: "auth_required", windows: []} else
       {status: "known",
        windows: [{id: "primary", label: "5 hour",
                   percentRemaining: ($gpt | tonumber)}]} end)}'
}

# A pipeline database with exactly the columns and rows this reduction reads.
make_db() {  # <path> <rows-sql>
  sqlite3 "$1" "
    create table agent_invocations (
      id text primary key, run_id text not null, step_name text not null,
      round integer not null, purpose text not null, agent text not null,
      model text, started_at integer not null, duration_ms integer not null,
      input_tokens integer, output_tokens integer, cache_read_tokens integer);
    $2"
}

run_history() {  # <home> [db]
  local home=$1 db=${2:-$home/absent.sqlite}
  PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FM_USAGE_HISTORY_FILE="$home/data/quota-history.jsonl" \
    FM_USAGE_HISTORY_DB="$db" \
    "$HISTORY_SH"
}

# Build a board from <usage-json> to prove the reduction satisfies the board's
# own payload contract rather than only this test's expectations.
board_accepts() {  # <home> <usage-json>
  local home=$1 data
  fm_fake_exit0 "$home/fakebin" lavish-axi
  data="$home/payload.json"
  jq -n --argjson usage "$2" '{
    schema:"fm-bearings-board.v1", home:"usage-home", generated:"2026-09-02T14:00Z",
    prs_live:false, captains_call:[], underway:[], landed:[], charted:[], usage:$usage}' > "$data"
  PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    "$ROOT/bin/fm-bearings-board.sh" build "$data" >/dev/null
}

test_both_readers_land_in_one_curve_series() {
  local home out
  home=$(make_home both)
  {
    sample 2026-09-02T10:00:00Z 90 80
    sample 2026-09-02T10:30:00Z 70 60
  } > "$home/data/quota-history.jsonl"
  out=$(run_history "$home") || fail "the reduction failed on two good samples"
  printf '%s' "$out" | jq -e '
    .samples == 2 and .since == "2026-09-02T10:00:00Z"
    and (.curves | length) == 2
    and ([.curves[].pool] | sort) == ["claude", "openai-codex"]
    and (.curves | map(select(.pool == "claude")) | first
         | .label == "Claude session" and (.points | length) == 2
           and .points[1].percent_remaining == 70)
  ' >/dev/null || fail "the two reader shapes did not reduce to one series: $out"
  pass "both quota readers reduce onto one curve series"
}

test_a_window_reset_is_a_reset_and_never_negative_burn() {
  local home out
  home=$(make_home reset)
  {
    sample 2026-09-02T10:00:00Z - 80
    sample 2026-09-02T11:00:00Z - 20
    sample 2026-09-02T12:00:00Z - 100
    sample 2026-09-02T13:00:00Z - 95
  } > "$home/data/quota-history.jsonl"
  out=$(run_history "$home") || fail "the reduction failed across a reset"
  # 80->20 is 60 points spent, 20->100 is the reset, 100->95 is 5 more.
  printf '%s' "$out" | jq -e '
    (.curves | first | .resets) == ["2026-09-02T12:00:00Z"]
    and (.daily | length) == 1
    and (.daily | first | .burn_points == 65 and .resets == 1)
  ' >/dev/null || fail "a reset was not separated from spend: $out"
  pass "a refilled window counts as a reset, never as negative burn"
}

test_burn_is_attributed_per_day_per_window() {
  local home out
  home=$(make_home perday)
  {
    sample 2026-09-01T10:00:00Z 90 -
    sample 2026-09-01T20:00:00Z 60 -
    sample 2026-09-02T10:00:00Z 50 -
  } > "$home/data/quota-history.jsonl"
  out=$(run_history "$home") || fail "the reduction failed across two days"
  printf '%s' "$out" | jq -e '
    (.daily | length) == 2
    and (.daily | map(select(.date == "2026-09-01")) | first | .burn_points) == 30
    and (.daily | map(select(.date == "2026-09-02")) | first | .burn_points) == 10
    and ([.daily[].label] | unique) == ["Claude session"]
  ' >/dev/null || fail "burn was not split per day: $out"
  pass "burn is attributed per day per window"
}

test_review_spend_is_attributed_to_the_pool_its_model_spends_from() {
  local home out db
  command -v sqlite3 >/dev/null 2>&1 || { echo "skip: sqlite3 not found"; return; }
  home=$(make_home spend)
  db="$home/state.sqlite"
  sample 2026-09-02T10:00:00Z 90 80 > "$home/data/quota-history.jsonl"
  make_db "$db" "
    insert into agent_invocations values
      ('a','R1','review',1,'review','pi','gpt-5.6-sol',1788350000,1000,100,10,1000),
      ('b','R1','review',2,'review-fix','pi','gpt-5.6-sol',1788351000,1000,50,5,500),
      ('c','R2','review',1,'review','claude','claude-opus-5',1788352000,1000,7,1,70),
      ('d','R2','test',1,'test','claude','claude-opus-5',1788353000,1000,999,999,999);"
  out=$(run_history "$home" "$db") || fail "the reduction failed on a good database"
  printf '%s' "$out" | jq -e '
    .review.available == true
    and (.review.daily | map(select(.model == "gpt-5.6-sol")) | first
         | .pool == "openai-codex" and .calls == 2 and .runs == 1
           and .fresh_input == 150 and .output == 15 and .cache_read == 1500)
    and (.review.daily | map(select(.model == "claude-opus-5")) | first
         | .pool == "claude" and .fresh_input == 7)
    and (.review.runs | map(select(.run_id == "R1")) | first | .rounds) == 2
  ' >/dev/null || fail "review spend was not attributed per model and pool: $out"
  pass "review spend is attributed per model, per pool, per run, review steps only"
}

test_a_call_that_spent_nothing_is_left_out_of_the_spend_lists() {
  local home out db
  command -v sqlite3 >/dev/null 2>&1 || { echo "skip: sqlite3 not found"; return; }
  home=$(make_home zero)
  db="$home/state.sqlite"
  : > "$home/data/quota-history.jsonl"
  make_db "$db" "
    insert into agent_invocations values
      ('a','R1','review',1,'review','pi',NULL,1788350000,1000,0,0,0),
      ('b','R2','review',1,'review','claude','claude-opus-5',1788351000,1000,5,1,9),
      ('c','R2','review',2,'review','claude','claude-opus-5',1788352000,1000,0,0,0);"
  out=$(run_history "$home" "$db") || fail "the reduction failed on a zero-token row"
  printf '%s' "$out" | jq -e '
    ([.review.runs[].run_id] == ["R2"])
    and ([.review.daily[].model] == ["claude-opus-5"])
    and (.review.runs | map(select(.run_id == "R2")) | first
         | .calls == 1 and .rounds == 1)
    and (.review.daily | map(select(.model == "claude-opus-5")) | first
         | .calls == 1)
  ' >/dev/null || fail "a call that spent nothing still crowded the lists: $out"
  pass "a review call that recorded no tokens stays out of the spend lists, even sharing a model and run with a real call"
}

test_an_absent_history_file_reports_its_reason_instead_of_failing() {
  local home out
  home=$(make_home nohistory)
  out=$(run_history "$home") || fail "an absent history file should not be fatal"
  printf '%s' "$out" | jq -e '
    .samples == 0 and .since == null and .curves == [] and .daily == []
    and (.notes | length) >= 1 and (.notes | join(" ") | test("quota samples"))
  ' >/dev/null || fail "an absent history file did not report its reason: $out"
  board_accepts "$home" "$out" \
    || fail "the board rejected a payload built from an empty reduction"
  pass "an absent quota history reports its reason and still builds a board"
}

test_an_absent_pipeline_database_reports_its_reason_instead_of_failing() {
  local home out
  home=$(make_home nodb)
  sample 2026-09-02T10:00:00Z 90 80 > "$home/data/quota-history.jsonl"
  out=$(run_history "$home" "$home/nowhere.sqlite") \
    || fail "an absent pipeline database should not be fatal"
  printf '%s' "$out" | jq -e '
    .review.available == false and (.review.note | length) > 0
    and .review.daily == [] and .review.runs == []
    and (.notes | join(" ") | test("pipeline database"))
    and (.curves | length) == 2
  ' >/dev/null || fail "an absent database did not report its reason: $out"
  pass "an absent pipeline database reports its reason and keeps the curves"
}

test_a_corrupt_sample_line_does_not_lose_the_good_ones() {
  local home out
  home=$(make_home corrupt)
  {
    sample 2026-09-02T10:00:00Z 90 80
    printf '{"ts":"2026-09-02T10:30:00Z","claude":\n'
  } > "$home/data/quota-history.jsonl"
  out=$(run_history "$home") || fail "a half-written line should not be fatal"
  printf '%s' "$out" | jq -e '
    .samples == 1 and (.curves | length) == 2
  ' >/dev/null || fail "a half-written line lost the good samples: $out"
  pass "a half-written final sample is dropped without losing earlier samples"
}

test_the_output_satisfies_the_board_payload_contract() {
  local home out db
  command -v sqlite3 >/dev/null 2>&1 || { echo "skip: sqlite3 not found"; return; }
  home=$(make_home contract)
  db="$home/state.sqlite"
  {
    sample 2026-09-02T10:00:00Z 90 80
    sample 2026-09-02T11:00:00Z 70 95
  } > "$home/data/quota-history.jsonl"
  make_db "$db" "
    insert into agent_invocations values
      ('a','R1','review',1,'review','pi','gpt-5.6-sol',1788350000,1000,100,10,1000);"
  out=$(run_history "$home" "$db") || fail "the reduction failed"
  board_accepts "$home" "$out" \
    || fail "the board refused a payload built from this reduction's own output"
  pass "the reduction's output is accepted by the board payload contract"
}

test_the_pipeline_database_is_never_written_to() {
  local home db before after
  command -v sqlite3 >/dev/null 2>&1 || { echo "skip: sqlite3 not found"; return; }
  home=$(make_home readonly)
  db="$home/state.sqlite"
  : > "$home/data/quota-history.jsonl"
  make_db "$db" "
    insert into agent_invocations values
      ('a','R1','review',1,'review','pi','gpt-5.6-sol',1788350000,1000,100,10,1000);"
  before=$(cksum < "$db")
  run_history "$home" "$db" >/dev/null || fail "the reduction failed"
  after=$(cksum < "$db")
  [ "$before" = "$after" ] || fail "the pipeline database changed: $before -> $after"
  pass "reading the pipeline spend leaves its database byte-identical"
}

test_both_readers_land_in_one_curve_series
test_a_window_reset_is_a_reset_and_never_negative_burn
test_burn_is_attributed_per_day_per_window
test_review_spend_is_attributed_to_the_pool_its_model_spends_from
test_a_call_that_spent_nothing_is_left_out_of_the_spend_lists
test_an_absent_history_file_reports_its_reason_instead_of_failing
test_an_absent_pipeline_database_reports_its_reason_instead_of_failing
test_a_corrupt_sample_line_does_not_lose_the_good_ones
test_the_output_satisfies_the_board_payload_contract
test_the_pipeline_database_is_never_written_to
