#!/usr/bin/env bash
# Inspect chrome-devtools-axi bridge processes and retire only bridges whose
# ownership is established from their current working directory.
#
# Usage: fm-chrome-bridge-sweep.sh [--apply] [--summary] [--worktree <path>]
#        fm-chrome-bridge-sweep.sh --record-owner <task-id> <worktree> <bridge-pid> <session-root> [state-dir]
#
# The default is a dry-run inventory with bridge age, owner, and disposition.
# --apply sends TERM to selected bridges and their current descendants, then
# KILL to survivors after FM_BRIDGE_TERM_GRACE_SECS (default 1).
# --worktree limits selection to bridges whose cwd is that path or below it and
# ignores age; teardown uses this while the task worktree still exists.
# Without --worktree, a bridge is selected only when its cwd no longer exists.
# Existing owners remain protected at every age; the age threshold reports them.
# --summary prints only a startup diagnostic and the exact inspect/apply commands.
# Unknown ownership is always reported and never selected.
# --record-owner atomically publishes the durable state/<task-id>.bridge-owner
# record expected by global cleanup. Session root is the owning process pid.
#
# Test seams use fixture files rather than real processes:
# FM_BRIDGE_PS_FILE has tab-separated pid, ppid, elapsed, command rows;
# FM_BRIDGE_CWD_FILE has tab-separated pid, cwd rows; and
# FM_BRIDGE_KILL_LOG records "SIGNAL pid" instead of sending signals.
set -u

if [ "${1:-}" = --watch-owner ]; then
  [ "$#" -ge 5 ] || { echo "error: --watch-owner requires task-id, worktree, state-dir, and session-root-pid" >&2; exit 2; }
  WATCH_TASK=$2
  WATCH_WORKTREE=$3
  WATCH_STATE=$4
  WATCH_SESSION_ROOT=$5
  WATCH_SELF=$$
  # Bounded three ways, because a watcher that outlives its task is exactly the
  # leak this script exists to clean up. It stops when the task record is gone
  # (teardown removes it, and a test fixture's state dir disappears with the
  # fixture), when the task worktree is gone, and at a hard deadline. The poll
  # interval is deliberately slow: each pass walks the full process table, so a
  # one-second loop across a fleet of tasks is a measurable share of the host.
  WATCH_META="$WATCH_STATE/$WATCH_TASK.meta"
  WATCH_INTERVAL=${FM_BRIDGE_WATCH_INTERVAL_SECS:-5}
  WATCH_DEADLINE=$(( $(date +%s) + ${FM_BRIDGE_WATCH_MAX_SECS:-900} ))
  command -v lsof >/dev/null 2>&1 || exit 1
  cd / || exit 1
  while [ -e "$WATCH_META" ] && [ -d "$WATCH_WORKTREE" ] \
     && [ "$(date +%s)" -lt "$WATCH_DEADLINE" ]; do
    WATCH_BRIDGE_PID=
    while IFS= read -r WATCH_ROW; do
      read -r WATCH_PID WATCH_COMMAND <<< "$WATCH_ROW"
      case "$WATCH_COMMAND" in
        node\ *chrome-devtools-axi-bridge.js*|*/node\ *chrome-devtools-axi-bridge.js*) ;;
        *) continue ;;
      esac
      WATCH_CWD=$(lsof -a -p "$WATCH_PID" -d cwd -Fn 2>/dev/null | awk '/^n/ { sub(/^n/, ""); print; exit }') || continue
      case "$WATCH_CWD" in "$WATCH_WORKTREE"|"$WATCH_WORKTREE"/*) WATCH_BRIDGE_PID=$WATCH_PID; break ;; esac
    done < <(ps -axo pid=,command= 2>/dev/null)
    if [ -n "$WATCH_BRIDGE_PID" ]; then
      "$0" --record-owner "$WATCH_TASK" "$WATCH_WORKTREE" "$WATCH_BRIDGE_PID" "$WATCH_SESSION_ROOT" "$WATCH_STATE" && exit 0
    fi
    sleep "$WATCH_INTERVAL"
  done
  exit 0
fi

if [ "${1:-}" = --record-owner ]; then
  [ "$#" -ge 5 ] || { echo "error: --record-owner requires task-id, worktree, bridge-pid, and session-root" >&2; exit 2; }
  OWNER_TASK=$2
  OWNER_WORKTREE=$3
  OWNER_BRIDGE_PID=$4
  OWNER_SESSION_ROOT=$5
  OWNER_STATE=${6:-${FM_BRIDGE_OWNER_DIR:-${FM_STATE_OVERRIDE:-${FM_HOME:-$PWD}/state}}}
  OWNER_START_TIME=${7:-${FM_BRIDGE_OWNER_START_TIME:-}}
  OWNER_COMMAND=${8:-${FM_BRIDGE_OWNER_COMMAND:-}}
  OWNER_SESSION_START_TIME=${9:-${FM_BRIDGE_OWNER_SESSION_START_TIME:-}}
  if [ -z "$OWNER_START_TIME" ]; then
    OWNER_START_TIME=$(LC_ALL=C ps -p "$OWNER_BRIDGE_PID" -o lstart= 2>/dev/null || true)
  fi
  if [ -z "$OWNER_COMMAND" ]; then
    OWNER_COMMAND=$(LC_ALL=C ps -p "$OWNER_BRIDGE_PID" -o command= 2>/dev/null || true)
  fi
  if [ -z "$OWNER_SESSION_START_TIME" ]; then
    OWNER_SESSION_START_TIME=$(LC_ALL=C ps -p "$OWNER_SESSION_ROOT" -o lstart= 2>/dev/null || true)
  fi
  [ -n "$OWNER_START_TIME" ] && [ -n "$OWNER_COMMAND" ] && [ -n "$OWNER_SESSION_START_TIME" ] || { echo "error: bridge process identity could not be captured" >&2; exit 1; }
  case "$OWNER_TASK:$OWNER_BRIDGE_PID:$OWNER_SESSION_ROOT" in
    *[!A-Za-z0-9_.:-]*) echo "error: invalid ownership record identity" >&2; exit 2 ;;
  esac
  mkdir -p "$OWNER_STATE" || exit 1
  OWNER_TMP="$OWNER_STATE/.$OWNER_TASK.bridge-owner.$$"
  if ! {
    printf 'task_id=%s\n' "$OWNER_TASK"
    printf 'worktree=%s\n' "$OWNER_WORKTREE"
    printf 'bridge_pid=%s\n' "$OWNER_BRIDGE_PID"
    printf 'session_root=%s\n' "$OWNER_SESSION_ROOT"
    printf 'session_root_start_time=%s\n' "$OWNER_SESSION_START_TIME"
    printf 'bridge_start_time=%s\n' "$OWNER_START_TIME"
    printf 'bridge_command=%s\n' "$OWNER_COMMAND"
  } > "$OWNER_TMP" || ! mv -f "$OWNER_TMP" "$OWNER_STATE/$OWNER_TASK.bridge-owner"; then
    rm -f "$OWNER_TMP"
    exit 1
  fi
  exit 0
fi

SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
APPLY=0
SUMMARY=0
WORKTREE=
MAX_HOURS=${FM_BRIDGE_MAX_AGE_HOURS:-6}
GRACE=${FM_BRIDGE_TERM_GRACE_SECS:-1}
OWNER_DIR=${FM_BRIDGE_OWNER_DIR:-${FM_STATE_OVERRIDE:-${FM_HOME:-$PWD}/state}}

usage() {
  sed -n '2,/^set -u$/p' "$0" | sed 's/^# \{0,1\}//; $d'
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    --summary) SUMMARY=1; shift ;;
    --worktree)
      [ "$#" -ge 2 ] || { echo "error: --worktree requires a path" >&2; exit 2; }
      WORKTREE=$2
      shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done
case "$MAX_HOURS" in ''|*[!0-9]*|0) echo "error: FM_BRIDGE_MAX_AGE_HOURS must be a positive integer" >&2; exit 2 ;; esac
case "$GRACE" in ''|*[!0-9]*) echo "error: FM_BRIDGE_TERM_GRACE_SECS must be a non-negative integer" >&2; exit 2 ;; esac

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-chrome-bridge-sweep.XXXXXX") || exit 1
trap 'rm -rf "$TMP_ROOT"' EXIT
PS_TABLE="$TMP_ROOT/ps"
BRIDGES="$TMP_ROOT/bridges"
SELECTED="$TMP_ROOT/selected"
IDENTITIES="$TMP_ROOT/identities"
: > "$BRIDGES"
: > "$SELECTED"
: > "$IDENTITIES"

elapsed_seconds() {  # [[dd-]hh:]mm:ss
  local value=$1 days=0 hours=0 minutes=0 seconds=0 left
  case "$value" in
    *-*) days=${value%%-*}; value=${value#*-} ;;
  esac
  case "$value" in
    *:*:*) hours=${value%%:*}; left=${value#*:}; minutes=${left%%:*}; seconds=${left#*:} ;;
    *:*) minutes=${value%%:*}; seconds=${value#*:} ;;
    *) return 1 ;;
  esac
  case "$days$hours$minutes$seconds" in ''|*[!0-9]*) return 1 ;; esac
  days=$((10#$days))
  hours=$((10#$hours))
  minutes=$((10#$minutes))
  seconds=$((10#$seconds))
  printf '%s\n' "$((days * 86400 + hours * 3600 + minutes * 60 + seconds))"
}

load_processes() {
  local raw="$TMP_ROOT/ps-raw"
  if [ -n "${FM_BRIDGE_PS_FILE:-}" ]; then
    cp "$FM_BRIDGE_PS_FILE" "$PS_TABLE"
  else
    LC_ALL=C ps -axo pid=,ppid=,etime=,command= > "$raw" || return 1
    while read -r pid ppid elapsed command; do
      printf '%s\t%s\t%s\t%s\n' "$pid" "$ppid" "$elapsed" "$command"
    done < "$raw" > "$PS_TABLE"
  fi
}

process_cwd() {  # <pid>
  local pid=$1 cwd
  if [ -n "${FM_BRIDGE_CWD_FILE:-}" ]; then
    awk -F '\t' -v pid="$pid" '$1 == pid { sub(/^[^\t]*\t/, ""); print; exit }' "$FM_BRIDGE_CWD_FILE"
    return 0
  fi
  command -v lsof >/dev/null 2>&1 || return 1
  cwd=$(lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | awk '/^n/ { sub(/^n/, ""); print; exit }') || return 1
  [ -n "$cwd" ] || return 1
  cwd=${cwd% (deleted)}
  printf '%s\n' "$cwd"
}

path_belongs_to_worktree() {  # <path> <worktree>
  case "$1" in "$2"|"$2"/*) return 0 ;; *) return 1 ;; esac
}

capture_identity() {  # <pid> <command> <cwd>
  local pid=$1 command=$2 cwd=$3 identity
  if [ -n "${FM_BRIDGE_PS_FILE:-}" ]; then
    identity=fixture
  else
    identity=$(LC_ALL=C ps -p "$pid" -o lstart= 2>/dev/null || true)
    [ -n "$identity" ] || return 1
  fi
  printf '%s\t%s\t%s\t%s\n' "$pid" "$identity" "$command" "$cwd" >> "$IDENTITIES"
}

if ! load_processes; then
  echo "error: bridge process inspection failed (inspect command: ps -axo pid=,ppid=,etime=,command=)" >&2
  exit 1
fi

owner_record_for_pid() {  # <bridge-pid>
  local bridge_pid=$1 record task_id worktree record_pid session_root session_start_time start_time bridge_command
  for record in "$OWNER_DIR"/*.bridge-owner; do
    [ -f "$record" ] || continue
    task_id=$(awk -F= '$1 == "task_id" { print substr($0, index($0, "=") + 1); exit }' "$record")
    worktree=$(awk -F= '$1 == "worktree" { print substr($0, index($0, "=") + 1); exit }' "$record")
    record_pid=$(awk -F= '$1 == "bridge_pid" { print substr($0, index($0, "=") + 1); exit }' "$record")
    session_root=$(awk -F= '$1 == "session_root" { print substr($0, index($0, "=") + 1); exit }' "$record")
    session_start_time=$(awk -F= '$1 == "session_root_start_time" { print substr($0, index($0, "=") + 1); exit }' "$record")
    start_time=$(awk -F= '$1 == "bridge_start_time" { print substr($0, index($0, "=") + 1); exit }' "$record")
    bridge_command=$(awk -F= '$1 == "bridge_command" { print substr($0, index($0, "=") + 1); exit }' "$record")
    if [ "$record_pid" = "$bridge_pid" ] && [ -n "$task_id" ] && [ -n "$worktree" ] \
       && [ -n "$session_root" ] && [ -n "$session_start_time" ] && [ -n "$start_time" ] \
       && [ -n "$bridge_command" ]; then
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$task_id" "$worktree" "$session_root" "$session_start_time" "$start_time" "$bridge_command"
      return 0
    fi
  done
  return 1
}

owner_identity_alive() {  # <pid> <start-time>
  local pid=$1 expected_start=$2 current_start
  if [ -n "${FM_BRIDGE_PS_FILE:-}" ]; then
    awk -F '\t' -v pid="$pid" '$1 == pid { found=1 } END { exit found ? 0 : 1 }' "$PS_TABLE" || return 1
    current_start=fixture
  else
    current_start=$(LC_ALL=C ps -p "$pid" -o lstart= 2>/dev/null || true)
  fi
  [ "$current_start" = "$expected_start" ]
}

bridge_identity_matches() {  # <pid> <start-time> <command>
  local pid=$1 expected_start=$2 expected_command=$3 current_start current_command
  if [ -n "${FM_BRIDGE_PS_FILE:-}" ]; then
    current_start=fixture
    current_command=$(awk -F '\t' -v pid="$pid" '$1 == pid { print substr($0, index($0, "\t") + 1); exit }' "$PS_TABLE" | cut -f3-)
  else
    current_start=$(LC_ALL=C ps -p "$pid" -o lstart= 2>/dev/null || true)
    current_command=$(LC_ALL=C ps -p "$pid" -o command= 2>/dev/null || true)
  fi
  [ "$current_start" = "$expected_start" ] && [ "$current_command" = "$expected_command" ]
}

while IFS=$'\t' read -r pid ppid elapsed command; do
  case "$pid:$ppid" in *[!0-9:]*) continue ;; esac
  case "$command" in
    node\ *chrome-devtools-axi-bridge.js*|*/node\ *chrome-devtools-axi-bridge.js*) ;;
    *) continue ;;
  esac
  cwd=$(process_cwd "$pid" 2>/dev/null || true)
  capture_identity "$pid" "$command" "${cwd:-unknown}" || true
done < "$PS_TABLE"
while IFS=$'\t' read -r pid ppid elapsed command; do
  case "$pid:$ppid" in *[!0-9:]*) continue ;; esac
  case "$command" in
    node\ *chrome-devtools-axi-bridge.js*|*/node\ *chrome-devtools-axi-bridge.js*) ;;
    *) continue ;;
  esac
  age=$(elapsed_seconds "$elapsed" 2>/dev/null || true)
  cwd=$(process_cwd "$pid" 2>/dev/null || true)
  disposition=keep
  reason=active
  if [ -n "$WORKTREE" ]; then
    if [ -z "$cwd" ]; then
      disposition=unknown
      reason=owner-unresolved
    elif path_belongs_to_worktree "$cwd" "$WORKTREE"; then
      disposition=select
      reason=task-worktree
    fi
  else
    owner_record=$(owner_record_for_pid "$pid" 2>/dev/null || true)
    if [ -z "$owner_record" ]; then
      disposition=unknown
      reason=owner-unrecorded
    else
      owner_worktree=$(printf '%s\n' "$owner_record" | cut -f2)
      owner_session_root=$(printf '%s\n' "$owner_record" | cut -f3)
      owner_session_start_time=$(printf '%s\n' "$owner_record" | cut -f4)
      owner_start_time=$(printf '%s\n' "$owner_record" | cut -f5)
      owner_command=$(printf '%s\n' "$owner_record" | cut -f6-)
      if ! bridge_identity_matches "$pid" "$owner_start_time" "$owner_command" \
         || ! path_belongs_to_worktree "$cwd" "$owner_worktree"; then
        disposition=unknown
        reason=owner-identity-mismatch
      elif owner_identity_alive "$owner_session_root" "$owner_session_start_time"; then
        reason=owner-live
      elif [ ! -e "$owner_worktree" ]; then
        disposition=select
        reason=owner-missing
      elif [ -n "$age" ] && [ "$age" -ge "$((MAX_HOURS * 3600))" ]; then
        reason=long-running
      elif [ -z "$age" ]; then
        disposition=unknown
        reason='age-unresolved'
      fi
    fi
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$pid" "$ppid" "$elapsed" "${cwd:-unknown}" "$disposition" "$reason" >> "$BRIDGES"
  [ "$disposition" = select ] && printf '%s\n' "$pid" >> "$SELECTED"
done < "$PS_TABLE"

selected_count=$(grep -c . "$SELECTED" 2>/dev/null || true)
if [ -n "${FM_BRIDGE_CANDIDATE_FILE:-}" ]; then
  visible_count=$(awk -F '\t' -v scoped="${WORKTREE:+1}" '!scoped || $5 != "keep" { n++ } END { print n + 0 }' "$BRIDGES")
  : > "$FM_BRIDGE_CANDIDATE_FILE"
  if [ "$visible_count" -gt 0 ]; then
    printf 'PID\tAGE\tOWNER\tACTION\tREASON\n' > "$FM_BRIDGE_CANDIDATE_FILE"
    awk -F '\t' -v scoped="${WORKTREE:+1}" 'BEGIN { OFS="\t" } !scoped || $5 != "keep" { action=($5 == "select" ? "would-stop" : $5); print $1, $3, $4, action, $6 }' "$BRIDGES" >> "$FM_BRIDGE_CANDIDATE_FILE"
  fi
fi
unknown_count=$(awk -F '\t' '$5 == "unknown" { n++ } END { print n + 0 }' "$BRIDGES")
long_running_count=$(awk -F '\t' '$6 == "long-running" { n++ } END { print n + 0 }' "$BRIDGES")
if [ "$SUMMARY" -eq 1 ]; then
  if [ "$selected_count" -gt 0 ]; then
    printf 'BROWSER_BRIDGES: %s orphan bridge(s), %s unknown, %s long-running and protected; inspect: %s; apply: %s --apply\n' \
      "$selected_count" "$unknown_count" "$long_running_count" "$SCRIPT_PATH" "$SCRIPT_PATH"
  else
    printf 'BROWSER_BRIDGES: 0 orphan bridges detected (%s unknown, %s long-running and protected).\n' \
      "$unknown_count" "$long_running_count"
  fi
  exit 0
fi

visible_count=$(awk -F '\t' -v scoped="${WORKTREE:+1}" '!scoped || $5 != "keep" { n++ } END { print n + 0 }' "$BRIDGES")
if [ "$visible_count" -gt 0 ]; then
  printf 'PID\tAGE\tOWNER\tACTION\tREASON\n'
  awk -F '\t' -v scoped="${WORKTREE:+1}" 'BEGIN { OFS="\t" } !scoped || $5 != "keep" { action=($5 == "select" ? (apply ? "stop" : "would-stop") : $5); print $1, $3, $4, action, $6 }' apply="$APPLY" "$BRIDGES"
fi
[ "$APPLY" -eq 1 ] || exit 0
[ "$selected_count" -gt 0 ] || exit 0

TARGETS="$TMP_ROOT/targets"
cp "$SELECTED" "$TARGETS"
while :; do
  before=$(wc -l < "$TARGETS" | tr -d ' ')
  awk -F '\t' 'NR == FNR { wanted[$1]=1; next } ($2 in wanted) { print $1 }' "$TARGETS" "$PS_TABLE" >> "$TARGETS.next"
  cat "$TARGETS" >> "$TARGETS.next"
  sort -un "$TARGETS.next" > "$TARGETS.sorted"
  mv -f "$TARGETS.sorted" "$TARGETS"
  rm -f "$TARGETS.next"
  after=$(wc -l < "$TARGETS" | tr -d ' ')
  [ "$after" -eq "$before" ] && break
done

# Descendants are discovered from the bounded process snapshot above, but their
# identities must be captured before they can be signaled.
while IFS= read -r pid; do
  awk -F '\t' -v pid="$pid" '$1 == pid { print; exit }' "$IDENTITIES" | grep -q . && continue
  process_row=$(awk -F '\t' -v pid="$pid" '$1 == pid { print; exit }' "$PS_TABLE")
  [ -n "$process_row" ] || continue
  process_command=$(printf '%s\n' "$process_row" | cut -f4-)
  process_cwd_value=$(process_cwd "$pid" 2>/dev/null || true)
  capture_identity "$pid" "$process_command" "${process_cwd_value:-unknown}" || true
done < "$TARGETS"

pid_identity_matches() {  # <pid>
  local pid=$1 expected expected_identity expected_command expected_cwd current current_command current_cwd
  expected=$(awk -F '\t' -v pid="$pid" '$1 == pid { print; exit }' "$IDENTITIES")
  [ -n "$expected" ] || return 1
  expected_identity=$(printf '%s\n' "$expected" | cut -f2)
  expected_command=$(printf '%s\n' "$expected" | cut -f3)
  expected_cwd=$(printf '%s\n' "$expected" | cut -f4-)
  if [ "$expected_identity" != fixture ]; then
    current=$(LC_ALL=C ps -p "$pid" -o lstart= 2>/dev/null || true)
    [ -n "$current" ] && [ "$current" = "$expected_identity" ] || return 1
    current_command=$(LC_ALL=C ps -p "$pid" -o command= 2>/dev/null || true)
  else
    current_command=$(awk -F '\t' -v pid="$pid" '$1 == pid { sub(/^[^\t]*\t[^\t]*\t[^\t]*\t/, ""); print; exit }' "$PS_TABLE")
  fi
  [ "$current_command" = "$expected_command" ] || return 1
  current_cwd=$(process_cwd "$pid" 2>/dev/null || true)
  [ -n "$current_cwd" ] && [ "$current_cwd" = "$expected_cwd" ] || return 1
  if [ -n "$WORKTREE" ]; then
    path_belongs_to_worktree "$current_cwd" "$WORKTREE" || return 1
  fi
}

signal_pid() {  # <signal> <pid>
  if [ -n "${FM_BRIDGE_KILL_LOG:-}" ]; then
    printf '%s %s\n' "$1" "$2" >> "$FM_BRIDGE_KILL_LOG"
  else
    kill "-$1" "$2" 2>/dev/null || true
  fi
}

while IFS= read -r pid; do
  pid_identity_matches "$pid" && signal_pid TERM "$pid"
done < "$TARGETS"
[ "$GRACE" -eq 0 ] || sleep "$GRACE"
while IFS= read -r pid; do
  if pid_identity_matches "$pid" \
     && { [ -n "${FM_BRIDGE_KILL_LOG:-}" ] || kill -0 "$pid" 2>/dev/null; }; then
    signal_pid KILL "$pid"
  fi
done < "$TARGETS"
