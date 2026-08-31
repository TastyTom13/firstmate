#!/usr/bin/env bash
# Behavior tests for bin/fm-quota-pools.sh: the board-shaped pool array it
# builds from two unrelated readers, and the way an unreadable pool stays in
# the array with its reason instead of vanishing or being guessed.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

POOLS="$ROOT/bin/fm-quota-pools.sh"
TMP_ROOT=$(fm_test_tmproot fm-quota-pools)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

QUOTA_AXI_JSON='{"schemaVersion":5,"providers":[{"provider":"claude",
  "windows":[{"id":"five_hour","label":"session","resetsAt":"2026-09-01T02:19:59Z"},
             {"id":"seven_day","label":"week","resetsAt":"2026-09-07T03:59:59Z"}],
  "quotaSemantics":{"status":"known","effectiveAvailability":[
    {"scope":"all_models","status":"known","effectivePercentRemaining":70.6,
     "limitingWindowIds":["seven_day"],"runway":{"status":"through_reset"}}]}}]}'

GPT_JSON='{"schema":"fm-gpt-quota.v1","provider":"openai-codex","status":"known",
  "source":"response_headers","estimate":false,
  "windows":[{"id":"primary","label":"30 day","percentRemaining":94,
              "resetsAt":"2026-09-30T21:37:52Z"}],
  "limiting":{"id":"primary","label":"30 day","percentRemaining":94,
              "resetsAt":"2026-09-30T21:37:52Z"}}'

make_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home"
  fm_fakebin "$home" >/dev/null
  printf '%s\n' "$home"
}

# Install a fake quota-axi that prints <json> for --json, or omit it entirely.
fake_quota_axi() {  # <home> <json|->
  if [ "$2" = "-" ]; then
    rm -f "$1/fakebin/quota-axi"
    return
  fi
  printf '%s' "$2" > "$1/quota-axi.json"
  cat > "$1/fakebin/quota-axi" <<'SH'
#!/usr/bin/env bash
[ -s "$FAKE_QUOTA_AXI_JSON" ] || exit 1
cat "$FAKE_QUOTA_AXI_JSON"
SH
  chmod +x "$1/fakebin/quota-axi"
}

fake_gpt_reader() {  # <home> <json>
  printf '%s' "$2" > "$1/gpt.json"
  cat > "$1/gpt-reader.sh" <<'SH'
#!/usr/bin/env bash
cat "$FAKE_GPT_JSON"
SH
  chmod +x "$1/gpt-reader.sh"
}

run_pools() {  # <home>
  PATH="$1/fakebin:$PATH" \
    FAKE_QUOTA_AXI_JSON="$1/quota-axi.json" \
    FAKE_GPT_JSON="$1/gpt.json" \
    FM_QUOTA_POOLS_GPT="$1/gpt-reader.sh" \
    "$POOLS"
}

test_both_pools_land_in_one_board_shape() {
  local home out
  home=$(make_home both)
  fake_quota_axi "$home" "$QUOTA_AXI_JSON"
  fake_gpt_reader "$home" "$GPT_JSON"
  out=$(run_pools "$home") || fail "the pool reader failed"
  printf '%s' "$out" | jq -e '
    length == 2
    and (.[0] | .provider == "claude" and .label == "Claude"
      and .percent_remaining == 70 and .window == "week"
      and .resets_at == "2026-09-07T03:59:59Z" and .estimate == false and .note == null)
    and (.[1] | .provider == "openai-codex" and .label == "ChatGPT"
      and .percent_remaining == 94 and .window == "30 day"
      and .resets_at == "2026-09-30T21:37:52Z" and .estimate == false and .note == null)
  ' >/dev/null || fail "the two readers did not map onto one board shape: $out"
  pass "both provider pools land in one board-shaped array"
}

test_an_absent_claude_reader_stays_in_the_array_with_its_reason() {
  local home out
  home=$(make_home no-quota-axi)
  fake_quota_axi "$home" -
  fake_gpt_reader "$home" "$GPT_JSON"
  # A fakebin with no quota-axi is not enough while the real tool is still on
  # PATH, so run against a PATH that carries only jq and the base system.
  ln -sf "$(command -v jq)" "$home/fakebin/jq"
  out=$(PATH="$home/fakebin:/usr/bin:/bin" FAKE_GPT_JSON="$home/gpt.json" \
    FM_QUOTA_POOLS_GPT="$home/gpt-reader.sh" "$POOLS" 2>/dev/null) \
    || fail "a missing quota-axi should not be fatal"
  printf '%s' "$out" | jq -e '
    length == 2
    and (.[0] | .provider == "claude" and .percent_remaining == null and (.note | length) > 0)
  ' >/dev/null || fail "a missing Claude reader did not stay in the array: $out"
  pass "a pool whose reader is missing stays in the array with its reason"
}

test_an_unreadable_gpt_pool_carries_the_readers_own_detail() {
  local home out
  home=$(make_home gpt-unavailable)
  fake_quota_axi "$home" "$QUOTA_AXI_JSON"
  fake_gpt_reader "$home" '{"schema":"fm-gpt-quota.v1","status":"unavailable",
    "kind":"auth_required","detail":"no credential file at /nowhere",
    "remedy":"sign in","windows":[],"limiting":null}'
  out=$(run_pools "$home") || fail "an unavailable ChatGPT pool should not be fatal"
  printf '%s' "$out" | jq -e '
    (.[1] | .provider == "openai-codex" and .percent_remaining == null
      and .note == "no credential file at /nowhere")
  ' >/dev/null || fail "the ChatGPT reader's own reason was not carried through: $out"
  pass "an unreadable ChatGPT pool carries the reader's own reason"
}

test_an_estimated_reading_is_marked_as_an_estimate() {
  local home out
  home=$(make_home estimate)
  fake_quota_axi "$home" "$QUOTA_AXI_JSON"
  fake_gpt_reader "$home" '{"schema":"fm-gpt-quota.v1","status":"known",
    "source":"local_tally","estimate":true,
    "limiting":{"id":"primary","label":"30 day","percentRemaining":80,"resetsAt":null}}'
  out=$(run_pools "$home") || fail "an estimated reading should not be fatal"
  printf '%s' "$out" | jq -e '.[1].estimate == true and .[1].percent_remaining == 80' \
    >/dev/null || fail "an estimated reading was not marked: $out"
  pass "a reading the source calls an estimate stays marked as an estimate"
}

test_the_output_satisfies_the_board_payload_contract() {
  local home out board data
  home=$(make_home board-contract)
  mkdir -p "$home/state" "$home/data"
  fm_fake_exit0 "$home/fakebin" lavish-axi
  fake_quota_axi "$home" "$QUOTA_AXI_JSON"
  fake_gpt_reader "$home" "$GPT_JSON"
  out=$(run_pools "$home") || fail "the pool reader failed"
  data="$home/payload.json"
  jq -n --argjson pools "$out" '{
    schema:"fm-bearings-board.v1", home:"pool-home", generated:"2026-08-31T00:00Z",
    prs_live:false, captains_call:[], underway:[], landed:[], charted:[], pools:$pools}' > "$data"
  board="$ROOT/bin/fm-bearings-board.sh"
  PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    "$board" build "$data" >/dev/null \
    || fail "the board refused a payload built from this reader's own output"
  pass "the reader's output is accepted by the board payload contract"
}

test_a_reader_that_prints_nothing_still_yields_a_marked_pool() {
  local home out
  home=$(make_home silent-reader)
  fake_quota_axi "$home" "$QUOTA_AXI_JSON"
  cat > "$home/fakebin/quota-axi" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$home/fakebin/quota-axi"
  fake_gpt_reader "$home" "$GPT_JSON"
  out=$(run_pools "$home") || fail "a silent quota-axi should not be fatal"
  printf '%s' "$out" | jq -e '
    length == 2
    and (.[0] | .provider == "claude" and .percent_remaining == null
         and (.note | length) > 0)
    and (.[1] | .percent_remaining == 94)
  ' >/dev/null || fail "a silent reader did not leave a marked pool: $out"
  pass "a reader that answers with nothing leaves its pool marked unreadable"
}

test_both_pools_land_in_one_board_shape
test_an_absent_claude_reader_stays_in_the_array_with_its_reason
test_an_unreadable_gpt_pool_carries_the_readers_own_detail
test_an_estimated_reading_is_marked_as_an_estimate
test_the_output_satisfies_the_board_payload_contract
test_a_reader_that_prints_nothing_still_yields_a_marked_pool
