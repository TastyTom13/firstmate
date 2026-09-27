#!/usr/bin/env bash
# Behavior tests for bin/fm-quota-pools.sh: the board-shaped pool inventory it
# builds for every fleet quota lane, and the way an unreadable pool stays in
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

fake_gpt_reader() {  # <home> <pro-json> [team-json]
  printf '%s' "$2" > "$1/gpt-pro.json"
  printf '%s' "${3:-$2}" > "$1/gpt-team.json"
  cat > "$1/gpt-reader.sh" <<'SH'
#!/usr/bin/env bash
case "${FM_GPT_QUOTA_AUTH-}" in
  *team*) cat "$FAKE_GPT_TEAM_JSON" ;;
  *) cat "$FAKE_GPT_PRO_JSON" ;;
esac
SH
  chmod +x "$1/gpt-reader.sh"
}

fake_supplemental_readers() {  # <home>
  cat > "$1/claude-accounts.sh" <<'SH'
#!/usr/bin/env bash
[ "${FAKE_CLAUDE_ACCOUNTS_EMPTY:-0}" != 1 ] || exit 0
cat <<'JSON'
[{"provider":"claude","label":"Claude Max A (active)","percent_remaining":70,"window":"week","resets_at":"2026-09-07T03:59:59Z","estimate":false,"note":null},{"provider":"claude","label":"Claude Max B","percent_remaining":100,"window":"week","resets_at":"2026-09-14T03:59:59Z","estimate":false,"note":null}]
JSON
SH
  cat > "$1/free-reader.sh" <<'SH'
#!/usr/bin/env bash
cat <<'JSON'
[{"provider":"groq","label":"Groq free tier","percent_remaining":80,"window":"day","resets_at":null,"estimate":false,"note":null},{"provider":"cerebras","label":"Cerebras free tier","percent_remaining":null,"window":"","resets_at":null,"estimate":false,"note":"key present, no usage API"},{"provider":"cloudflare","label":"Cloudflare free tier","percent_remaining":75,"window":"API rate limit","resets_at":null,"estimate":false,"note":null},{"provider":"openrouter","label":"OpenRouter free tier","percent_remaining":60,"window":"credits","resets_at":null,"estimate":false,"note":null},{"provider":"gemini","label":"Gemini free tier 1","percent_remaining":null,"window":"","resets_at":null,"estimate":false,"note":"key present, no usage API"},{"provider":"gemini","label":"Gemini free tier 2","percent_remaining":null,"window":"","resets_at":null,"estimate":false,"note":"key present, no usage API"},{"provider":"gemini","label":"Gemini free tier 3","percent_remaining":null,"window":"","resets_at":null,"estimate":false,"note":"key present, no usage API"},{"provider":"gemini","label":"Gemini free tier 4","percent_remaining":null,"window":"","resets_at":null,"estimate":false,"note":"key present, no usage API"}]
JSON
SH
  chmod +x "$1/claude-accounts.sh" "$1/free-reader.sh"
}

run_pools() {  # <home>
  fake_supplemental_readers "$1"
  PATH="$1/fakebin:$PATH" \
    FAKE_QUOTA_AXI_JSON="$1/quota-axi.json" \
    FAKE_GPT_PRO_JSON="$1/gpt-pro.json" \
    FAKE_GPT_TEAM_JSON="$1/gpt-team.json" \
    FM_QUOTA_POOLS_GPT="$1/gpt-reader.sh" \
    FM_QUOTA_POOLS_GPT_PRO_AUTH="$1/pro-auth.json" \
    FM_QUOTA_POOLS_GPT_TEAM_AUTH="$1/team-auth.json" \
    FM_QUOTA_POOLS_CLAUDE_ACCOUNTS="$1/claude-accounts.sh" \
    FM_QUOTA_POOLS_FREE="$1/free-reader.sh" \
    FM_QUOTA_POOLS_CACHE="$1/cache.json" \
    "$POOLS"
}

test_both_pools_land_in_one_board_shape() {
  local home out
  home=$(make_home both)
  fake_quota_axi "$home" "$QUOTA_AXI_JSON"
  fake_gpt_reader "$home" "$GPT_JSON"
  out=$(run_pools "$home") || fail "the pool reader failed"
  printf '%s' "$out" | jq -e '
    length == 12
    and ([.[].label] | index("Claude Max A (active)") != null)
    and ([.[].label] | index("Claude Max B") != null)
    and ([.[].label] | index("ChatGPT Pro") != null)
    and ([.[].label] | index("ChatGPT Team") != null)
    and ([.[].label] | index("Groq free tier") != null)
    and ([.[].label] | index("Cerebras free tier") != null)
    and ([.[].label] | index("Cloudflare free tier") != null)
    and ([.[].label] | index("OpenRouter free tier") != null)
    and ([.[].label] | index("Gemini free tier 4") != null)
    and (.[] | select(.label == "Claude Max B")
      | .percent_remaining == 100 and .resets_at == "2026-09-14T03:59:59Z")
  ' >/dev/null || fail "the fleet pools did not map onto one board shape: $out"
  pass "every fleet pool lands in one board-shaped array"
}

test_mirrored_free_tier_keys_use_vendor_readings_without_a_vault_call() {
  local home out
  home=$(make_home free-readings)
  fake_quota_axi "$home" "$QUOTA_AXI_JSON"
  fake_gpt_reader "$home" "$GPT_JSON"
  fake_supplemental_readers "$home"
  mkdir -p "$home/config"
  cat > "$home/config/env-sync.toml" <<'TOML'
[quota-pools]
path = "."
file = ".env.quota-pools"
keys = ["fixture"]
TOML
  cat > "$home/.env.quota-pools" <<'ENV'
GROQ_API_KEY=groq-secret
CEREBRAS_API_KEY=cerebras-secret
CLOUDFLARE_API_KEY=cloudflare-secret
OPENROUTER_API_KEY=openrouter-secret
GEMINI_API_KEY=gemini-one
GEMINI_API_KEY2=gemini-two
GEMINI_API_KEY3=gemini-three
GEMINI_API_KEY4=gemini-four
ENV
  chmod 600 "$home/.env.quota-pools"
  cat > "$home/fakebin/curl" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
headers= output= url=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dump-header) headers=$2; shift 2 ;;
    --output) output=$2; shift 2 ;;
    http*) url=$1; shift ;;
    *) shift ;;
  esac
done
case "$url" in
  *groq*) printf 'HTTP/2 200\nx-ratelimit-limit-requests: 100\nx-ratelimit-remaining-requests: 80\n' > "$headers"; : > "$output" ;;
  *cloudflare*) printf 'HTTP/2 200\nratelimit-policy: "default";q=1200;w=300\nratelimit: "default";r=900;t=1\n' > "$headers"; : > "$output" ;;
  *openrouter*) printf '%s\n' '{"data":{"total_credits":10,"total_usage":4}}' > "$output" ;;
esac
SH
  chmod +x "$home/fakebin/curl"
  out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FAKE_GPT_PRO_JSON="$home/gpt-pro.json" FAKE_GPT_TEAM_JSON="$home/gpt-team.json" \
    FM_QUOTA_POOLS_GPT="$home/gpt-reader.sh" FM_QUOTA_POOLS_CLAUDE_ACCOUNTS="$home/claude-accounts.sh" \
    FM_QUOTA_POOLS_CACHE="$home/cache.json" "$POOLS") || fail "mirrored free-tier readings failed"
  printf '%s' "$out" | jq -e '
    (.[] | select(.label == "Groq free tier") | .percent_remaining == 80)
    and (.[] | select(.label == "Cloudflare free tier") | .percent_remaining == 75)
    and (.[] | select(.label == "OpenRouter free tier") | .percent_remaining == 60)
    and (.[] | select(.label == "Cerebras free tier") | .note == "key present, no usage API")
    and ([.[] | select(.provider == "gemini" and .note == "key present, no usage API")] | length == 4)
  ' >/dev/null || fail "the free-tier readings were incomplete: $out"
  pass "mirrored free-tier keys use vendor readings without a vault call"
}

test_an_absent_claude_reader_stays_in_the_array_with_its_reason() {
  local home out
  home=$(make_home no-quota-axi)
  fake_quota_axi "$home" -
  fake_gpt_reader "$home" "$GPT_JSON"
  fake_supplemental_readers "$home"
  cat > "$home/claude-accounts.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' '[{"provider":"claude","label":"Claude Max A (active)","percent_remaining":null,"window":"","resets_at":null,"estimate":false,"note":"quota-axi is not installed"},{"provider":"claude","label":"Claude Max B","percent_remaining":null,"window":"","resets_at":null,"estimate":false,"note":"saved login unreadable"}]'
SH
  chmod +x "$home/claude-accounts.sh"
  out=$(PATH="$home/fakebin:/usr/bin:/bin" FAKE_GPT_PRO_JSON="$home/gpt-pro.json" \
    FAKE_GPT_TEAM_JSON="$home/gpt-team.json" FM_QUOTA_POOLS_GPT="$home/gpt-reader.sh" \
    FM_QUOTA_POOLS_CLAUDE_ACCOUNTS="$home/claude-accounts.sh" \
    FM_QUOTA_POOLS_FREE="$home/free-reader.sh" FM_QUOTA_POOLS_CACHE="$home/cache.json" \
    "$POOLS" 2>/dev/null) || fail "a missing quota-axi should not be fatal"
  printf '%s' "$out" | jq -e '
    ([.[] | select(.provider == "claude")] | length) == 2
    and all(.[] | select(.provider == "claude"); .percent_remaining == null and (.note | length) > 0)
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
    (.[] | select(.label == "ChatGPT Pro") | .percent_remaining == null
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
  printf '%s' "$out" | jq -e '(.[] | select(.label == "ChatGPT Pro") | .estimate == true and .percent_remaining == 80)' \
    >/dev/null || fail "an estimated reading was not marked: $out"
  pass "a reading the source calls an estimate stays marked as an estimate"
}

# Build a board from <pools-json> through the real bin/fm-bearings-board.sh,
# which is the validator this array has to satisfy.
board_accepts() {  # <home> <pools-json>
  local home=$1 data
  mkdir -p "$home/state" "$home/data" "$home/fakebin"
  # The board arms a poll only on a Lavish session it can see open after
  # opening it, so the stub reports the opened shape the real lavish-axi emits
  # (the same stub tests/fm-bearings-board-render.test.sh uses).
  cat > "$home/fakebin/lavish-axi" <<'SH'
#!/usr/bin/env bash
case "${1-}" in
  --version) printf '0.1.61\n' ;;
  '')
    printf 'sessions[1]{file,status,url,pending_prompts}:\n'
    [ ! -s "$FM_HOME/lavish-open" ] \
      || printf '  %s,open,"http://127.0.0.1/session/pools",0\n' "$(cat "$FM_HOME/lavish-open")"
    ;;
  poll)
    while [ "$SECONDS" -lt "${FM_TEST_STUB_MAX_BLOCK_SECONDS:-120}" ]; do sleep 1; done
    exit 75
    ;;
  *)
    real=$(cd "$(dirname "$1")" && pwd -P)/$(basename "$1")
    printf '%s\n' "$real" > "$FM_HOME/lavish-open"
    printf 'session:\n  status: opened\n'
    ;;
esac
SH
  chmod +x "$home/fakebin/lavish-axi"
  data="$home/payload.json"
  jq -n --argjson pools "$2" '{
    schema:"fm-bearings-board.v1", home:"pool-home", generated:"2026-08-31T00:00Z",
    prs_live:false, captains_call:[], underway:[], landed:[], charted:[], pools:$pools}' > "$data"
  PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    "$ROOT/bin/fm-bearings-board.sh" build "$data" >/dev/null
}

test_the_output_satisfies_the_board_payload_contract() {
  local home out
  home=$(make_home board-contract)
  fake_quota_axi "$home" "$QUOTA_AXI_JSON"
  fake_gpt_reader "$home" "$GPT_JSON"
  out=$(run_pools "$home") || fail "the pool reader failed"
  board_accepts "$home" "$out" \
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
  out=$(FAKE_CLAUDE_ACCOUNTS_EMPTY=1 run_pools "$home") || fail "a silent account reader should not be fatal"
  printf '%s' "$out" | jq -e '
    length == 12
    and ([.[] | select(.provider == "claude" and .percent_remaining == null)] | length) >= 1
    and (.[] | select(.label == "ChatGPT Pro") | .percent_remaining == 94)
  ' >/dev/null || fail "a silent reader did not leave a marked pool: $out"
  pass "a reader that answers with nothing leaves its pool marked unreadable"
}

test_an_out_of_range_percent_is_reported_unreadable() {
  local home out
  home=$(make_home out-of-range)
  fake_quota_axi "$home" "${QUOTA_AXI_JSON/70.6/140}"
  fake_gpt_reader "$home" '{"schema":"fm-gpt-quota.v1","status":"known",
    "source":"response_headers","estimate":false,
    "limiting":{"id":"primary","label":"5 hour","percentRemaining":-20,"resetsAt":null}}'
  out=$(run_pools "$home") || fail "an out-of-range percent should not be fatal"
  printf '%s' "$out" | jq -e '
    length == 12
    and all(.[] | select(.provider == "openai-codex"); .percent_remaining == null and (.note | length) > 0)
  ' >/dev/null || fail "an out-of-range percent was not marked unreadable: $out"
  board_accepts "$home" "$out" \
    || fail "the board rejected a payload built from an out-of-range reading"
  pass "a percent outside 0-100 is reported unreadable, not passed to the board"
}

test_both_pools_land_in_one_board_shape
test_mirrored_free_tier_keys_use_vendor_readings_without_a_vault_call
test_an_absent_claude_reader_stays_in_the_array_with_its_reason
test_an_unreadable_gpt_pool_carries_the_readers_own_detail
test_an_estimated_reading_is_marked_as_an_estimate
test_the_output_satisfies_the_board_payload_contract
test_a_reader_that_prints_nothing_still_yields_a_marked_pool
test_an_out_of_range_percent_is_reported_unreadable
