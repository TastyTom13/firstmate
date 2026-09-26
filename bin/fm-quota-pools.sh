#!/usr/bin/env bash
# fm-quota-pools.sh - render every fleet quota pool as the
# fm-bearings-board.v1 `pools` array.
#
# The Baby Menu credits widget and bearings board both consume this command.
# It reports the two saved Claude Max accounts, the Pi and Codex CLI ChatGPT
# accounts, and every configured free-tier API lane. A pool is never omitted
# merely because its credential or usage reading is unavailable.
#
# Usage:
#   fm-quota-pools.sh
#
# Each compact JSON element carries provider, label, percent_remaining, window,
# resets_at, estimate, and note. Percent and reset are null when unreadable.
# Results are cached for 15 minutes because every consumer refresh is a fleet
# overview, not a reason to probe every vendor again.
#
# Local credentials are only read from the Claude labelled Keychain entries,
# the two documented ChatGPT auth files, and protected env mirrors declared by
# config/env-sync.toml (plus .env.quota-pools at the home root). Secret values
# are sent to curl through stdin and are never printed or passed in argv.
#
# Test overrides:
#   FM_QUOTA_POOLS_GPT, FM_QUOTA_POOLS_CLAUDE_ACCOUNTS, FM_QUOTA_POOLS_FREE
#   FM_QUOTA_POOLS_GPT_PRO_AUTH, FM_QUOTA_POOLS_GPT_TEAM_AUTH
#   FM_QUOTA_POOLS_CACHE, FM_QUOTA_POOLS_CACHE_TTL
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FLEET_HOME="${FM_HOME:-$ROOT}"
GPT_READER="${FM_QUOTA_POOLS_GPT:-$SCRIPT_DIR/fm-gpt-quota.sh}"
PRO_AUTH="${FM_QUOTA_POOLS_GPT_PRO_AUTH:-$HOME/.pi/agent/auth.json}"
TEAM_AUTH="${FM_QUOTA_POOLS_GPT_TEAM_AUTH:-$HOME/.codex/auth.json}"
CACHE="${FM_QUOTA_POOLS_CACHE:-${FM_STATE_OVERRIDE:-$FLEET_HOME/state}/.quota-pools-cache.json}"
CACHE_TTL="${FM_QUOTA_POOLS_CACHE_TTL:-900}"
CLAUDE_ACCOUNTS_READER="${FM_QUOTA_POOLS_CLAUDE_ACCOUNTS:-}"
FREE_READER="${FM_QUOTA_POOLS_FREE:-}"

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

fail() { printf 'fm-quota-pools: %s\n' "$*" >&2; exit 1; }

unreadable_pool() {  # <provider> <label> <note>
  jq -nc --arg provider "$1" --arg label "$2" --arg note "$3" '{
    provider: $provider, label: $label, percent_remaining: null,
    window: "", resets_at: null, estimate: false, note: $note
  }'
}

# shellcheck disable=SC2016
POOL_SHAPE='
def pool($provider; $label; $pct; $window; $resets; $estimate):
  if ($pct | type) == "number" and $pct >= 0 and $pct <= 100 then
    {provider: $provider, label: $label, percent_remaining: ($pct | floor),
     window: $window, resets_at: $resets, estimate: $estimate, note: null}
  else
    {provider: $provider, label: $label, percent_remaining: null,
     window: "", resets_at: null, estimate: false,
     note: "the reader reported \($pct | tojson) percent remaining, which is out of range"}
  end;
'

map_quota_axi_claude() {  # <raw> <label>
  printf '%s' "$1" | jq -c --arg label "$2" "$POOL_SHAPE"'
    (.providers // [] | map(select(.provider == "claude")) | first) as $p
    | ($p.quotaSemantics.effectiveAvailability // []
       | map(select(.scope == "all_models" and .status == "known")) | first) as $a
    | if $a == null then
        {provider:"claude", label:$label, percent_remaining:null, window:"",
         resets_at:null, estimate:false, note:"quota-axi reports no readable Claude window"}
      else
        ($a.limitingWindowIds // [] | first) as $wid
        | (($p.windows // []) | map(select(.id == $wid)) | first) as $w
        | pool("claude"; $label; $a.effectivePercentRemaining;
               ($w.label // $wid // ""); ($w.resetsAt // null); false)
      end
  ' 2>/dev/null
}

active_claude_pool() {  # <label>
  local raw
  command -v quota-axi >/dev/null 2>&1 || {
    unreadable_pool claude "$1" "quota-axi is not installed"; return
  }
  raw=$(quota-axi --provider claude --json 2>/dev/null </dev/null) || {
    unreadable_pool claude "$1" "quota-axi could not report"; return
  }
  map_quota_axi_claude "$raw" "$1" \
    || unreadable_pool claude "$1" "quota-axi returned an unreadable report"
}

saved_claude_pool() {  # <label> <display-label>
  local blob access body headers code pct resets window tmp status
  blob=$(security find-generic-password -s "Claude Code-credentials-$1" -a tomas -w 2>/dev/null) || {
    unreadable_pool claude "$2" "saved Claude login $1 is unavailable"; return
  }
  access=$(printf '%s' "$blob" | jq -r '.claudeAiOauth.accessToken // .claudeAiOauth.access_token // empty' 2>/dev/null)
  [ -n "$access" ] || {
    unreadable_pool claude "$2" "saved Claude login $1 has no readable access token"; return
  }
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-quota-claude.XXXXXX") || {
    unreadable_pool claude "$2" "cannot stage the Claude quota response"; return
  }
  chmod 700 "$tmp"
  body="$tmp/body"; headers="$tmp/headers"
  status=0
  printf 'header = "Authorization: Bearer %s"\n' "$access" |
    curl --silent --show-error --config - --max-time 15 \
      --header 'anthropic-beta: oauth-2025-04-20' \
      --header 'User-Agent: claude-code/2.0' --header 'accept: application/json' \
      --dump-header "$headers" --output "$body" --write-out '%{http_code}' \
      'https://api.anthropic.com/api/oauth/usage' > "$tmp/code" 2>/dev/null || status=$?
  code=$(cat "$tmp/code" 2>/dev/null || true)
  if [ "$status" -ne 0 ] || [ "$code" != 200 ]; then
    rm -rf -- "$tmp"
    unreadable_pool claude "$2" "saved Claude login $1 could not be read${code:+ (HTTP $code)}"
    return
  fi
  pct=$(jq -r '[
      (.limits // [] | .[] | select(.group == "session" or .group == "weekly") | .percent),
      .five_hour.utilization, .seven_day.utilization
    ] | map(select(type == "number")) | if length == 0 then empty else (max | 100 - .) end' "$body" 2>/dev/null)
  resets=$(jq -r '[
      (.limits // [] | .[] | select(.group == "session" or .group == "weekly") | {p:.percent,r:.resets_at,g:.group}),
      {p:.five_hour.utilization,r:.five_hour.resets_at,g:"session"},
      {p:.seven_day.utilization,r:.seven_day.resets_at,g:"weekly"}
    ] | map(select(.p|type == "number")) | sort_by(.p) | last | .r // empty' "$body" 2>/dev/null)
  window=$(jq -r '[
      (.limits // [] | .[] | select(.group == "session" or .group == "weekly") | {p:.percent,g:.group}),
      {p:.five_hour.utilization,g:"session"}, {p:.seven_day.utilization,g:"weekly"}
    ] | map(select(.p|type == "number")) | sort_by(.p) | last | if .g == "weekly" then "week" else "session" end' "$body" 2>/dev/null)
  rm -rf -- "$tmp"
  if [ -z "$pct" ]; then
    unreadable_pool claude "$2" "saved Claude login $1 returned no readable quota window"
  else
    jq -nc --arg label "$2" --argjson pct "$pct" --arg window "$window" \
      --arg resets "$resets" "$POOL_SHAPE"'pool("claude";$label;$pct;$window;(if $resets == "" then null else $resets end);false)'
  fi
}

claude_accounts() {
  local current label_a label_b a b
  if [ -n "$CLAUDE_ACCOUNTS_READER" ]; then
    "$CLAUDE_ACCOUNTS_READER" 2>/dev/null || return 1
    return
  fi
  current=$(cat "$FLEET_HOME/data/claude-account.current" 2>/dev/null || true)
  label_a='Claude Max A'; label_b='Claude Max B'
  [ "$current" != max-a ] || label_a="$label_a (active)"
  [ "$current" != max-b ] || label_b="$label_b (active)"
  if [ "$current" = max-a ]; then a=$(active_claude_pool "$label_a"); else a=$(saved_claude_pool max-a "$label_a"); fi
  if [ "$current" = max-b ]; then b=$(active_claude_pool "$label_b"); else b=$(saved_claude_pool max-b "$label_b"); fi
  jq -nc --argjson a "$a" --argjson b "$b" '[$a,$b]'
}

gpt_pool() {  # <label> <auth-file>
  local raw
  [ -x "$GPT_READER" ] || {
    unreadable_pool openai-codex "$1" "the ChatGPT reader is not available"; return
  }
  raw=$(FM_GPT_QUOTA_AUTH="$2" "$GPT_READER" --json 2>/dev/null </dev/null) || {
    unreadable_pool openai-codex "$1" "the ChatGPT reader could not report"; return
  }
  printf '%s' "$raw" | jq -c --arg label "$1" "$POOL_SHAPE"'
    if .status == "known" and .limiting != null then
      pool("openai-codex"; $label; .limiting.percentRemaining;
           (.limiting.label // ""); (.limiting.resetsAt // null); (.estimate == true))
    else
      {provider:"openai-codex", label:$label, percent_remaining:null, window:"",
       resets_at:null, estimate:false,
       note:(.detail // "the ChatGPT quota could not be read")}
    end
  ' 2>/dev/null || unreadable_pool openai-codex "$1" "the ChatGPT reader returned an unreadable report"
}

env_files() {
  local config="$FLEET_HOME/config/env-sync.toml"
  [ ! -f "$FLEET_HOME/.env.quota-pools" ] || printf '%s\n' "$FLEET_HOME/.env.quota-pools"
  [ -f "$config" ] || return 0
  awk -v home="$FLEET_HOME" '
    /^\[/ { path=""; file=".env.local" }
    /^[[:space:]]*path[[:space:]]*=/ { x=$0; sub(/^[^=]*=[[:space:]]*"/,"",x); sub(/"[[:space:]]*$/, "", x); path=x }
    /^[[:space:]]*file[[:space:]]*=/ { x=$0; sub(/^[^=]*=[[:space:]]*"/,"",x); sub(/"[[:space:]]*$/, "", x); file=x }
    /^[[:space:]]*keys[[:space:]]*=/ { if (path != "") print (substr(path,1,1)=="/" ? path : home "/" path) "/" file }
  ' "$config"
}

read_mirrored_key() {  # <name>
  local file value
  while IFS= read -r file; do
    [ -f "$file" ] || continue
    value=$(awk -v key="$1" '
      { line=$0; sub(/^[[:space:]]*export[[:space:]]+/, "", line) }
      index(line,key "=") == 1 {
        sub(/^[^=]*=/, "", line)
        if (line ~ /^".*"$/ || line ~ /^\047.*\047$/) { line=substr(line,2,length(line)-2) }
        print line; exit
      }
    ' "$file")
    [ -z "$value" ] || { printf '%s' "$value"; return 0; }
  done <<EOF
$(env_files)
EOF
  return 1
}

header_value() {  # <headers> <name>
  tr -d '\r' < "$1" | awk -v want="$2" 'BEGIN{IGNORECASE=1} index(tolower($0),tolower(want) ":")==1{sub(/^[^:]*:[ \t]*/,"");v=$0} END{print v}'
}

rate_header_pool() {  # <provider> <label> <key-name> <url> <auth-prefix> <limit-header> <remaining-header>
  local key tmp headers status limit remaining pct
  key=$(read_mirrored_key "$3") || { unreadable_pool "$1" "$2" "key not mirrored"; return; }
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-quota-free.XXXXXX") || { unreadable_pool "$1" "$2" "cannot stage the vendor response"; return; }
  chmod 700 "$tmp"; headers="$tmp/headers"; status=0
  printf 'header = "%s %s"\n' "$5" "$key" |
    curl --silent --show-error --config - --max-time 12 --dump-header "$headers" --output /dev/null "$4" 2>/dev/null || status=$?
  if [ "$status" -ne 0 ]; then rm -rf -- "$tmp"; unreadable_pool "$1" "$2" "usage endpoint did not answer"; return; fi
  limit=$(header_value "$headers" "$6"); remaining=$(header_value "$headers" "$7"); rm -rf -- "$tmp"
  if [ "$1" = cloudflare ]; then
    limit=$(printf '%s' "$limit" | awk 'match($0,/q=[0-9]+/){print substr($0,RSTART+2,RLENGTH-2)}')
    remaining=$(printf '%s' "$remaining" | awk 'match($0,/r=[0-9]+/){print substr($0,RSTART+2,RLENGTH-2)}')
  fi
  case "$limit:$remaining" in *[!0-9.:]*|:*) unreadable_pool "$1" "$2" "key present, no usage headers"; return ;; esac
  pct=$(awk -v r="$remaining" -v l="$limit" 'BEGIN { if (l>0) printf "%.4f", 100*r/l }')
  jq -nc --arg provider "$1" --arg label "$2" --argjson pct "$pct" "$POOL_SHAPE"'pool($provider;$label;$pct;"API rate limit";null;false)'
}

openrouter_pool() {
  local key tmp body status total used pct
  key=$(read_mirrored_key OPENROUTER_API_KEY) || { unreadable_pool openrouter 'OpenRouter free tier' 'key not mirrored'; return; }
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-quota-openrouter.XXXXXX") || { unreadable_pool openrouter 'OpenRouter free tier' 'cannot stage the vendor response'; return; }
  chmod 700 "$tmp"; body="$tmp/body"; status=0
  printf 'header = "Authorization: Bearer %s"\n' "$key" |
    curl --silent --show-error --config - --max-time 12 --output "$body" 'https://openrouter.ai/api/v1/credits' 2>/dev/null || status=$?
  if [ "$status" -ne 0 ]; then rm -rf -- "$tmp"; unreadable_pool openrouter 'OpenRouter free tier' 'usage endpoint did not answer'; return; fi
  total=$(jq -r '.data.total_credits // empty' "$body" 2>/dev/null); used=$(jq -r '.data.total_usage // empty' "$body" 2>/dev/null); rm -rf -- "$tmp"
  case "$total:$used" in *[!0-9.:]*|:*) unreadable_pool openrouter 'OpenRouter free tier' 'key present, usage response unreadable'; return ;; esac
  pct=$(awk -v t="$total" -v u="$used" 'BEGIN { if (t>0) printf "%.4f", 100*(t-u)/t; else print 0 }')
  jq -nc --argjson pct "$pct" "$POOL_SHAPE"'pool("openrouter";"OpenRouter free tier";$pct;"credits";null;false)'
}

presence_pool() {  # <provider> <label> <key>
  if read_mirrored_key "$3" >/dev/null; then
    unreadable_pool "$1" "$2" 'key present, no usage API'
  else
    unreadable_pool "$1" "$2" 'key not mirrored'
  fi
}

free_pools() {
  local groq cloudflare openrouter cerebras g1 g2 g3 g4
  if [ -n "$FREE_READER" ]; then "$FREE_READER" 2>/dev/null || return 1; return; fi
  groq=$(rate_header_pool groq 'Groq free tier' GROQ_API_KEY 'https://api.groq.com/openai/v1/models' 'Authorization: Bearer' x-ratelimit-limit-requests x-ratelimit-remaining-requests)
  cloudflare=$(rate_header_pool cloudflare 'Cloudflare free tier' CLOUDFLARE_API_KEY 'https://api.cloudflare.com/client/v4/user/tokens/verify' 'Authorization: Bearer' ratelimit-policy ratelimit)
  openrouter=$(openrouter_pool)
  cerebras=$(presence_pool cerebras 'Cerebras free tier' CEREBRAS_API_KEY)
  g1=$(presence_pool gemini 'Gemini free tier 1' GEMINI_API_KEY)
  g2=$(presence_pool gemini 'Gemini free tier 2' GEMINI_API_KEY2)
  g3=$(presence_pool gemini 'Gemini free tier 3' GEMINI_API_KEY3)
  g4=$(presence_pool gemini 'Gemini free tier 4' GEMINI_API_KEY4)
  jq -nc --argjson groq "$groq" --argjson cerebras "$cerebras" --argjson cloudflare "$cloudflare" \
    --argjson openrouter "$openrouter" --argjson g1 "$g1" --argjson g2 "$g2" --argjson g3 "$g3" --argjson g4 "$g4" \
    '[$groq,$cerebras,$cloudflare,$openrouter,$g1,$g2,$g3,$g4]'
}

reader_array_or_fallback() {  # <raw> <fallback-json>
  if printf '%s' "$1" | jq -e 'type == "array"' >/dev/null 2>&1; then printf '%s' "$1"; else printf '%s' "$2"; fi
}

cache_fresh() {
  local modified now
  [ -s "$CACHE" ] || return 1
  jq -e 'type == "array"' "$CACHE" >/dev/null 2>&1 || return 1
  modified=$(stat -f '%m' "$CACHE" 2>/dev/null || stat -c '%Y' "$CACHE" 2>/dev/null || echo 0)
  now=$(date +%s)
  [ $((now - modified)) -lt "$CACHE_TTL" ]
}

main() {
  local claude pro team free out dir tmp fallback_claude fallback_free
  case "${1-}" in -h|--help|help) usage; return 0 ;; '') : ;; *) usage >&2; exit 2 ;; esac
  command -v jq >/dev/null 2>&1 || fail 'jq is required'
  if cache_fresh; then cat "$CACHE"; return; fi
  fallback_claude=$(jq -nc --argjson a "$(unreadable_pool claude 'Claude Max A' 'Claude account reader failed')" --argjson b "$(unreadable_pool claude 'Claude Max B' 'Claude account reader failed')" '[$a,$b]')
  claude=$(reader_array_or_fallback "$(claude_accounts 2>/dev/null || true)" "$fallback_claude")
  pro=$(gpt_pool 'ChatGPT Pro' "$PRO_AUTH")
  team=$(gpt_pool 'ChatGPT Team' "$TEAM_AUTH")
  fallback_free=$(jq -nc '[
    ["groq","Groq free tier"],["cerebras","Cerebras free tier"],["cloudflare","Cloudflare free tier"],
    ["openrouter","OpenRouter free tier"],["gemini","Gemini free tier 1"],["gemini","Gemini free tier 2"],
    ["gemini","Gemini free tier 3"],["gemini","Gemini free tier 4"]
  ] | map({provider:.[0],label:.[1],percent_remaining:null,window:"",resets_at:null,estimate:false,note:"free-tier reader failed"})')
  free=$(reader_array_or_fallback "$(free_pools 2>/dev/null || true)" "$fallback_free")
  out=$(jq -nc --argjson claude "$claude" --argjson pro "$pro" --argjson team "$team" --argjson free "$free" '$claude + [$pro,$team] + $free')
  dir=$(dirname "$CACHE")
  if mkdir -p "$dir" 2>/dev/null; then
    tmp=$(mktemp "$dir/.quota-pools.XXXXXX" 2>/dev/null || true)
    if [ -n "$tmp" ]; then printf '%s\n' "$out" > "$tmp"; chmod 600 "$tmp"; mv -f "$tmp" "$CACHE"; fi
  fi
  printf '%s\n' "$out"
}

main "$@"
