#!/usr/bin/env bash
# Context-budget estimator and once-per-step nudge throttle.
#
# The captain's 2026-09-09 ruling on token burn: firstmate should suggest /stow
# plus a fresh session, or compaction, at a low-disruption moment once the
# session passes about 40 percent of its context, rather than running a session
# until it drops a full context window. This script owns the measurement and the
# throttle; it never speaks to the session itself. The ONE surface that prints
# the suggestion is the Claude Stop turn-end guard (bin/fm-turnend-guard.sh,
# docs/turnend-guard.md), which calls this script in --nudge mode. Do not add a
# second printing surface.
#
# Measurement. A Claude primary keeps its own transcript as a JSON-lines file
# under ~/.claude/projects/<slugged-cwd>/<session-id>.jsonl, and every assistant
# record carries the usage counters for that request. The newest such record's
# input_tokens + cache_read_input_tokens + cache_creation_input_tokens +
# output_tokens is the size of the context that request actually carried, so it
# is the estimate used whenever jq can read one. The script scans the tail first
# and widens to the full transcript only when that tail has no usage record. This
# bounds ordinary Stop-hook cost while preserving the newest usage record. With
# jq absent, or with no readable usage record in the full transcript, the fallback
# estimate is transcript bytes / 4 - deliberately coarse, and an overestimate on
# a session whose transcript is longer than its live context.
#
# Modes.
#   (default)  print one line: the estimated percentage and the verdict.
#   --percent  print the integer percentage only.
#   --nudge    throttle mode for the turn-end guard: print the same one line and
#              exit 0 only when this session has crossed into a NEW 20 percent
#              step at or above 40 percent, or upgraded its verdict band;
#              otherwise print nothing and exit 1.
#
# Verdicts follow the ruling's bands: under 40 percent is quiet, 40 to 60
# percent suggests /stow at the next quiet moment, and over 60 percent suggests
# /stow now.
#
# Throttle record. --nudge keeps state/.context-budget-nudged as one line,
# "<session-id> <step> <band>", where step is percent/20 and band is quiet,
# next, or now. A step is announced at most once, except that an upward band
# change is announced once, a different session id resets the count, and a step
# BELOW the recorded one (the session was compacted, so its context shrank)
# rewrites the record down and stays silent, so the next real crossing announces
# again.
#
# Exit status: 0 printed a line, 1 nothing to say or nothing measurable. This
# script never blocks and never writes outside the state directory.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

NUDGE_RECORD="$STATE/.context-budget-nudged"
NUDGE_LOCK="$STATE/.context-budget-nudged.lock"
TAIL_LINES=${FM_CONTEXT_TAIL_LINES:-400}
case "$TAIL_LINES" in ''|*[!0-9]*|0) TAIL_LINES=400 ;; esac
WINDOW=${FM_CONTEXT_WINDOW:-200000}
case "$WINDOW" in ''|*[!0-9]*|0) WINDOW=200000 ;; esac

TRANSCRIPT=${FM_CONTEXT_TRANSCRIPT:-}
SESSION_ID=
MODE=line

usage() {
  cat <<'USAGE'
usage: fm-context-budget.sh [--transcript <path>] [--window <tokens>]
                            [--session <id>] [--percent | --nudge]

Estimates how full the current Claude session's context is and prints one
verdict line. --nudge applies the once-per-20-percent-step throttle used by the
Claude Stop turn-end guard and exits 1 when there is nothing new to say.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --transcript) TRANSCRIPT=${2:-}; shift 2 || true ;;
    --window) WINDOW=${2:-}; shift 2 || true ;;
    --session) SESSION_ID=${2:-}; shift 2 || true ;;
    --percent) MODE=percent; shift ;;
    --nudge) MODE=nudge; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done
case "$WINDOW" in ''|*[!0-9]*|0) WINDOW=200000 ;; esac

# Claude slugs the working directory into a projects subdirectory by replacing
# every "/" and "." with "-". Auto-detection is a convenience for a hand-run
# command; the turn-end guard always passes the payload's own transcript_path.
locate_transcript() {
  local base slug dir newest
  base=${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}
  [ -d "$base" ] || return 1
  slug=$(printf '%s' "$PWD" | tr '/.' '--')
  dir="$base/$slug"
  [ -d "$dir" ] || return 1
  [ -n "$(find "$dir" -maxdepth 1 -name '*.jsonl' -type f -print -quit 2>/dev/null)" ] || return 1
  newest=$(find "$dir" -maxdepth 1 -name '*.jsonl' -type f -print0 2>/dev/null \
    | xargs -0 ls -t 2>/dev/null | head -n 1)
  [ -n "$newest" ] || return 1
  printf '%s\n' "$newest"
}

# Newest usage-bearing record in the tail window, or the full file when asked.
tokens_from_usage() {
  local file=$1 scope=${2:-tail} value
  command -v jq >/dev/null 2>&1 || return 1
  if [ "$scope" = full ]; then
    value=$(jq -Rrs '
      [ split("\n")[]
        | fromjson?
        | .message?.usage?
        | select(type == "object")
        | ((.input_tokens // 0) + (.cache_read_input_tokens // 0)
           + (.cache_creation_input_tokens // 0) + (.output_tokens // 0))
        | select(. > 0) ]
      | last // empty
    ' < "$file" 2>/dev/null) || return 1
  else
    value=$(tail -n "$TAIL_LINES" "$file" 2>/dev/null | jq -Rrs '
      [ split("\n")[]
        | fromjson?
        | .message?.usage?
        | select(type == "object")
        | ((.input_tokens // 0) + (.cache_read_input_tokens // 0)
           + (.cache_creation_input_tokens // 0) + (.output_tokens // 0))
        | select(. > 0) ]
      | last // empty
    ' 2>/dev/null) || return 1
  fi
  case "$value" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$value"
}

tokens_from_bytes() {
  local file=$1 bytes
  bytes=$(wc -c < "$file" 2>/dev/null | tr -d ' ')
  case "$bytes" in ''|*[!0-9]*|0) return 1 ;; esac
  printf '%s\n' $((bytes / 4))
}

verdict_for() {  # <percent>
  if [ "$1" -lt 40 ]; then
    printf '%s\n' 'quiet'
  elif [ "$1" -le 60 ]; then
    printf '%s\n' 'suggest /stow at the next quiet moment'
  else
    printf '%s\n' 'suggest /stow now'
  fi
}

# One line = "<session-id> <step> <band>". A record whose session id does not
# match the current one counts as no step announced yet.
recorded_state() {  # <session-id>
  local want=$1 line have_session have_step have_band
  line=$(head -n 1 "$NUDGE_RECORD" 2>/dev/null || true)
  [ -n "$line" ] || { printf '0 quiet\n'; return 0; }
  read -r have_session have_step have_band <<EOF
$line
EOF
  case "$have_step" in ''|*[!0-9]*) printf '0 quiet\n'; return 0 ;; esac
  [ "$have_session" = "$want" ] || { printf '0 quiet\n'; return 0; }
  case "$have_band" in quiet|next|now) ;; *) have_band=next ;; esac
  printf '%s %s\n' "$have_step" "$have_band"
}

state_is_writable() {
  local mode
  [ -d "$STATE" ] || return 1
  mode=$(stat -f %Lp "$STATE" 2>/dev/null || stat -c %a "$STATE" 2>/dev/null) || return 1
  case "$mode" in
    *[2367]*) ;;
    *) return 1 ;;
  esac
  return 0
}

write_step() {  # <session-id> <step> <band>
  local tmp
  [ -d "$STATE" ] || return 1
  tmp=$(mktemp "$NUDGE_RECORD.XXXXXX" 2>/dev/null) || return 1
  printf '%s %s %s\n' "$1" "$2" "$3" > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
  if mv -f "$tmp" "$NUDGE_RECORD" 2>/dev/null; then
    return 0
  fi
  rm -f "$tmp"
  return 1
}

[ -n "$TRANSCRIPT" ] || TRANSCRIPT=$(locate_transcript || true)
[ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ] || exit 1

TOKENS=$(tokens_from_usage "$TRANSCRIPT" \
  || tokens_from_usage "$TRANSCRIPT" full \
  || tokens_from_bytes "$TRANSCRIPT" || true)
case "$TOKENS" in ''|*[!0-9]*) exit 1 ;; esac

PERCENT=$((TOKENS * 100 / WINDOW))

if [ "$MODE" = percent ]; then
  printf '%s\n' "$PERCENT"
  exit 0
fi

LINE="context $PERCENT% of $WINDOW tokens - $(verdict_for "$PERCENT")"

if [ "$MODE" = line ]; then
  printf '%s\n' "$LINE"
  exit 0
fi

# --nudge
[ -n "$SESSION_ID" ] || SESSION_ID=unknown
STEP=$((PERCENT / 20))
BAND=$(verdict_for "$PERCENT")
case "$BAND" in
  quiet) BAND=quiet ;;
  'suggest /stow at the next quiet moment') BAND=next ;;
  *) BAND=now ;;
esac
. "$SCRIPT_DIR/fm-wake-lib.sh"
state_is_writable || exit 1
fm_lock_try_acquire "$NUDGE_LOCK" || exit 1
read -r LAST LAST_BAND <<EOF
$(recorded_state "$SESSION_ID")
EOF
if [ "$STEP" -lt "$LAST" ]; then
  write_step "$SESSION_ID" "$STEP" "$BAND" || true
  fm_lock_release "$NUDGE_LOCK"
  exit 1
fi
if [ "$PERCENT" -lt 40 ] || { [ "$STEP" -le "$LAST" ] && [ "$BAND" != now -o "$LAST_BAND" = now ]; }; then
  fm_lock_release "$NUDGE_LOCK"
  exit 1
fi
if ! write_step "$SESSION_ID" "$STEP" "$BAND"; then
  fm_lock_release "$NUDGE_LOCK"
  exit 1
fi
fm_lock_release "$NUDGE_LOCK"
printf '%s\n' "$LINE"
exit 0
