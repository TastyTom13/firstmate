#!/usr/bin/env bash
# fm-validation-restart-resume.sh - resume workers whose no-mistakes run ended
# only because the shared validation daemon restarted.
#
# Scans this home's recorded in-flight no-mistakes ships and steers a worker only
# when every part of the restart signature is positive: its local worktree is
# present, its recorded endpoint still has a live agent, and `axi status` for the
# worktree's current branch reports status=failed, outcome=failed, and the exact
# daemon-owned error `daemon shutting down`. A parked review gate, an ordinary
# step/agent failure, an unreadable endpoint, and every other ambiguous shape are
# ignored rather than guessed.
#
# The steer tells the worker to invoke /no-mistakes again and follow the current
# gate help. A receipt binds the task's preserved worktree to the failed run id,
# and the exact message is also recognized in the task's durable inbox, so a repeated
# scan - including one after interruption between enqueue and receipt write -
# never sends a second steer for the same restart episode.
#
# Output: one resumed task id per line; no output when nothing was resumed.
# Exit nonzero only when a qualifying task could not be steered or recorded.
# Called by fm-session-start.sh on a full locked start and by fm-watch.sh on its
# existing slow-check cadence. It never starts, stops, or restarts the shared
# validation daemon.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
NM_TIMEOUT=${FM_VALIDATION_RESTART_NM_TIMEOUT:-10}
SEND_BIN=${FM_VALIDATION_RESTART_SEND_BIN:-$SCRIPT_DIR/fm-send.sh}
ENDPOINT_STATE_BIN=${FM_VALIDATION_RESTART_ENDPOINT_STATE_BIN:-}

case "$NM_TIMEOUT" in ''|*[!0-9]*|0) NM_TIMEOUT=10 ;; esac
[ -d "$STATE" ] || exit 0

# shellcheck source=bin/fm-task-inbox-lib.sh
. "$SCRIPT_DIR/fm-task-inbox-lib.sh"
# shellcheck source=bin/fm-nm-run-lib.sh
. "$SCRIPT_DIR/fm-nm-run-lib.sh"

LOCK="$STATE/.validation-restart-resume.lock"
if ! fm_lock_acquire_wait_bounded "$LOCK" 5; then
  # Another session-start or watcher scan owns the same reconciliation. It will
  # either publish the receipt or leave the episode eligible for the next scan.
  exit 0
fi
trap 'fm_lock_release "$LOCK" || true' EXIT

meta_value() {  # <meta-file> <key>
  fm_meta_get "$1" "$2"
}

endpoint_agent_state() {  # <meta-file> <task-id>
  local meta=$1 id=$2 backend target
  if [ -n "$ENDPOINT_STATE_BIN" ]; then
    "$ENDPOINT_STATE_BIN" "$meta" "$id"
    return
  fi
  backend=$(fm_backend_of_meta "$meta")
  target=$(fm_backend_target_of_meta "$meta")
  [ -n "$target" ] || return 1
  fm_backend_agent_state "$backend" "$target" 2>/dev/null
}

restart_message() {  # <run-id>
  printf 'The validation daemon restarted and ended no-mistakes run %s with "daemon shutting down". Resume validation now by invoking /no-mistakes again, then follow the current axi gate help until the PR is ready. This restart is not a code failure.' "$1"
}

receipt_matches() {  # <receipt> <worktree> <run-id>
  local receipt=$1 worktree=$2 run_id=$3 version recorded_worktree recorded_run extra
  [ -f "$receipt" ] && [ ! -L "$receipt" ] || return 1
  IFS= read -r version < "$receipt" || return 1
  recorded_worktree=$(sed -n 's/^worktree=//p' "$receipt" 2>/dev/null | head -1)
  recorded_run=$(sed -n 's/^run=//p' "$receipt" 2>/dev/null | head -1)
  extra=$(sed -n '4p' "$receipt" 2>/dev/null || true)
  [ "$version" = v1 ] && [ "$recorded_worktree" = "$worktree" ] \
    && [ "$recorded_run" = "$run_id" ] && [ -z "$extra" ]
}

message_recorded() {  # <task-id> <message>
  local id=$1 message=$2 dir f body
  dir=$(fm_task_inbox_dir "$STATE" "$id")
  for f in "$dir"/*.msg "$dir/handled"/*.msg; do
    [ -e "$f" ] || continue
    body=$(fm_task_inbox_body "$f" 2>/dev/null) || {
      case "$f" in
        "$dir"/*.msg)
          f="$dir/handled/${f##*/}"
          body=$(fm_task_inbox_body "$f" 2>/dev/null) || continue
          ;;
        *) continue ;;
      esac
    }
    [ "$body" = "$message" ] && return 0
  done
  return 1
}

write_receipt() {  # <receipt> <worktree> <run-id>
  local receipt=$1 worktree=$2 run_id=$3 tmp
  [ ! -L "$receipt" ] || return 1
  tmp=$(mktemp "$STATE/.validation-restart-resume.XXXXXX") || return 1
  if printf 'v1\nworktree=%s\nrun=%s\n' "$worktree" "$run_id" > "$tmp" \
    && mv -f "$tmp" "$receipt"; then
    return 0
  fi
  rm -f "$tmp"
  return 1
}

status_field() {  # <status-output> <field>
  fm_nm_strip_quotes "$(fm_nm_field "$1" "$2")"
}

scan_status_is_restart() {  # <worktree> <branch>; sets RESTART_RUN_ID
  local wt=$1 branch=$2 out status outcome error run_branch run_head
  RESTART_RUN_ID=
  out=$(fm_nm_run_checked "$wt" "$NM_TIMEOUT" axi status) || return 1
  status=$(status_field "$out" status)
  outcome=$(status_field "$out" outcome)
  error=$(status_field "$out" error)
  run_branch=$(status_field "$out" branch)
  run_head=$(status_field "$out" head_sha)
  [ -n "$run_head" ] || run_head=$(status_field "$out" head)
  RESTART_RUN_ID=$(status_field "$out" id)
  [ "$status" = failed ] && [ "$outcome" = failed ] \
    && [ "$error" = 'daemon shutting down' ] \
    && [ "$run_branch" = "$branch" ] && [ -n "$RESTART_RUN_ID" ] \
    && fm_nm_head_matches_worktree "$wt" "$run_head" \
    || { RESTART_RUN_ID=; return 1; }
  case "$RESTART_RUN_ID" in *[[:space:]]*) RESTART_RUN_ID=; return 1 ;; esac
  return 0
}

result=0
for meta in "$STATE"/*.meta; do
  [ -f "$meta" ] && [ ! -L "$meta" ] || continue
  id=${meta##*/}
  id=${id%.meta}
  case "$id" in ''|*[!A-Za-z0-9._-]*) continue ;; esac
  [ "$(meta_value "$meta" kind)" = ship ] || continue
  [ "$(meta_value "$meta" mode)" = no-mistakes ] || continue
  [ -z "$(meta_value "$meta" remote_host)" ] || continue
  wt=$(meta_value "$meta" worktree)
  [ -n "$wt" ] && [ -d "$wt" ] || continue
  branch=$(git -C "$wt" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  [ -n "$branch" ] || continue
  [ "$(endpoint_agent_state "$meta" "$id" 2>/dev/null || true)" = alive ] || continue
  scan_status_is_restart "$wt" "$branch" || continue

  receipt="$STATE/.validation-restart-resume-$id"
  receipt_matches "$receipt" "$wt" "$RESTART_RUN_ID" && continue
  [ ! -L "$receipt" ] || {
    printf 'fm-validation-restart-resume: refusing symlink receipt for %s\n' "$id" >&2
    result=1
    continue
  }
  message=$(restart_message "$RESTART_RUN_ID")
  if message_recorded "$id" "$message"; then
    write_receipt "$receipt" "$wt" "$RESTART_RUN_ID" || result=1
    continue
  fi
  send_err=$(mktemp "$STATE/.validation-restart-send.XXXXXX") || {
    printf 'fm-validation-restart-resume: cannot create send diagnostic for %s\n' "$id" >&2
    result=1
    continue
  }
  if ! FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SEND_BIN" "$id" "$message" \
    >/dev/null 2> "$send_err"; then
    cat "$send_err" >&2
    rm -f "$send_err"
    printf 'fm-validation-restart-resume: steer failed for %s run %s\n' "$id" "$RESTART_RUN_ID" >&2
    result=1
    continue
  fi
  rm -f "$send_err"
  if ! write_receipt "$receipt" "$wt" "$RESTART_RUN_ID"; then
    printf 'fm-validation-restart-resume: receipt write failed for %s run %s\n' "$id" "$RESTART_RUN_ID" >&2
    result=1
    continue
  fi
  printf '%s\n' "$id"
done

exit "$result"
