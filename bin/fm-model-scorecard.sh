#!/usr/bin/env bash
# fm-model-scorecard.sh - read-only per-model delivery scorecard.
#
# Tallies, per (model, effort) pair, from durable records only:
#   tasks     - completed ships and scouts, counted from each Done entry's
#               "model=<model> effort=<effort>" note (an unset value is
#               recorded as the literal "default" at spawn and teardown, see
#               bin/fm-spawn.sh and bin/fm-teardown.sh's backlog_done_args).
#   fix-rnds  - a best-effort textual count of status-log lines that mention
#               both "fix" and "round" (case-insensitive), since no worker
#               status verb marks a no-mistakes fix-review round on its own;
#               this undercounts a task whose fix rounds a status line never
#               narrated, and is never treated as an exact figure.
#   ask-user  - a count of status lines opening with the `needs-decision`
#               verb (bare, keyed, or correlated), the exact verb the
#               generated brief's Definition of done uses to escalate an
#               ask-user finding (bin/fm-dod-lib.sh, AGENTS.md section 7's
#               ask-user rule). A rare non-ask-user product decision also
#               uses this verb, so the column is a close proxy, not a
#               provably exact ask-user-only count.
#
# Sources, in the order read:
#   1. This home's data/backlog.md "## Done" section.
#   2. This home's configured Done archive (.tasks.toml's `archive` key,
#      default "data/done-archive.md"; absent file is skipped, not an error).
#   3. state/<id>.status for every id found in (1) or (2) that still has one -
#      teardown never removes this file (bin/fm-crew-state.sh), but it is not
#      guaranteed to survive indefinitely (manual cleanup, /stow, or an older
#      pruning pass may remove it), so a missing status log contributes 0 to
#      fix-rnds/ask-user for that task rather than being treated as an error.
# A secondmate's own backlog lives in its own home; run this against each
# home whose scorecard you want (FM_HOME, matching every other fm-*.sh tool).
#
# Usage: fm-model-scorecard.sh [--home <path>]
#   --home <path>  Use <path> as FM_HOME instead of the environment/default.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

while [ $# -gt 0 ]; do
  case "$1" in
    --home)
      [ $# -ge 2 ] || { echo "error: --home requires a path" >&2; exit 2; }
      FM_HOME=$2
      shift 2
      ;;
    --home=*)
      FM_HOME=${1#--home=}
      shift
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
ROOT="${DATA%/*}"
[ -n "$ROOT" ] || ROOT=/

BACKLOG="$DATA/backlog.md"
if [ ! -f "$BACKLOG" ]; then
  echo "error: no backlog at $BACKLOG" >&2
  exit 1
fi

ARCHIVE_REL="data/done-archive.md"
TOML="$ROOT/.tasks.toml"
if [ -f "$TOML" ]; then
  toml_value=$(grep -E '^[[:space:]]*archive[[:space:]]*=' "$TOML" 2>/dev/null | tail -1 \
    | sed -E 's/^[^=]*=[[:space:]]*"([^"]*)".*/\1/')
  [ -n "$toml_value" ] && ARCHIVE_REL=$toml_value
fi
ARCHIVE="$ROOT/$ARCHIVE_REL"

# Extract "<id> <model> <effort>" (space-separated) for every Done entry in
# one backlog or archive file, deriving the id from the checkbox line and the
# note from that entry's body. tasks-axi appends the close note to the END of
# the task body, so the note is the last note-shaped line among the entry's
# continuation lines (indented or blank) up to the next bullet, heading, or
# unindented line. A Done entry with no attribution note (an older row from
# before this contract, or a hand-edited one) is silently skipped: it predates
# model tracking, not a parse failure.
extract_done_ids() {
  awk '
    function flush(  model, effort) {
      if (id != "" && note != "") {
        model = note
        sub(/.*model=/, "", model)
        sub(/[[:space:]].*/, "", model)
        effort = note
        sub(/.*effort=/, "", effort)
        sub(/[[:space:]].*/, "", effort)
        if (model != "" && effort != "") print id, model, effort
      }
      id = ""
      note = ""
    }
    /^- \[[ xX]\] / {
      flush()
      if ($0 ~ /^- \[x\] [^ ]+ - /) id = $3
      next
    }
    /^[^[:space:]]/ {
      flush()
      next
    }
    id != "" && /model=[^[:space:]]+ effort=[^[:space:]]+/ {
      note = $0
      next
    }
    END { flush() }
  ' "$1"
}

TMP_ROWS=$(mktemp)
trap 'rm -f "$TMP_ROWS"' EXIT

extract_done_ids "$BACKLOG" > "$TMP_ROWS"
[ -f "$ARCHIVE" ] && extract_done_ids "$ARCHIVE" >> "$TMP_ROWS"

if [ ! -s "$TMP_ROWS" ]; then
  echo "no attributed Done tasks found in $BACKLOG${ARCHIVE:+ or $ARCHIVE}"
  exit 0
fi

# For each attributed task, add its status log's fix-round and ask-user
# proxy counts as two more fields; awk then folds every row per (model,
# effort) key, and `sort` gives the folded keys a stable order before
# rendering (awk associative-array iteration order is unspecified).
while IFS=' ' read -r id model effort; do
  status="$STATE/$id.status"
  fix_rounds=0
  ask_user=0
  if [ -f "$status" ]; then
    fix_rounds=$(grep -i 'fix' "$status" 2>/dev/null | grep -ci 'round' || true)
    ask_user=$(grep -cE '^needs-decision([[:space:]]|:)' "$status" 2>/dev/null || true)
  fi
  printf '%s\t%s\t%s\t%s\n' "$model" "$effort" "${fix_rounds:-0}" "${ask_user:-0}"
done < "$TMP_ROWS" | awk -F'\t' '
  {
    key = $1 SUBSEP $2
    tasks[key]++
    fix[key] += $3
    ask[key] += $4
  }
  END {
    for (k in tasks) {
      split(k, parts, SUBSEP)
      printf "%s\t%s\t%d\t%d\t%d\n", parts[1], parts[2], tasks[k], fix[k], ask[k]
    }
  }
' | sort | awk -F'\t' '
  BEGIN { printf "%-24s %-10s %8s %11s %10s\n", "MODEL", "EFFORT", "TASKS", "FIX-ROUNDS", "ASK-USER" }
  { printf "%-24s %-10s %8s %11s %10s\n", $1, $2, $3, $4, $5 }
'
