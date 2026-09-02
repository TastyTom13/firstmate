#!/usr/bin/env bash
# fm-usage-history.sh - render this home's token-burn history as the
# fm-bearings-board.v1 `usage` object.
#
# The board's fuel gauges answer "how much is left right now"; they cannot
# answer "how fast are we spending it" or "what spent it". Two durable records
# already hold those answers - the half-hourly quota sampler's
# data/quota-history.jsonl, and the no-mistakes pipeline's own
# agent_invocations table - and this script is the single place that reduces
# both onto the one board shape, so composing a board stays "run this, splice
# the object in" rather than re-deriving two schemas by hand every run.
#
# Usage:
#   fm-usage-history.sh
#
# Prints one compact JSON object:
#   generated   ISO 8601 instant this reduction ran
#   samples     number of quota samples read
#   since       ISO 8601 timestamp of the oldest sample read, or null
#   curves      one entry per pool window that any sample could read:
#               pool, window, label, points [{ts, percent_remaining}], and
#               resets [ts] - the instants where remaining went UP, which is
#               the only thing a window reset can look like in a sample series
#   daily       per pool window per UTC day: burn_points (percentage points
#               spent) and resets. Burn sums only the DROPS between
#               consecutive samples, so a reset inside a day adds nothing
#               instead of reading as negative burn.
#   review      pipeline review spend attributed per model, or an unavailable
#               marker with its reason:
#               available, note, daily [{date, pool, model, runs, calls,
#               fresh_input, output, cache_read}], runs [{run_id, date, pool,
#               model, rounds, calls, fresh_input, output, cache_read}]
#   notes       reader-provenance strings for anything that could not be read
#
# A review call that recorded no tokens at all spent nothing and is filtered
# out of both spend lists row by row, before grouping, so a run that died
# before its first model turn can never inflate the calls count or rounds
# figure of a group it happens to share a model with.
#
# The percentages are the providers' own reported remaining allowance; the
# token counts are the pipeline's own measured spend. They are different
# measurements of different things and the board labels them as such: a token
# on the ChatGPT Team pool costs roughly two orders of magnitude more of that
# pool than a token on Claude Max (data/quota-burn-2026-09-02.md), so the two
# token columns are never comparable across pools.
#
# Every read is best-effort and fails soft: a missing history file, a missing
# sqlite3, or an unreadable database yields an empty section carrying its
# reason, never a hard failure, because one missing panel is better than a
# board that will not build.
#
# The pipeline database is opened READ-ONLY and is never written to.
#
# FM_USAGE_HISTORY_FILE  quota sample file (default: $FM_HOME/data/quota-history.jsonl)
# FM_USAGE_HISTORY_DB    pipeline database (default: ~/.no-mistakes/state.sqlite)
# FM_USAGE_HISTORY_DAYS  how many recent days of review spend to report (default 14)
# FM_USAGE_HISTORY_RUNS  how many recent review runs to report (default 20)
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"

HISTORY="${FM_USAGE_HISTORY_FILE:-$FM_HOME/data/quota-history.jsonl}"
DB="${FM_USAGE_HISTORY_DB:-$HOME/.no-mistakes/state.sqlite}"
DAYS="${FM_USAGE_HISTORY_DAYS:-14}"
RUNS="${FM_USAGE_HISTORY_RUNS:-20}"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'fm-usage-history: %s\n' "$*" >&2
  exit 1
}

# One sample line carries two provider reports with two different shapes. This
# flattens both to the same {pool, label, id, pct} record so everything
# downstream works on one series shape and knows nothing about either schema.
# shellcheck disable=SC2016  # jq program text, not shell expansion
SAMPLE_REDUCTION='
def windows:
  [ ((.claude.providers // []) | map(select(.provider == "claude")) | first
     | (.windows // []))[]
    | select((.percentRemaining | type) == "number")
    | {pool: "claude", pool_label: "Claude", id: (.id // ""),
       label: (.label // .id // ""), pct: .percentRemaining} ]
  + [ (if (.gpt.status // "") == "known" then (.gpt.windows // []) else [] end)[]
    | select((.percentRemaining | type) == "number")
    | {pool: "openai-codex", pool_label: "ChatGPT", id: (.id // ""),
       label: (.label // .id // ""), pct: .percentRemaining} ];

# A reset is the only way remaining can rise, so burn counts drops only and a
# rise is recorded as a reset instant rather than as negative spend.
def steps($p):
  [range(1; ($p | length))
   | . as $i
   | {date: ($p[$i].ts[0:10]),
      drop: (($p[$i - 1].pct - $p[$i].pct) as $d | if $d > 0 then $d else 0 end),
      reset: ($p[$i].pct > $p[$i - 1].pct),
      ts: $p[$i].ts}];

map(select(type == "object" and (.ts | type) == "string"))
| sort_by(.ts)
| . as $samples
| [ $samples[] | .ts as $ts | windows[] | . + {ts: $ts} ]
| group_by(.pool + " " + .id)
| map(sort_by(.ts) as $p
      | (steps($p)) as $s
      | {pool: $p[0].pool, window: $p[0].id,
         label: ($p[0].pool_label + " " + $p[0].label),
         points: [$p[] | {ts: .ts, percent_remaining: .pct}],
         resets: [$s[] | select(.reset) | .ts],
         by_day: ($s | group_by(.date)
                  | map({date: .[0].date,
                         burn_points: ([.[].drop] | add | . * 100 | round / 100),
                         resets: ([.[] | select(.reset)] | length)}))})
| sort_by(.pool, .window)
| {samples: ($samples | length),
   since: ($samples[0].ts // null),
   curves: [.[] | del(.by_day)],
   daily: ([.[] | .pool as $pool | .window as $window | .label as $label
            | .by_day[] | {date: .date, pool: $pool, window: $window,
                           label: $label, burn_points: .burn_points,
                           resets: .resets}]
           | sort_by(.date, .pool, .window) | reverse)}
'

read_curves() {
  local lines
  if [ ! -f "$HISTORY" ]; then
    jq -nc --arg note "no quota samples recorded yet at $HISTORY" \
      '{samples: 0, since: null, curves: [], daily: [], note: $note}'
    return
  fi
  # A truncated or half-written final line must not lose every earlier sample,
  # so unparseable lines are dropped rather than failing the whole read.
  lines=$(jq -c . "$HISTORY" 2>/dev/null || true)
  printf '%s\n' "$lines" | jq -sc "$SAMPLE_REDUCTION" 2>/dev/null \
    || jq -nc '{samples: 0, since: null, curves: [], daily: [],
                note: "the quota sample file could not be read"}'
}

unreadable_review() {  # <note>
  jq -nc --arg note "$1" '{available: false, note: $note, daily: [], runs: []}'
}

# The pipeline attributes every agent call to a model; which pool a model
# spends from is a property of the model name, not of the harness that ran it,
# so that mapping lives here in one place.
POOL_CASE="case
  when lower(coalesce(model, '')) like 'gpt%'
    or lower(coalesce(model, '')) like 'o3%'
    or lower(coalesce(model, '')) like 'codex%' then 'openai-codex'
  when lower(coalesce(model, '')) like 'claude%'
    or lower(coalesce(model, '')) like 'opus%'
    or lower(coalesce(model, '')) like 'sonnet%'
    or lower(coalesce(model, '')) like 'haiku%'
    or lower(coalesce(model, '')) like 'fable%' then 'claude'
  else 'unknown' end"

review_spend() {
  local daily runs
  command -v sqlite3 >/dev/null 2>&1 || {
    unreadable_review "sqlite3 is not installed, so pipeline spend cannot be read"
    return
  }
  [ -f "$DB" ] || {
    unreadable_review "no pipeline database at $DB"
    return
  }
  daily=$(sqlite3 -readonly -json "$DB" "
    select date(started_at, 'unixepoch') as date,
           $POOL_CASE as pool,
           coalesce(nullif(model, ''), 'unrecorded') as model,
           count(distinct run_id) as runs,
           count(*) as calls,
           sum(coalesce(input_tokens, 0)) as fresh_input,
           sum(coalesce(output_tokens, 0)) as output,
           sum(coalesce(cache_read_tokens, 0)) as cache_read
      from agent_invocations
     where step_name = 'review'
       and coalesce(input_tokens, 0) + coalesce(output_tokens, 0)
           + coalesce(cache_read_tokens, 0) > 0
     group by date, pool, model
     order by date desc, model asc
     limit $((DAYS * 12));" 2>/dev/null) || {
    unreadable_review "the pipeline database could not be read"
    return
  }
  runs=$(sqlite3 -readonly -json "$DB" "
    select run_id,
           date(min(started_at), 'unixepoch') as date,
           $POOL_CASE as pool,
           coalesce(nullif(model, ''), 'unrecorded') as model,
           max(round) as rounds,
           count(*) as calls,
           sum(coalesce(input_tokens, 0)) as fresh_input,
           sum(coalesce(output_tokens, 0)) as output,
           sum(coalesce(cache_read_tokens, 0)) as cache_read
      from agent_invocations
     where step_name = 'review'
       and coalesce(input_tokens, 0) + coalesce(output_tokens, 0)
           + coalesce(cache_read_tokens, 0) > 0
     group by run_id, pool, model
     order by min(started_at) desc
     limit $RUNS;" 2>/dev/null) || {
    unreadable_review "the pipeline database could not be read"
    return
  }
  jq -nc --argjson daily "${daily:-[]}" --argjson runs "${runs:-[]}" \
    '{available: true, note: null, daily: $daily, runs: $runs}' 2>/dev/null \
    || unreadable_review "the pipeline database returned an unreadable report"
}

main() {
  local curves review
  case "${1-}" in
    -h|--help|help) usage; return 0 ;;
    '') : ;;
    *) usage >&2; exit 2 ;;
  esac
  command -v jq >/dev/null 2>&1 || fail "jq is required"
  curves=$(read_curves)
  review=$(review_spend)
  jq -nc --argjson curves "$curves" --argjson review "$review" \
    --arg generated "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
    {generated: $generated,
     samples: $curves.samples, since: $curves.since,
     curves: $curves.curves, daily: $curves.daily,
     review: $review,
     notes: ([$curves.note, (if $review.available then null else $review.note end)]
             | map(select(. != null)))}'
}

main "$@"
