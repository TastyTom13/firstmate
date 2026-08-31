#!/usr/bin/env bash
# fm-gpt-quota.sh - report the ChatGPT (Codex) subscription quota window.
#
# quota-axi covers every provider whose usage it can read locally, but it
# reports "Codex quota unavailable" on a home that talks to OpenAI through an
# OAuth ChatGPT account with no codex CLI installed, because there is no local
# usage file to read. This script closes that gap for exactly that case.
#
# Source of truth: the Codex responses endpoint attaches the account's current
# rate-limit state to EVERY response as `x-codex-*` headers. This script sends
# one deliberately incomplete request - a supported model with no `input` - so
# the backend validates the model, attaches the headers, and rejects the call
# with HTTP 400 before any model is invoked. The reading is therefore the
# account's own live number, not an estimate, and it costs no tokens.
#
# Usage:
#   fm-gpt-quota.sh [--json]
#
# (default)  A quota-axi-shaped TOON block: one `quota` row per readable
#            window, or one `attention` row naming why the reading is
#            unavailable.
# --json     One `fm-gpt-quota.v1` JSON object for machine consumers
#            (bin/fm-quota-pools.sh is the one in this repo).
#
# Every reading carries `source` and `estimate` so a consumer never has to
# guess how the number was obtained. Today the only source is
# `response_headers`, whose `estimate` is false: it is the same allowance
# figure the provider enforces. A future source that measures this home's own
# spend instead of the account's remaining allowance must set `estimate` true
# and say so in `detail`, because those two numbers answer different questions.
#
# Failure is reported, never guessed: a missing credential, an expired token,
# a credential the backend refuses (HTTP 401/403), an unreachable backend, or
# a response without the headers each produce status=unavailable with the
# concrete reason, and exit 0 so a board build or digest keeps working with
# the pool marked unreadable.
#
# FM_GPT_QUOTA_AUTH     credential file (default ~/.pi/agent/auth.json), read
#                       for its `openai-codex` oauth entry. Token material is
#                       never printed and never passed in argv.
# FM_GPT_QUOTA_MODEL    model used to pass the backend's model gate (default
#                       gpt-5.5). No completion is ever generated.
# FM_GPT_QUOTA_BASE_URL Codex base URL (default https://chatgpt.com/backend-api).
# FM_GPT_QUOTA_TIMEOUT  probe timeout in seconds (default 15).
set -eu

SCHEMA=fm-gpt-quota.v1
PROVIDER=openai-codex
AUTH_FILE="${FM_GPT_QUOTA_AUTH:-$HOME/.pi/agent/auth.json}"
MODEL="${FM_GPT_QUOTA_MODEL:-gpt-5.5}"
BASE_URL="${FM_GPT_QUOTA_BASE_URL:-https://chatgpt.com/backend-api}"
TIMEOUT="${FM_GPT_QUOTA_TIMEOUT:-15}"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'fm-gpt-quota: %s\n' "$*" >&2
  exit 1
}

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# An unreadable account is a reported state, not a crash: emit the same
# document shape with status=unavailable so consumers have one contract.
unavailable() {  # <kind> <detail> <remedy>
  jq -n --arg schema "$SCHEMA" --arg provider "$PROVIDER" --arg generated "$(now_iso)" \
    --arg kind "$1" --arg detail "$2" --arg remedy "$3" '{
      schema: $schema, generatedAt: $generated, provider: $provider,
      status: "unavailable", kind: $kind, detail: $detail, remedy: $remedy,
      source: null, estimate: null, windows: [], limiting: null
    }'
}

# 43200 -> "30 day", 10080 -> "7 day", 300 -> "5 hour", 90 -> "90 min".
window_label() {  # <minutes>
  local m=$((10#$1))
  if [ "$m" -ge 1440 ] && [ $((m % 1440)) -eq 0 ]; then
    printf '%s day\n' $((m / 1440))
  elif [ "$m" -ge 60 ] && [ $((m % 60)) -eq 0 ]; then
    printf '%s hour\n' $((m / 60))
  else
    printf '%s min\n' "$m"
  fi
}

is_window_minutes() {  # <value>
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$((10#$1))" -gt 0 ]
}

is_percent() {  # <value>
  case "$1" in
    ''|.|*[!0-9.]*|*.*.*|.*|*.) return 1 ;;
  esac
  return 0
}

# A window the account does not have is reported as zero minutes; carrying it
# as a 100%-free window would invent headroom that does not exist, so any
# window without a usable length and percent is dropped.
append_window() {  # <windows-json> <id> <minutes> <used> <resets-at> <resets-in>
  local minutes=$3 used=$4
  if ! is_window_minutes "$minutes" || ! is_percent "$used"; then
    printf '%s' "$1"
    return
  fi
  printf '%s' "$1" | jq -c \
    --arg id "$2" --arg label "$(window_label "$minutes")" \
    --arg minutes "$minutes" --arg used "$used" \
    --arg resets_at "$5" --arg resets_in "$6" '
    ($minutes | tonumber) as $m
    | ($used | tonumber) as $u
    | . + [{
      id: $id, label: $label, windowMinutes: $m,
      usedPercent: $u, percentRemaining: (100 - $u),
      resetsAt: (if ($resets_at | test("^[0-9]+$")) then ($resets_at | tonumber | todate) else null end),
      resetsInSeconds: (if ($resets_in | test("^[0-9]+$")) then ($resets_in | tonumber) else null end)
    }]'
}

http_status() {  # <headers-file>
  tr -d '\r' < "$1" | awk '/^HTTP\// { code = $2 } END { print code }'
}

header_value() {  # <headers-file> <name>
  tr -d '\r' < "$1" | awk -v want="$2" '
    BEGIN { IGNORECASE = 1 }
    index(tolower($0), want ":") == 1 {
      sub(/^[^:]*:[ \t]*/, "")
      value = $0
    }
    END { print value }
  '
}

read_quota() {
  local access account expires headers status http_code minutes used reset_at reset_in
  local plan active_limit secondary_minutes secondary_used
  local secondary_reset_at secondary_reset_in windows

  command -v jq >/dev/null 2>&1 || fail "jq is required"
  command -v curl >/dev/null 2>&1 || fail "curl is required"

  [ -f "$AUTH_FILE" ] || {
    unavailable auth_required "no credential file at $AUTH_FILE" \
      "sign in to the ChatGPT account with the agent that owns that file"
    return
  }
  if ! jq -e '.["openai-codex"].access | type == "string" and length > 0' "$AUTH_FILE" >/dev/null 2>&1; then
    unavailable auth_required "$AUTH_FILE has no openai-codex access token" \
      "sign in to the ChatGPT account with the agent that owns that file"
    return
  fi
  access=$(jq -r '.["openai-codex"].access' "$AUTH_FILE")
  account=$(jq -r '.["openai-codex"].accountId // ""' "$AUTH_FILE")
  expires=$(jq -r '.["openai-codex"].expires // 0' "$AUTH_FILE")
  [ -n "$account" ] || {
    unavailable auth_required "$AUTH_FILE has no openai-codex accountId" \
      "sign in again so the credential records its account id"
    return
  }
  # A stale token would come back as an opaque 401; naming the expiry is more
  # useful than relaying that.
  case "$expires" in
    ''|*[!0-9]*) : ;;
    *) if [ "$expires" -gt 0 ] && [ "$expires" -le "$(( $(date -u +%s) * 1000 ))" ]; then
         unavailable auth_expired "the stored openai-codex token expired" \
           "run the agent that owns $AUTH_FILE once so it refreshes the token"
         return
       fi ;;
  esac

  headers=$(mktemp) || fail "cannot stage the probe headers"
  # The token goes in via a curl config on stdin, never argv, so it cannot be
  # read out of the process table by anything else on this machine.
  status=0
  printf 'header = "Authorization: Bearer %s"\nheader = "chatgpt-account-id: %s"\n' \
    "$access" "$account" |
    curl --silent --show-error --config - \
      --max-time "$TIMEOUT" \
      --request POST \
      --header 'originator: pi' \
      --header 'OpenAI-Beta: responses=experimental' \
      --header 'content-type: application/json' \
      --header 'accept: text/event-stream' \
      --data "$(jq -nc --arg model "$MODEL" '{model: $model, stream: true, store: false}')" \
      --dump-header "$headers" \
      --output /dev/null \
      "$BASE_URL/codex/responses" 2>/dev/null || status=$?
  if [ "$status" -ne 0 ]; then
    rm -f -- "$headers"
    unavailable unreachable "the Codex backend did not answer (curl exit $status)" \
      "check network access to $BASE_URL"
    return
  fi

  http_code=$(http_status "$headers")
  minutes=$(header_value "$headers" 'x-codex-primary-window-minutes')
  used=$(header_value "$headers" 'x-codex-primary-used-percent')
  reset_at=$(header_value "$headers" 'x-codex-primary-reset-at')
  reset_in=$(header_value "$headers" 'x-codex-primary-reset-after-seconds')
  plan=$(header_value "$headers" 'x-codex-plan-type')
  active_limit=$(header_value "$headers" 'x-codex-active-limit')
  secondary_minutes=$(header_value "$headers" 'x-codex-secondary-window-minutes')
  secondary_used=$(header_value "$headers" 'x-codex-secondary-used-percent')
  secondary_reset_at=$(header_value "$headers" 'x-codex-secondary-reset-at')
  secondary_reset_in=$(header_value "$headers" 'x-codex-secondary-reset-after-seconds')
  rm -f -- "$headers"

  windows='[]'
  windows=$(append_window "$windows" primary "$minutes" "$used" "$reset_at" "$reset_in")
  windows=$(append_window "$windows" secondary "$secondary_minutes" "$secondary_used" \
    "$secondary_reset_at" "$secondary_reset_in")
  if [ "$windows" = '[]' ]; then
    case "$http_code" in
      401|403)
        unavailable auth_required \
          "the Codex backend refused the stored credential (HTTP $http_code)" \
          "sign in to the ChatGPT account again with the agent that owns $AUTH_FILE"
        return ;;
    esac
    unavailable no_headers "the Codex backend answered without usable rate-limit headers" \
      "check that $MODEL is still accepted for this account"
    return
  fi

  # The account can only spend what its tightest window allows, so that window
  # is the one headline figure; ties keep the shorter window.
  jq -n --arg schema "$SCHEMA" --arg provider "$PROVIDER" --arg generated "$(now_iso)" \
    --arg plan "$plan" --arg active_limit "$active_limit" --argjson windows "$windows" '{
      schema: $schema, generatedAt: $generated, provider: $provider,
      status: "known", kind: null, detail: null, remedy: null,
      source: "response_headers", estimate: false,
      plan: (if $plan == "" then null else $plan end),
      activeLimit: (if $active_limit == "" then null else $active_limit end),
      windows: $windows,
      limiting: ($windows | sort_by(.percentRemaining, .windowMinutes) | first)
    }'
}

render_toon() {  # <json>
  printf 'bin: %s\n' "$0"
  printf 'description: Report the ChatGPT (Codex) subscription quota window for this home\n'
  printf '%s' "$1" | jq -r '
    def q: "\"" + . + "\"";
    "generatedAt: " + (.generatedAt | q),
    (if .status == "known" then
      "quota[" + (.windows | length | tostring) + "]{provider,scope,percentRemaining,window,resetsAt,source,estimate}:",
      (.windows[] | "  " + $p + "," + .id + "," + (.percentRemaining | tostring) + ","
        + (.label | q) + "," + ((.resetsAt // "unknown") | q) + "," + $src + "," + ($est | tostring))
    else
      "attention[1]{provider,scope,kind,detail,remedy}:",
      ("  " + $p + ",all," + .kind + "," + (.detail | q) + "," + (.remedy | q))
    end)
  ' --arg p "$PROVIDER" \
    --arg src "$(printf '%s' "$1" | jq -r '.source // "none"')" \
    --argjson est "$(printf '%s' "$1" | jq -c '.estimate')"
}

main() {
  local json
  case "${1-}" in
    -h|--help|help) usage; return 0 ;;
    --json) json=$(read_quota); printf '%s\n' "$json"; return 0 ;;
    '') json=$(read_quota); render_toon "$json"; return 0 ;;
    *) usage >&2; exit 2 ;;
  esac
}

main "$@"
