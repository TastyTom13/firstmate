#!/usr/bin/env bash
# Behavior tests for bin/fm-gpt-quota.sh: the reading it produces from the
# backend's rate-limit headers, the window arithmetic, the credential
# boundaries, and the reported-not-guessed failure shape. Every case drives the
# real executable with a fake curl, so no test touches the network.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

READER="$ROOT/bin/fm-gpt-quota.sh"
TMP_ROOT=$(fm_test_tmproot fm-gpt-quota)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

# A home with a valid-looking credential and a curl that replays <headers>.
make_home() {  # <name> <headers-text>
  local home="$TMP_ROOT/$1" fakebin
  mkdir -p "$home"
  fakebin=$(fm_fakebin "$home")
  printf '%s' "$2" > "$home/headers.txt"
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
# Record argv so a test can prove the token never rides the process table,
# then replay the canned response headers into --dump-header's file.
printf '%s\n' "$@" > "$FAKE_CURL_ARGV"
cat > "$FAKE_CURL_STDIN"
dump=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dump-header) dump=$2; shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$dump" ] && cp "$FAKE_CURL_HEADERS" "$dump"
exit "${FAKE_CURL_EXIT:-0}"
SH
  chmod +x "$fakebin/curl"
  jq -n --argjson expires "$(( ($(date -u +%s) + 86400) * 1000 ))" '{
    "openai-codex": {type: "oauth", access: "fake-access-token-value",
                     refresh: "fake-refresh", expires: $expires,
                     accountId: "acct-1234"}}' > "$home/auth.json"
  printf '%s\n' "$home"
}

run_reader() {  # <home> <args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" \
    FAKE_CURL_HEADERS="$home/headers.txt" \
    FAKE_CURL_ARGV="$home/curl-argv.txt" \
    FAKE_CURL_STDIN="$home/curl-stdin.txt" \
    FM_GPT_QUOTA_AUTH="$home/auth.json" \
    FM_GPT_QUOTA_BASE_URL="https://example.invalid/backend-api" \
    "$READER" "$@"
}

FULL_HEADERS='HTTP/2 400
content-type: application/json
x-codex-plan-type: plus
x-codex-active-limit: premium
x-codex-primary-window-minutes: 43200
x-codex-primary-used-percent: 6
x-codex-primary-reset-at: 1790804272
x-codex-primary-reset-after-seconds: 2591264
x-codex-secondary-window-minutes: 10080
x-codex-secondary-used-percent: 55
x-codex-secondary-reset-at: 1788600000
x-codex-secondary-reset-after-seconds: 400000
'

test_it_reports_remaining_allowance_per_window() {
  local home out
  home=$(make_home per-window "$FULL_HEADERS")
  out=$(run_reader "$home" --json) || fail "the reader failed on a good response"
  printf '%s' "$out" | jq -e '
    .status == "known" and .source == "response_headers" and .estimate == false
    and .plan == "plus"
    and (.windows | length) == 2
    and (.windows[0] | .id == "primary" and .percentRemaining == 94
      and .label == "30 day" and .resetsAt == "2026-09-30T21:37:52Z")
    and (.windows[1] | .id == "secondary" and .percentRemaining == 45 and .label == "7 day")
  ' >/dev/null || fail "the reading did not describe both windows: $out"
  pass "a good response reports remaining allowance and reset time per window"
}

test_the_headline_is_the_tightest_window() {
  local home out
  home=$(make_home tightest "$FULL_HEADERS")
  out=$(run_reader "$home" --json) || fail "the reader failed on a good response"
  printf '%s' "$out" | jq -e '.limiting.id == "secondary" and .limiting.percentRemaining == 45' \
    >/dev/null || fail "the headline was not the window with least left: $out"
  pass "the headline figure is the window with the least left"
}

test_a_window_the_account_does_not_have_is_not_reported_as_free() {
  local home out
  home=$(make_home no-secondary "HTTP/2 400
x-codex-primary-window-minutes: 300
x-codex-primary-used-percent: 10
x-codex-primary-reset-at: 1790804272
x-codex-primary-reset-after-seconds: 100
x-codex-secondary-window-minutes: 0
x-codex-secondary-used-percent: 0
x-codex-secondary-reset-at:
x-codex-secondary-reset-after-seconds: 0
")
  out=$(run_reader "$home" --json) || fail "the reader failed on a single-window response"
  printf '%s' "$out" | jq -e '
    (.windows | length) == 1 and .windows[0].label == "5 hour" and .limiting.percentRemaining == 90
  ' >/dev/null || fail "a zero-length window was not dropped: $out"
  pass "a window the account does not have is dropped, not shown as fully free"
}

test_the_token_never_rides_the_command_line() {
  local home
  home=$(make_home token-safety "$FULL_HEADERS")
  run_reader "$home" --json >/dev/null || fail "the reader failed on a good response"
  grep -q 'fake-access-token-value' "$home/curl-stdin.txt" \
    || fail "the credential never reached the request at all"
  if grep -q 'fake-access-token-value' "$home/curl-argv.txt"; then
    fail "the access token was passed in argv, where any process can read it"
  fi
  pass "the access token reaches the request without ever entering argv"
}

test_a_missing_credential_is_reported_not_guessed() {
  local home out
  home=$(make_home no-credential "$FULL_HEADERS")
  rm -f "$home/auth.json"
  out=$(run_reader "$home" --json) || fail "a missing credential should not be fatal"
  printf '%s' "$out" | jq -e '
    .status == "unavailable" and .kind == "auth_required"
    and (.detail | length) > 0 and (.remedy | length) > 0
    and .windows == [] and .limiting == null
  ' >/dev/null || fail "a missing credential did not report a concrete reason: $out"
  pass "a missing credential reports why instead of inventing a reading"
}

test_an_expired_token_is_named_before_the_request_is_made() {
  local home out
  home=$(make_home expired "$FULL_HEADERS")
  jq '.["openai-codex"].expires = 1' "$home/auth.json" > "$home/auth.tmp" \
    && mv "$home/auth.tmp" "$home/auth.json"
  out=$(run_reader "$home" --json) || fail "an expired token should not be fatal"
  printf '%s' "$out" | jq -e '.status == "unavailable" and .kind == "auth_expired"' \
    >/dev/null || fail "an expired token was not named: $out"
  [ ! -f "$home/curl-argv.txt" ] || fail "a request was sent with a token already known to be expired"
  pass "an expired token is named without spending a request on it"
}

test_a_response_without_the_headers_is_unavailable() {
  local home out
  home=$(make_home no-headers "HTTP/2 400
content-type: application/json
")
  out=$(run_reader "$home" --json) || fail "a header-less response should not be fatal"
  printf '%s' "$out" | jq -e '.status == "unavailable" and .kind == "no_headers"' \
    >/dev/null || fail "a header-less response did not report unavailable: $out"
  pass "a response without the rate-limit headers reports unavailable"
}

test_an_unreachable_backend_is_unavailable() {
  local home out
  home=$(make_home unreachable "$FULL_HEADERS")
  out=$(PATH="$home/fakebin:$PATH" FAKE_CURL_HEADERS="$home/headers.txt" \
    FAKE_CURL_ARGV="$home/curl-argv.txt" FAKE_CURL_STDIN="$home/curl-stdin.txt" \
    FAKE_CURL_EXIT=7 FM_GPT_QUOTA_AUTH="$home/auth.json" \
    "$READER" --json) || fail "an unreachable backend should not be fatal"
  printf '%s' "$out" | jq -e '.status == "unavailable" and .kind == "unreachable"' \
    >/dev/null || fail "an unreachable backend did not report unavailable: $out"
  pass "an unreachable backend reports unavailable rather than failing the caller"
}

test_the_default_view_is_a_quota_axi_shaped_block() {
  local home out
  home=$(make_home toon "$FULL_HEADERS")
  out=$(run_reader "$home") || fail "the default view failed"
  printf '%s' "$out" | grep -q '^quota\[2\]{provider,scope,percentRemaining,window,resetsAt,source,estimate}:$' \
    || fail "the default view did not carry a quota block: $out"
  printf '%s' "$out" | grep -q 'openai-codex,secondary,45,"7 day"' \
    || fail "the default view did not render a window row: $out"
  pass "the default view is a quota-axi-shaped block with one row per window"
}

test_the_default_view_names_an_unreadable_pool() {
  local home out
  home=$(make_home toon-attention "$FULL_HEADERS")
  rm -f "$home/auth.json"
  out=$(run_reader "$home") || fail "the default view failed"
  printf '%s' "$out" | grep -q '^attention\[1\]{provider,scope,kind,detail,remedy}:$' \
    || fail "an unreadable pool did not render an attention block: $out"
  pass "an unreadable pool renders an attention block naming the reason"
}

test_a_partial_header_set_is_unavailable_not_a_crash() {
  local home out
  home=$(make_home partial-headers 'HTTP/2 400
content-type: application/json
x-codex-plan-type: plus
x-codex-primary-window-minutes: 43200
')
  out=$(run_reader "$home" --json) || fail "a partial header set should not be fatal"
  printf '%s' "$out" | jq -e '
    .status == "unavailable" and (.detail | length) > 0
    and .windows == [] and .limiting == null
  ' >/dev/null || fail "a partial header set did not report unavailable: $out"
  pass "a half-answered header set reports unavailable instead of failing"
}

test_a_fractional_percent_is_read_not_rejected() {
  local home out
  home=$(make_home fractional 'HTTP/2 400
content-type: application/json
x-codex-primary-window-minutes: 43200
x-codex-primary-used-percent: 6.5
')
  out=$(run_reader "$home" --json) || fail "a fractional percent should not be fatal"
  printf '%s' "$out" | jq -e '
    .status == "known" and (.windows | length) == 1
    and .limiting.percentRemaining == 93.5
  ' >/dev/null || fail "a fractional used-percent was not read: $out"
  pass "a fractional used-percent is read as a real reading"
}

test_a_zero_length_primary_window_is_dropped() {
  local home out
  home=$(make_home zero-primary 'HTTP/2 400
content-type: application/json
x-codex-primary-window-minutes: 0
x-codex-primary-used-percent: 0
x-codex-secondary-window-minutes: 10080
x-codex-secondary-used-percent: 55
')
  out=$(run_reader "$home" --json) || fail "a zero-minute primary should not be fatal"
  printf '%s' "$out" | jq -e '
    (.windows | length) == 1 and .windows[0].id == "secondary"
    and .limiting.percentRemaining == 45
  ' >/dev/null || fail "a zero-minute primary window was not dropped: $out"
  pass "a zero-length primary window is dropped, not shown as fully free"
}

test_it_reports_remaining_allowance_per_window
test_the_headline_is_the_tightest_window
test_a_window_the_account_does_not_have_is_not_reported_as_free
test_the_token_never_rides_the_command_line
test_a_missing_credential_is_reported_not_guessed
test_an_expired_token_is_named_before_the_request_is_made
test_a_response_without_the_headers_is_unavailable
test_an_unreachable_backend_is_unavailable
test_the_default_view_is_a_quota_axi_shaped_block
test_the_default_view_names_an_unreadable_pool
test_a_partial_header_set_is_unavailable_not_a_crash
test_a_fractional_percent_is_read_not_rejected
test_a_zero_length_primary_window_is_dropped
