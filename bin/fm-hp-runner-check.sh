#!/usr/bin/env bash
# fm-hp-runner-check.sh - detect a backed-up Scout queue with no usable runner.
#
# Usage:
#   fm-hp-runner-check.sh [check]
#   fm-hp-runner-check.sh arm
#   fm-hp-runner-check.sh disarm
#   fm-hp-runner-check.sh --help
#
# `check` reads the GitHub Actions runners and queued workflow runs for
# TastyTom13/Scout. It prints one line after the queue exceeds QUEUE_THRESHOLD
# (default 3) for CONSECUTIVE_POLLS polls (default 2) while hp-scout-1 is
# offline, absent, or every online runner is idle. It stays silent otherwise
# and reports an unchanged outage only once. API and configuration failures are
# actionable because they leave the detector blind, but an unchanged failure is
# also reported only once.
#
# The optional local config/hp-runner-check file accepts only these lines:
#   QUEUE_THRESHOLD=<whole number from 0 to 10000>
#   CONSECUTIVE_POLLS=<whole number from 1 to 100>
# Blank lines and lines beginning with # are ignored.
#
# Every GitHub read is hard-bounded and the whole probe budget is kept below
# FM_CHECK_TIMEOUT. `arm` atomically writes state/hp-runner.check.sh with mode
# 0700 and binds its bytes through fm-check-register.sh.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/hp-runner-check"
CHECK_ID=hp-runner
CHECK_SHIM="$STATE/$CHECK_ID.check.sh"
RECORD="$STATE/.hp-runner-check"
REGISTER_BIN="$SCRIPT_DIR/fm-check-register.sh"
UNREGISTER_BIN="$SCRIPT_DIR/fm-check-unregister.sh"
REPOSITORY=TastyTom13/Scout
RUNNER_NAME=hp-scout-1
RECORD_SCHEMA=fm-hp-runner-check-v1

# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"

usage() {
  cat <<'EOF'
Usage:
  fm-hp-runner-check.sh [check]   inspect the Scout queue and runner capacity
  fm-hp-runner-check.sh arm       write and register state/hp-runner.check.sh
  fm-hp-runner-check.sh disarm    unregister the check and remove its poll record
  fm-hp-runner-check.sh --help    print this help

Optional thresholds live in config/hp-runner-check.
See docs/configuration.md for the schema.
EOF
}

die_usage() {
  printf 'fm-hp-runner-check: %s\n' "$1" >&2
  usage >&2
  exit 2
}

QUEUE_THRESHOLD=3
CONSECUTIVE_POLLS=2
CONFIG_PROBLEM=

config_validate_value() { # <key> <value>
  local key=$1 value=$2 min max
  case "$key" in
    QUEUE_THRESHOLD) min=0; max=10000 ;;
    CONSECUTIVE_POLLS) min=1; max=100 ;;
    *) return 1 ;;
  esac
  case "$value" in ''|*[!0-9]*) return 1 ;; esac
  [ "$value" -ge "$min" ] && [ "$value" -le "$max" ]
}

config_load() {
  local line key value seen_queue=0 seen_polls=0
  QUEUE_THRESHOLD=3
  CONSECUTIVE_POLLS=2
  CONFIG_PROBLEM=
  [ -e "$CONFIG" ] || return 0
  if [ ! -f "$CONFIG" ] || [ -L "$CONFIG" ] || [ ! -r "$CONFIG" ]; then
    CONFIG_PROBLEM='config/hp-runner-check is not a readable regular file'
    return 1
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    key=${line%%=*}
    if [ "$key" = "$line" ]; then
      CONFIG_PROBLEM='config/hp-runner-check has a malformed line'
      return 1
    fi
    value=${line#*=}
    case "$key" in
      QUEUE_THRESHOLD)
        if [ "$seen_queue" -eq 1 ] || ! config_validate_value "$key" "$value"; then
          CONFIG_PROBLEM='QUEUE_THRESHOLD must appear once at most and be a whole number from 0 to 10000'
          return 1
        fi
        seen_queue=1
        QUEUE_THRESHOLD=$value
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
        CONFIG_PROBLEM='config/hp-runner-check has an unknown key'
        return 1
        ;;
    esac
  done < "$CONFIG"
  return 0
}

CHECK_TIMEOUT=${FM_CHECK_TIMEOUT:-30}
case "$CHECK_TIMEOUT" in ''|*[!0-9]*|0) CHECK_TIMEOUT=30 ;; esac
TIMEOUT_PROBLEM=
[ "$CHECK_TIMEOUT" -ge 4 ] || TIMEOUT_PROBLEM='FM_CHECK_TIMEOUT must be at least 4 seconds for the HP runner check'
PROBE_SECS=${FM_HP_RUNNER_PROBE_SECS:-10}
case "$PROBE_SECS" in
  ''|*[!0-9]*|0) PROBE_SECS=10 ;;
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
  tmp=$(umask 077; mktemp "$STATE/.fm-hp-runner-check.XXXXXX" 2>/dev/null) || return 1
  if ! {
    printf '%s\n' "$RECORD_SCHEMA"
    printf 'streak=%s\n' "$streak"
    printf 'alerted=%s\n' "$alerted"
    printf 'error=%s\n' "$error"
    printf 'policy=%s:%s\n' "$QUEUE_THRESHOLD" "$CONSECUTIVE_POLLS"
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

report_failure() { # <stable one-line reason>
  local reason=$1 previous=$RECORD_ERROR
  record_write 0 0 "$reason" || {
    printf 'hp runner check failed: cannot write its poll record\n'
    return 0
  }
  if [ "$reason" != "$previous" ]; then
    printf 'hp runner check failed: %s\n' "$reason"
  fi
}

RUNNERS_FILE=
RUNS_FILE=
PROBE_ERR=
cleanup_probe_files() {
  [ -z "$RUNNERS_FILE" ] || rm -f -- "$RUNNERS_FILE"
  [ -z "$RUNS_FILE" ] || rm -f -- "$RUNS_FILE"
  [ -z "$PROBE_ERR" ] || rm -f -- "$PROBE_ERR"
}

probe_github() { # <endpoint> <output-file>
  local endpoint=$1 output=$2 status
  : > "$PROBE_ERR" || return 1
  fm_run_timed "$(probe_bound)" gh api --method GET "$endpoint" > "$output" 2> "$PROBE_ERR"
  status=$?
  case "$status" in
    0) return 0 ;;
    124) return 124 ;;
    *) return 1 ;;
  esac
}

action_check() {
  local runner_endpoint runs_endpoint status queued total loaded hp_status online busy streak reason
  mkdir -p "$STATE" 2>/dev/null || {
    printf 'hp runner check failed: state directory is unavailable\n'
    return 0
  }
  record_read
  if ! config_load; then
    report_failure "$CONFIG_PROBLEM"
    return 0
  fi
  if [ "$RECORD_POLICY" != "$QUEUE_THRESHOLD:$CONSECUTIVE_POLLS" ]; then
    RECORD_STREAK=0
    RECORD_ALERTED=0
    RECORD_ERROR=
  fi
  if [ -n "$TIMEOUT_PROBLEM" ]; then
    report_failure "$TIMEOUT_PROBLEM"
    return 0
  fi
  if ! command -v gh >/dev/null 2>&1; then
    report_failure 'gh is not installed'
    return 0
  fi
  if ! command -v jq >/dev/null 2>&1; then
    report_failure 'jq is not installed'
    return 0
  fi

  RUNNERS_FILE=$(umask 077; mktemp "$STATE/.fm-hp-runners.XXXXXX" 2>/dev/null) || {
    report_failure 'cannot create a private runner response file'
    return 0
  }
  RUNS_FILE=$(umask 077; mktemp "$STATE/.fm-hp-runs.XXXXXX" 2>/dev/null) || {
    cleanup_probe_files
    report_failure 'cannot create a private workflow response file'
    return 0
  }
  PROBE_ERR=$(umask 077; mktemp "$STATE/.fm-hp-probe-error.XXXXXX" 2>/dev/null) || {
    cleanup_probe_files
    report_failure 'cannot create a private probe error file'
    return 0
  }
  trap cleanup_probe_files EXIT HUP INT TERM
  DEADLINE=$(($(date +%s) + BUDGET_SECS))
  runner_endpoint="repos/$REPOSITORY/actions/runners?per_page=100"
  runs_endpoint="repos/$REPOSITORY/actions/runs?status=queued&per_page=1"

  probe_github "$runner_endpoint" "$RUNNERS_FILE"
  status=$?
  if [ "$status" -ne 0 ]; then
    [ "$status" -eq 124 ] && reason='the GitHub runners read timed out' || reason='the GitHub runners read failed'
    report_failure "$reason"
    cleanup_probe_files
    trap - EXIT HUP INT TERM
    return 0
  fi
  probe_github "$runs_endpoint" "$RUNS_FILE"
  status=$?
  if [ "$status" -ne 0 ]; then
    [ "$status" -eq 124 ] && reason='the GitHub queued-runs read timed out' || reason='the GitHub queued-runs read failed'
    report_failure "$reason"
    cleanup_probe_files
    trap - EXIT HUP INT TERM
    return 0
  fi

  if ! jq -e '(.total_count | type == "number" and . >= 0 and floor == .)' "$RUNNERS_FILE" >/dev/null 2>&1 \
    || ! jq -e '.runners | type == "array"' "$RUNNERS_FILE" >/dev/null 2>&1; then
    report_failure 'the GitHub runners response was malformed'
    cleanup_probe_files
    trap - EXIT HUP INT TERM
    return 0
  fi
  total=$(jq -r '.total_count' "$RUNNERS_FILE")
  loaded=$(jq -r '.runners | length' "$RUNNERS_FILE")
  case "$total:$loaded" in *[!0-9:]*) total=0; loaded=1 ;; esac
  if [ "$total" -gt "$loaded" ]; then
    report_failure 'the repository has more than 100 runners and the response was incomplete'
    cleanup_probe_files
    trap - EXIT HUP INT TERM
    return 0
  fi
  if ! jq -e '.runners | all(.[]; (.name | type == "string") and (.status | type == "string") and (.busy | type == "boolean"))' \
    "$RUNNERS_FILE" >/dev/null 2>&1; then
    report_failure 'the GitHub runners response was malformed'
    cleanup_probe_files
    trap - EXIT HUP INT TERM
    return 0
  fi
  if ! jq -e '(.total_count | type == "number" and . >= 0 and floor == .)' "$RUNS_FILE" >/dev/null 2>&1; then
    queued=
  else
    queued=$(jq -r '.total_count' "$RUNS_FILE" 2>/dev/null)
  fi
  case "$queued" in ''|*[!0-9]*)
    report_failure 'the GitHub queued-runs response was malformed'
    cleanup_probe_files
    trap - EXIT HUP INT TERM
    return 0
    ;;
  esac

  hp_status=$(jq -r --arg runner "$RUNNER_NAME" '[.runners[] | select(.name == $runner)] | if length == 0 then "offline" else .[0].status end' "$RUNNERS_FILE")
  online=$(jq -r '[.runners[] | select(.status == "online")] | length' "$RUNNERS_FILE")
  busy=$(jq -r '[.runners[] | select(.status == "online" and .busy == true)] | length' "$RUNNERS_FILE")
  cleanup_probe_files
  trap - EXIT HUP INT TERM

  if [ "$queued" -le "$QUEUE_THRESHOLD" ] \
    || { [ "$hp_status" = online ] && { [ "$online" -eq 0 ] || [ "$busy" -gt 0 ]; }; }; then
    record_write 0 0 '' || printf 'hp runner check failed: cannot write its poll record\n'
    return 0
  fi

  streak=$((RECORD_STREAK + 1))
  [ "$streak" -le "$CONSECUTIVE_POLLS" ] || streak=$CONSECUTIVE_POLLS
  if [ "$streak" -ge "$CONSECUTIVE_POLLS" ] && [ "$RECORD_ALERTED" -eq 0 ]; then
    if ! record_write "$streak" 1 ''; then
      printf 'hp runner check failed: cannot write its poll record\n'
      return 0
    fi
    if [ "$hp_status" != online ]; then
      printf 'Scout runner outage: %s is offline with %s queued Scout runs (threshold %s)\n' \
        "$RUNNER_NAME" "$queued" "$QUEUE_THRESHOLD"
    else
      printf 'Scout runner outage: every online runner is idle with %s queued Scout runs (threshold %s)\n' \
        "$queued" "$QUEUE_THRESHOLD"
    fi
    return 0
  fi
  record_write "$streak" "$RECORD_ALERTED" '' \
    || printf 'hp runner check failed: cannot write its poll record\n'
  return 0
}

shim_content() {
  local home=$1
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    '# Auto-generated by fm-hp-runner-check.sh - Scout runner outage poll shim.' \
    '# The watcher validates these bytes, then dispatches the trusted check script.' \
    "export FM_HOME=$(printf '%q' "$home")" \
    "exec $(printf '%q' "$SCRIPT_DIR/fm-hp-runner-check.sh") check"
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
  tmp=$(umask 077; mktemp "$STATE/.fm-hp-runner-shim.XXXXXX" 2>/dev/null) || return 1
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
  tmp=$(umask 077; mktemp "$STATE/.fm-hp-runner-shim.XXXXXX" 2>/dev/null) || return 1
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
  printf 'fm-hp-runner-check: arming was interrupted, so state/%s.check.sh is not armed\n' "$CHECK_ID" >&2
  exit 1
}

action_arm() {
  local want home
  if ! config_load; then
    printf 'fm-hp-runner-check: %s\n' "$CONFIG_PROBLEM" >&2
    return 1
  fi
  mkdir -p "$STATE" || return 1
  case "$FM_HOME" in
    /*) home=$FM_HOME ;;
    *)
      home=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) || {
        printf 'fm-hp-runner-check: cannot resolve FM_HOME %s\n' "$FM_HOME" >&2
        return 1
      }
      ;;
  esac
  want=$(shim_content "$home")
  ARM_BACKUP=
  if [ -f "$CHECK_SHIM" ] && [ ! -L "$CHECK_SHIM" ]; then
    ARM_BACKUP=$(shim_backup) || {
      printf 'fm-hp-runner-check: could not save the existing %s\n' "$CHECK_SHIM" >&2
      return 1
    }
  fi
  trap arm_interrupted HUP INT TERM
  if ! shim_write "$want"; then
    trap - HUP INT TERM
    arm_rollback
    printf 'fm-hp-runner-check: could not write %s\n' "$CHECK_SHIM" >&2
    return 1
  fi
  if ! FM_HOME="$home" "$REGISTER_BIN" "$CHECK_ID" >/dev/null; then
    trap - HUP INT TERM
    arm_rollback
    printf 'fm-hp-runner-check: could not register %s\n' "$CHECK_SHIM" >&2
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
    printf 'fm-hp-runner-check: state directory is unavailable\n' >&2
    return 1
  }
  device=$(fm_pr_file_device "$STATE") || return 1
  if [ -e "$RECORD" ] || [ -L "$RECORD" ]; then
    fm_pr_private_file_valid "$RECORD" 600 "$device" || {
      printf 'fm-hp-runner-check: poll record is unsafe to remove\n' >&2
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
