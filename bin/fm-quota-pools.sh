#!/usr/bin/env bash
# fm-quota-pools.sh - render this home's provider quota pools as the
# fm-bearings-board.v1 `pools` array.
#
# The bearings board carries an always-visible usage gauge so the captain can
# see how much of each subscription is left without asking. Two different
# readers answer that question - quota-axi for the Claude pool, and
# bin/fm-gpt-quota.sh for the ChatGPT/Codex pool, whose usage quota-axi cannot
# read on an OAuth-only home. This script is the single place that knows how to
# map both of them onto the one board shape, so composing a board stays
# "run this, splice the array in" instead of re-deriving two provider schemas
# by hand at every invocation.
#
# Usage:
#   fm-quota-pools.sh
#
# Prints one compact JSON array. Each element is:
#   provider          slug of the reader's provider (claude, openai-codex)
#   label             captain-facing pool name
#   percent_remaining number 0-100, or null when the pool is unreadable
#   window            the limiting window in plain words ("week", "30 day")
#   resets_at         ISO 8601 reset instant, or null
#   estimate          true only when the number measures something other than
#                     the provider's own enforced allowance
#   note              why an unreadable pool is unreadable, else null
#
# A pool that cannot be read is reported with a null percent and a note, never
# omitted and never guessed, so a missing gauge always says why. Both readers
# are optional: a home without quota-axi, or without a ChatGPT credential,
# still gets a valid array with that pool marked unreadable.
#
# FM_QUOTA_POOLS_GPT  path to the ChatGPT reader (default: fm-gpt-quota.sh
#                     beside this script). Tests only.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GPT_READER="${FM_QUOTA_POOLS_GPT:-$SCRIPT_DIR/fm-gpt-quota.sh}"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'fm-quota-pools: %s\n' "$*" >&2
  exit 1
}

unreadable_pool() {  # <provider> <label> <note>
  jq -nc --arg provider "$1" --arg label "$2" --arg note "$3" '{
    provider: $provider, label: $label, percent_remaining: null,
    window: "", resets_at: null, estimate: false, note: $note
  }'
}

# Both readers hand over a percentage this script did not compute. The board
# rejects a payload whose pool percent falls outside 0-100, and a whole board
# build failing is worse than one gauge missing, so a figure that cannot be a
# remaining percentage is reported as unreadable here instead.
# shellcheck disable=SC2016  # jq program text, not shell expansion
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

# quota-axi already reduces every Claude window to one effective figure; the
# limiting window id is what names it and dates its reset.
claude_pool() {
  local raw
  command -v quota-axi >/dev/null 2>&1 || {
    unreadable_pool claude Claude "quota-axi is not installed"
    return
  }
  raw=$(quota-axi --json 2>/dev/null </dev/null) || {
    unreadable_pool claude Claude "quota-axi could not report"
    return
  }
  printf '%s' "$raw" | jq -c "$POOL_SHAPE"'
    (.providers // [] | map(select(.provider == "claude")) | first) as $p
    | ($p.quotaSemantics.effectiveAvailability // []
       | map(select(.scope == "all_models" and .status == "known")) | first) as $a
    | if $a == null then
        {provider: "claude", label: "Claude", percent_remaining: null,
         window: "", resets_at: null, estimate: false,
         note: "quota-axi reports no readable Claude window"}
      else
        ($a.limitingWindowIds // [] | first) as $wid
        | (($p.windows // []) | map(select(.id == $wid)) | first) as $w
        | pool("claude"; "Claude"; ($a.effectivePercentRemaining);
               ($w.label // $wid // ""); ($w.resetsAt // null); false)
      end
  ' 2>/dev/null || unreadable_pool claude Claude "quota-axi returned an unreadable report"
}

gpt_pool() {
  local raw
  [ -x "$GPT_READER" ] || {
    unreadable_pool openai-codex ChatGPT "the ChatGPT reader is not available"
    return
  }
  raw=$("$GPT_READER" --json 2>/dev/null </dev/null) || {
    unreadable_pool openai-codex ChatGPT "the ChatGPT reader could not report"
    return
  }
  printf '%s' "$raw" | jq -c "$POOL_SHAPE"'
    if .status == "known" and .limiting != null then
      pool("openai-codex"; "ChatGPT"; (.limiting.percentRemaining);
           (.limiting.label // ""); (.limiting.resetsAt // null);
           (.estimate == true))
    else
      {provider: "openai-codex", label: "ChatGPT", percent_remaining: null,
       window: "", resets_at: null, estimate: false,
       note: (.detail // "the ChatGPT quota could not be read")}
    end
  ' 2>/dev/null || unreadable_pool openai-codex ChatGPT "the ChatGPT reader returned an unreadable report"
}

# A reader that prints nothing at all is as unreadable as one that fails, so
# both collapse to the same reported pool rather than breaking the array.
or_unreadable() {  # <pool-json> <provider> <label> <note>
  if printf '%s' "$1" | jq -e 'type == "object"' >/dev/null 2>&1; then
    printf '%s' "$1"
  else
    unreadable_pool "$2" "$3" "$4"
  fi
}

main() {
  local claude gpt
  case "${1-}" in
    -h|--help|help) usage; return 0 ;;
    '') : ;;
    *) usage >&2; exit 2 ;;
  esac
  command -v jq >/dev/null 2>&1 || fail "jq is required"
  claude=$(or_unreadable "$(claude_pool)" claude Claude \
    "quota-axi returned an unreadable report")
  gpt=$(or_unreadable "$(gpt_pool)" openai-codex ChatGPT \
    "the ChatGPT reader returned an unreadable report")
  jq -nc --argjson claude "$claude" --argjson gpt "$gpt" '[$claude, $gpt]'
}

main "$@"
