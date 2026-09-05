#!/usr/bin/env bash
# Inspect chrome-devtools-axi bridge processes and retire only bridges whose
# ownership is established from their current working directory.
#
# Usage: fm-chrome-bridge-sweep.sh [--apply] [--summary] [--worktree <path>]
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
#
# Test seams use fixture files rather than real processes:
# FM_BRIDGE_PS_FILE has tab-separated pid, ppid, elapsed, command rows;
# FM_BRIDGE_CWD_FILE has tab-separated pid, cwd rows; and
# FM_BRIDGE_KILL_LOG records "SIGNAL pid" instead of sending signals.
set -u

SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
APPLY=0
SUMMARY=0
WORKTREE=
MAX_HOURS=${FM_BRIDGE_MAX_AGE_HOURS:-6}
GRACE=${FM_BRIDGE_TERM_GRACE_SECS:-1}

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
  if [ -n "${FM_BRIDGE_PS_FILE:-}" ]; then
    cp "$FM_BRIDGE_PS_FILE" "$PS_TABLE"
  else
    LC_ALL=C ps -axo pid=,ppid=,etime=,command= | while read -r pid ppid elapsed command; do
      printf '%s\t%s\t%s\t%s\n' "$pid" "$ppid" "$elapsed" "$command"
    done > "$PS_TABLE"
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

owner_process_tree_dead() {  # <pid>
  local pid=$1 parent row first=1
  while :; do
    parent=$(awk -F '\t' -v pid="$pid" '$1 == pid { print $2; exit }' "$PS_TABLE")
    case "$parent" in
      1) [ "$first" -eq 1 ] && return 0 || return 1 ;;
      ''|*[!0-9]*) return 1 ;;
    esac
    row=$(awk -F '\t' -v pid="$parent" '$1 == pid { print; exit }' "$PS_TABLE")
    [ -n "$row" ] || return 0
    first=0
    pid=$parent
  done
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

load_processes
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
  if [ -z "$cwd" ]; then
    disposition=unknown
    reason=owner-unresolved
  elif [ -n "$WORKTREE" ]; then
    if path_belongs_to_worktree "$cwd" "$WORKTREE"; then
      disposition=select
      reason=task-worktree
    fi
  elif [ ! -e "$cwd" ]; then
    disposition=select
    reason=owner-missing
  elif owner_process_tree_dead "$pid"; then
    disposition=select
    reason=owner-dead
  elif [ -n "$age" ] && [ "$age" -ge "$((MAX_HOURS * 3600))" ]; then
    reason=long-running
  elif [ -z "$age" ]; then
    disposition=unknown
    reason='age-unresolved'
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$pid" "$ppid" "$elapsed" "${cwd:-unknown}" "$disposition" "$reason" >> "$BRIDGES"
  [ "$disposition" = select ] && printf '%s\n' "$pid" >> "$SELECTED"
done < "$PS_TABLE"

selected_count=$(grep -c . "$SELECTED" 2>/dev/null || true)
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
  sort -un "$TARGETS.next" > "$TARGETS"
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
