#!/usr/bin/env bash
# Record that a live ship or scout task has no follow-ups.
# A task's follow-ups are work its worker found but did not do. The worker
# writes them one per line to data/<task-id>/follow-ups.md, and
# bin/fm-teardown.sh files each line as a backlog item before cleanup and
# refuses until that record or this explicit escape exists. Either the worker
# or firstmate runs this command; it appends `followups=none` to the task's own
# state/<task-id>.meta under that record's lock, so the escape lives in the task
# record teardown reads, not in a file that could be mistaken for a list.
# It never creates a task record: a task with no meta is refused.
# Usage: fm-followups.sh <task-id> --none
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

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

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

if [ "$#" -ne 2 ] || [ "$2" != --none ] || ! fm_task_id_path_safe "$1"; then
  echo "usage: fm-followups.sh <task-id> --none" >&2
  exit 2
fi
ID=$1
META="$STATE/$ID.meta"
[ -f "$META" ] && [ ! -L "$META" ] || {
  echo "error: task $ID has no task record at $META; --none applies only to a live task" >&2
  exit 1
}

META_LOCK=$(fm_meta_lock_path "$META") || exit 1
fm_lock_acquire_wait "$META_LOCK"
trap 'fm_lock_release "$META_LOCK" || true' EXIT
[ -f "$META" ] && [ ! -L "$META" ] || {
  echo "error: task $ID's record disappeared before --none could be recorded" >&2
  exit 1
}
if [ -s "$META" ] && [ -n "$(tail -c 1 -- "$META")" ]; then
  printf '\n' >> "$META"
fi
printf 'followups=none\n' >> "$META"
echo "recorded: task $ID has no follow-ups"
