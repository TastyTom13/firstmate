#!/usr/bin/env bash
# fm-memory-check.sh - warn before the host runs out of memory.
#
# Usage:
#   fm-memory-check.sh [check]
#   fm-memory-check.sh arm
#   fm-memory-check.sh disarm
#   fm-memory-check.sh --help
#
# `check` reads free memory from vm_stat (pages free plus pages speculative,
# times the page size vm_stat prints) and the system-wide free percentage from
# memory_pressure. It prints one line after free memory is below
# FREE_GB_THRESHOLD gigabytes (default 6) or the free percentage is below
# FREE_PERCENT_THRESHOLD (default 12) for CONSECUTIVE_POLLS polls (default 2).
# That line names the free gigabytes, the free percentage, and the five
# processes with the most resident memory (ps -axo rss=,comm=, command basename
# only). It stays silent otherwise and reports an unchanged low-memory episode
# only once; a clear poll starts a new episode. A missing, hung, or unreadable
# vm_stat or memory_pressure leaves the detector blind, so it is reported as
# "cannot measure", and a configuration problem as "failed"; an unchanged
# problem is also reported only once. The check only measures and wakes: it
# never stops processes or services and never pauses dispatch.
#
# The optional local config/memory-check file accepts only these lines:
#   FREE_GB_THRESHOLD=<whole number from 1 to 1000>
#   FREE_PERCENT_THRESHOLD=<whole number from 0 to 100>
#   CONSECUTIVE_POLLS=<whole number from 1 to 100>
# Blank lines and lines beginning with # are ignored. Unknown keys, duplicates,
# and malformed values are reported, never silently defaulted.
#
# Every probe is hard-bounded and the whole probe budget is kept below
# FM_CHECK_TIMEOUT. `arm` atomically writes state/memory.check.sh with mode 0700
# and binds its bytes through fm-check-register.sh. `disarm` unregisters it and
# removes the private poll record state/.memory-check.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/memory-check"
CHECK_ID=memory
CHECK_SHIM="$STATE/$CHECK_ID.check.sh"
RECORD="$STATE/.memory-check"
REGISTER_BIN="$SCRIPT_DIR/fm-check-register.sh"
UNREGISTER_BIN="$SCRIPT_DIR/fm-check-unregister.sh"
RECORD_SCHEMA=fm-memory-check-v1
GIB=1073741824

# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"

usage() {
  cat <<'EOF'
Usage:
  fm-memory-check.sh [check]   measure free host memory and report a low-memory episode
  fm-memory-check.sh arm       write and register state/memory.check.sh
  fm-memory-check.sh disarm    unregister the check and remove its poll record
  fm-memory-check.sh --help    print this help

Optional thresholds live in config/memory-check.
See docs/configuration.md for the schema.
EOF
}

die_usage() {
  printf 'fm-memory-check: %s\n' "$1" >&2
  usage >&2
  exit 2
}

FREE_GB_THRESHOLD=6
FREE_PERCENT_THRESHOLD=12
CONSECUTIVE_POLLS=2
CONFIG_PROBLEM=

config_validate_value() { # <key> <value>
  local key=$1 value=$2 min max
  case "$key" in
    FREE_GB_THRESHOLD) min=1; max=1000 ;;
    FREE_PERCENT_THRESHOLD) min=0; max=100 ;;
    CONSECUTIVE_POLLS) min=1; max=100 ;;
    *) return 1 ;;
  esac
  case "$value" in ''|*[!0-9]*) return 1 ;; esac
  # Reject leading zeros so a value is never read as octal or as a long string.
  case "$value" in 0?*) return 1 ;; esac
  [ "${#value}" -le 4 ] && [ "$value" -ge "$min" ] && [ "$value" -le "$max" ]
}

config_load() {
  local line key value seen_gb=0 seen_percent=0 seen_polls=0
  FREE_GB_THRESHOLD=6
  FREE_PERCENT_THRESHOLD=12
  CONSECUTIVE_POLLS=2
  CONFIG_PROBLEM=
  [ -e "$CONFIG" ] || return 0
  if [ ! -f "$CONFIG" ] || [ -L "$CONFIG" ] || [ ! -r "$CONFIG" ]; then
    CONFIG_PROBLEM='config/memory-check is not a readable regular file'
    return 1
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    key=${line%%=*}
    if [ "$key" = "$line" ]; then
      CONFIG_PROBLEM='config/memory-check has a malformed line'
      return 1
    fi
    value=${line#*=}
    case "$key" in
      FREE_GB_THRESHOLD)
        if [ "$seen_gb" -eq 1 ] || ! config_validate_value "$key" "$value"; then
          CONFIG_PROBLEM='FREE_GB_THRESHOLD must appear once at most and be a whole number from 1 to 1000'
          return 1
        fi
        seen_gb=1
        FREE_GB_THRESHOLD=$value
        ;;
      FREE_PERCENT_THRESHOLD)
        if [ "$seen_percent" -eq 1 ] || ! config_validate_value "$key" "$value"; then
          CONFIG_PROBLEM='FREE_PERCENT_THRESHOLD must appear once at most and be a whole number from 0 to 100'
          return 1
        fi
        seen_percent=1
        FREE_PERCENT_THRESHOLD=$value
        ;;
      CONSECUTIVE_POLLS)
        if [ "$seen_polls" -eq 1 ] || ! config_validate_value "$key" "$value"; then
          CONFIG_PROBLEM='CONSECUTIVE_POLLS must appear once at most and be a whole number from 1 to 100'
          return 1
        fi
        seen_polls=1
        CONSECUTIVE_POLLS=$value
        ;;
      *)
        CONFIG_PROBLEM='config/memory-check has an unknown key'
        return 1
        ;;
    esac
  done < "$CONFIG"
  return 0
}

CHECK_TIMEOUT=${FM_CHECK_TIMEOUT:-30}
case "$CHECK_TIMEOUT" in ''|*[!0-9]*|0) CHECK_TIMEOUT=30 ;; esac
TIMEOUT_PROBLEM=
[ "$CHECK_TIMEOUT" -ge 4 ] || TIMEOUT_PROBLEM='FM_CHECK_TIMEOUT must be at least 4 seconds for the memory check'
PROBE_SECS=${FM_MEMORY_PROBE_SECS:-5}
case "$PROBE_SECS" in
  ''|*[!0-9]*|0) PROBE_SECS=5 ;;
  *) [ "$PROBE_SECS" -le 20 ] || PROBE_SECS=20 ;;
esac
BUDGET_SECS=$((CHECK_TIMEOUT - 3))
[ "$BUDGET_SECS" -ge 1 ] || BUDGET_SECS=1
[ "$BUDGET_SECS" -le 20 ] || BUDGET_SECS=20
DEADLINE=0

probe_bound() {
  local left
  left=$((DEADLINE - $(date +%s)))
  [ "$left" -ge 1 ] || left=1
  if [ "$left" -lt "$PROBE_SECS" ]; then
    printf '%s\n' "$left"
  else
    printf '%s\n' "$PROBE_SECS"
  fi
}

RECORD_STREAK=0
RECORD_ALERTED=0
RECORD_ERROR=
RECORD_POLICY=

record_read() {
  local line first=1
  RECORD_STREAK=0
  RECORD_ALERTED=0
  RECORD_ERROR=
  RECORD_POLICY=
  [ -f "$RECORD" ] && [ ! -L "$RECORD" ] || return 0
  while IFS= read -r line; do
    if [ "$first" -eq 1 ]; then
      first=0
      [ "$line" = "$RECORD_SCHEMA" ] || return 0
      continue
    fi
    case "$line" in
      streak=*)
        line=${line#streak=}
        case "$line" in ''|*[!0-9]*) ;; *) RECORD_STREAK=$line ;; esac
        ;;
      alerted=0) RECORD_ALERTED=0 ;;
      alerted=1) RECORD_ALERTED=1 ;;
      error=*) RECORD_ERROR=${line#error=} ;;
      policy=*) RECORD_POLICY=${line#policy=} ;;
    esac
  done < "$RECORD"
}

record_write() { # <streak> <alerted> <error>
  local streak=$1 alerted=$2 error=$3 tmp device
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 1
  device=$(fm_pr_file_device "$STATE") || return 1
  [ -n "$device" ] || return 1
  fm_pr_regular_destination_on_device_or_absent "$RECORD" "$device" || return 1
  tmp=$(umask 077; mktemp "$STATE/.fm-memory-check.XXXXXX" 2>/dev/null) || return 1
  if ! {
    printf '%s\n' "$RECORD_SCHEMA"
    printf 'streak=%s\n' "$streak"
    printf 'alerted=%s\n' "$alerted"
    printf 'error=%s\n' "$error"
    printf 'policy=%s:%s:%s\n' "$FREE_GB_THRESHOLD" "$FREE_PERCENT_THRESHOLD" "$CONSECUTIVE_POLLS"
  } > "$tmp" || ! chmod 0600 "$tmp" || ! fm_pr_private_file_valid "$tmp" 600 "$device"; then
    rm -f -- "$tmp"
    return 1
  fi
  if ! fm_pr_regular_destination_on_device_or_absent "$RECORD" "$device" \
    || ! mv -f -- "$tmp" "$RECORD"; then
    rm -f -- "$tmp"
    return 1
  fi
  return 0
}

report_problem() { # <stable one-line report>
  local report=$1 previous=$RECORD_ERROR
  record_write 0 0 "$report" || {
    printf 'memory check failed: cannot write its poll record\n'
    return 0
  }
  [ "$report" = "$previous" ] || printf '%s\n' "$report"
}

# probe_output <command> [args...] - print the bounded command's stdout.
# Returns 0, 124 for a hit bound, or 1 for any other failure.
probe_output() {
  local status
  fm_run_timed "$(probe_bound)" "$@" 2>/dev/null
  status=$?
  case "$status" in
    0) return 0 ;;
    124) return 124 ;;
    *) return 1 ;;
  esac
}

# gb_from_bytes <bytes> - gigabytes with one decimal.
gb_from_bytes() {
  awk -v b="$1" -v g="$GIB" 'BEGIN { printf "%.1f", b / g }'
}

# top_processes - "name X.X GB" for the five largest resident processes.
top_processes() {
  local listing
  listing=$(probe_output ps -axo rss=,comm=) || return 1
  printf '%s\n' "$listing" | sort -rn | head -n 5 | awk '
    {
      rss = $1
      sub(/^[ \t]*[0-9]+[ \t]+/, "")
      sub(/.*\//, "")
      if (rss !~ /^[0-9]+$/ || $0 == "") next
      out = out sep sprintf("%s %.1f GB", $0, rss / 1048576)
      sep = ", "
    }
    END { if (out == "") exit 1; print out }'
}

action_check() {
  local tool vm pressure status page_size free_pages spec_pages free_bytes free_gb percent streak top
  mkdir -p "$STATE" 2>/dev/null || {
    printf 'memory check failed: state directory is unavailable\n'
    return 0
  }
  record_read
  if ! config_load; then
    report_problem "memory check failed: $CONFIG_PROBLEM"
    return 0
  fi
  if [ "$RECORD_POLICY" != "$FREE_GB_THRESHOLD:$FREE_PERCENT_THRESHOLD:$CONSECUTIVE_POLLS" ]; then
    RECORD_STREAK=0
    RECORD_ALERTED=0
    RECORD_ERROR=
  fi
  if [ -n "$TIMEOUT_PROBLEM" ]; then
    report_problem "memory check failed: $TIMEOUT_PROBLEM"
    return 0
  fi
  for tool in vm_stat memory_pressure; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      report_problem "memory check cannot measure: $tool is not installed on this host"
      return 0
    fi
  done

  DEADLINE=$(($(date +%s) + BUDGET_SECS))
  vm=$(probe_output vm_stat)
  status=$?
  if [ "$status" -ne 0 ]; then
    if [ "$status" -eq 124 ]; then
      report_problem 'memory check cannot measure: vm_stat timed out'
    else
      report_problem 'memory check cannot measure: vm_stat failed'
    fi
    return 0
  fi
  pressure=$(probe_output memory_pressure)
  status=$?
  if [ "$status" -ne 0 ]; then
    if [ "$status" -eq 124 ]; then
      report_problem 'memory check cannot measure: memory_pressure timed out'
    else
      report_problem 'memory check cannot measure: memory_pressure failed'
    fi
    return 0
  fi

  page_size=$(printf '%s\n' "$vm" | sed -n 's/.*page size of \([0-9][0-9]*\) bytes.*/\1/p' | head -n 1)
  free_pages=$(printf '%s\n' "$vm" | sed -n 's/^Pages free:[[:space:]]*\([0-9][0-9]*\)\.$/\1/p' | head -n 1)
  spec_pages=$(printf '%s\n' "$vm" | sed -n 's/^Pages speculative:[[:space:]]*\([0-9][0-9]*\)\.$/\1/p' | head -n 1)
  [ -n "$spec_pages" ] || spec_pages=0
  percent=$(printf '%s\n' "$pressure" | sed -n 's/^System-wide memory free percentage:[[:space:]]*\([0-9][0-9]*\)%$/\1/p' | head -n 1)
  case "$page_size:$free_pages:$spec_pages" in
    *[!0-9:]*|:*|*::*)
      report_problem 'memory check cannot measure: vm_stat output was unreadable'
      return 0
      ;;
  esac
  case "$percent" in ''|*[!0-9]*)
    report_problem 'memory check cannot measure: memory_pressure output was unreadable'
    return 0
    ;;
  esac
  if [ "${#page_size}" -gt 9 ] || [ "${#free_pages}" -gt 12 ] || [ "${#spec_pages}" -gt 12 ] || [ "${#percent}" -gt 3 ] \
    || [ "$page_size" -le 0 ] || [ "$percent" -gt 100 ]; then
    report_problem 'memory check cannot measure: memory readings were out of range'
    return 0
  fi
  free_bytes=$(( (free_pages + spec_pages) * page_size ))

  if [ "$free_bytes" -ge $((FREE_GB_THRESHOLD * GIB)) ] && [ "$percent" -ge "$FREE_PERCENT_THRESHOLD" ]; then
    record_write 0 0 '' || printf 'memory check failed: cannot write its poll record\n'
    return 0
  fi

  streak=$((RECORD_STREAK + 1))
  [ "$streak" -le "$CONSECUTIVE_POLLS" ] || streak=$CONSECUTIVE_POLLS
  if [ "$streak" -ge "$CONSECUTIVE_POLLS" ] && [ "$RECORD_ALERTED" -eq 0 ]; then
    if ! record_write "$streak" 1 ''; then
      printf 'memory check failed: cannot write its poll record\n'
      return 0
    fi
    free_gb=$(gb_from_bytes "$free_bytes")
    top=$(top_processes) || top='unavailable'
    printf 'low memory: %s GB free, %s%% free (thresholds %s GB, %s%%); top memory: %s\n' \
      "$free_gb" "$percent" "$FREE_GB_THRESHOLD" "$FREE_PERCENT_THRESHOLD" "$top"
    return 0
  fi
  record_write "$streak" "$RECORD_ALERTED" '' \
    || printf 'memory check failed: cannot write its poll record\n'
  return 0
}

shim_content() {
  local home=$1
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    '# Auto-generated by fm-memory-check.sh - host low-memory poll shim.' \
    '# The watcher validates these bytes, then dispatches the trusted check script.' \
    "export FM_HOME=$(printf '%q' "$home")" \
    "exec $(printf '%q' "$SCRIPT_DIR/fm-memory-check.sh") check"
}

SHIM_WRITE_TMP=
shim_write() {
  local want=$1 device tmp
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 1
  device=$(fm_pr_file_device "$STATE") || return 1
  [ -n "$device" ] || return 1
  fm_pr_regular_destination_on_device_or_absent "$CHECK_SHIM" "$device" || return 1
  if [ -e "$CHECK_SHIM" ] && [ "$(fm_pr_file_mode "$CHECK_SHIM")" = 700 ] \
    && [ "$(cat "$CHECK_SHIM" 2>/dev/null)" = "$want" ]; then
    return 0
  fi
  tmp=$(umask 077; mktemp "$STATE/.fm-memory-shim.XXXXXX" 2>/dev/null) || return 1
  SHIM_WRITE_TMP=$tmp
  if ! printf '%s\n' "$want" > "$tmp" || ! chmod 0700 "$tmp" \
    || ! fm_pr_private_file_valid "$tmp" 700 "$device"; then
    rm -f -- "$tmp"
    SHIM_WRITE_TMP=
    return 1
  fi
  if ! fm_pr_regular_destination_on_device_or_absent "$CHECK_SHIM" "$device" \
    || ! mv -f -- "$tmp" "$CHECK_SHIM"; then
    rm -f -- "$tmp"
    SHIM_WRITE_TMP=
    return 1
  fi
  SHIM_WRITE_TMP=
  fm_pr_private_file_valid "$CHECK_SHIM" 700 "$device"
}

shim_backup() {
  local device tmp
  device=$(fm_pr_file_device "$STATE") || return 1
  tmp=$(umask 077; mktemp "$STATE/.fm-memory-shim.XXXXXX" 2>/dev/null) || return 1
  if ! cat "$CHECK_SHIM" > "$tmp" 2>/dev/null || ! chmod 0700 "$tmp" \
    || ! fm_pr_private_file_valid "$tmp" 700 "$device"; then
    rm -f -- "$tmp"
    return 1
  fi
  printf '%s\n' "$tmp"
}

ARM_BACKUP=
arm_rollback() {
  [ -z "$SHIM_WRITE_TMP" ] || rm -f -- "$SHIM_WRITE_TMP"
  SHIM_WRITE_TMP=
  if [ -n "$ARM_BACKUP" ]; then
    mv -f -- "$ARM_BACKUP" "$CHECK_SHIM" 2>/dev/null || rm -f -- "$ARM_BACKUP"
    ARM_BACKUP=
    fm_custom_check_registered "$STATE" "$CHECK_ID" && return 0
  fi
  rm -f -- "$CHECK_SHIM"
}

# shellcheck disable=SC2329  # Registered by action_arm's signal trap.
arm_interrupted() {
  arm_rollback
  printf 'fm-memory-check: arming was interrupted, so state/%s.check.sh is not armed\n' "$CHECK_ID" >&2
  exit 1
}

action_arm() {
  local want home
  if ! config_load; then
    printf 'fm-memory-check: %s\n' "$CONFIG_PROBLEM" >&2
    return 1
  fi
  mkdir -p "$STATE" || return 1
  case "$FM_HOME" in
    /*) home=$FM_HOME ;;
    *)
      home=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) || {
        printf 'fm-memory-check: cannot resolve FM_HOME %s\n' "$FM_HOME" >&2
        return 1
      }
      ;;
  esac
  want=$(shim_content "$home")
  ARM_BACKUP=
  if [ -f "$CHECK_SHIM" ] && [ ! -L "$CHECK_SHIM" ]; then
    ARM_BACKUP=$(shim_backup) || {
      printf 'fm-memory-check: could not save the existing %s\n' "$CHECK_SHIM" >&2
      return 1
    }
  fi
  trap arm_interrupted HUP INT TERM
  if ! shim_write "$want"; then
    trap - HUP INT TERM
    arm_rollback
    printf 'fm-memory-check: could not write %s\n' "$CHECK_SHIM" >&2
    return 1
  fi
  if ! FM_HOME="$home" "$REGISTER_BIN" "$CHECK_ID" >/dev/null; then
    trap - HUP INT TERM
    arm_rollback
    printf 'fm-memory-check: could not register %s\n' "$CHECK_SHIM" >&2
    return 1
  fi
  trap - HUP INT TERM
  [ -z "$ARM_BACKUP" ] || rm -f -- "$ARM_BACKUP"
  ARM_BACKUP=
  printf 'armed: state/%s.check.sh\n' "$CHECK_ID"
}

action_disarm() {
  local device
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || {
    printf 'fm-memory-check: state directory is unavailable\n' >&2
    return 1
  }
  device=$(fm_pr_file_device "$STATE") || return 1
  if [ -e "$RECORD" ] || [ -L "$RECORD" ]; then
    fm_pr_private_file_valid "$RECORD" 600 "$device" || {
      printf 'fm-memory-check: poll record is unsafe to remove\n' >&2
      return 1
    }
  fi
  FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$UNREGISTER_BIN" "$CHECK_ID" >/dev/null || return 1
  rm -f -- "$RECORD"
  printf 'disarmed: state/%s.check.sh\n' "$CHECK_ID"
}

case "${1:-check}" in
  check) action_check ;;
  arm) action_arm ;;
  disarm) action_disarm ;;
  -h|--help) usage ;;
  *) die_usage "unknown action: $1" ;;
esac
