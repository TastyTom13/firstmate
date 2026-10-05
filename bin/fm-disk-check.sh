#!/usr/bin/env bash
# fm-disk-check.sh - warn while disk is leaking, not after it is gone.
#
# Usage:
#   fm-disk-check.sh [check]
#   fm-disk-check.sh arm
#   fm-disk-check.sh disarm
#   fm-disk-check.sh --help
#
# `check` only reads; it never prunes, removes, or stops anything. Each run
# takes one sample:
#   - free space from `df -Pk` on /System/Volumes/Data (/ where that macOS
#     data volume does not exist);
#   - the count of dangling Docker volumes (`docker volume ls -q -f
#     dangling=true`) and their total size (joined by name against `docker
#     system df -v`), or "docker unreachable" when the docker CLI or daemon
#     does not answer, which is recorded but is not itself a wake;
#   - the size of ~/.treehouse from `du -sk`.
# It appends the dated sample to state/.disk-watch-history (one line per run,
# samples older than eight days pruned) and prints one line, which the watcher
# turns into a `check:` wake, only when at least one condition holds:
#   - free space is below FREE_MIN_GB;
#   - free space fell more than FREE_DROP_GB since the newest sample at least
#     24 hours old;
#   - dangling Docker volumes exceed DANGLING_MAX_COUNT or DANGLING_MAX_GB;
#   - ~/.treehouse grew more than TREEHOUSE_GROWTH_GB since the newest sample
#     at least seven days old;
#   - the check is blind: config/disk-watch is invalid, df is unreadable, or
#     one ~/.treehouse entry cannot be measured within a whole run's budget.
# Otherwise it prints nothing. An unchanged set of conditions is reported once
# and then again at most once a day while it persists; a run with no condition
# clears the episode. GB means 10^9 bytes, the unit docker prints.
#
# One `du -sk` of ~/.treehouse can take longer than the watcher allows a whole
# check (FM_CHECK_TIMEOUT), so the size is summed from per-entry `du -sk`
# measurements of every ~/.treehouse/<pool>/<entry> (plus loose files directly
# under ~/.treehouse), cached in state/.disk-watch-treehouse. Each run refreshes
# entries older than an hour, oldest first, inside the time left in its budget,
# and a ~/.treehouse total is sampled only when every current entry has a size.
#
# The optional local config/disk-watch file accepts only these lines:
#   FREE_MIN_GB=<whole number from 1 to 100000>          (default 300)
#   FREE_DROP_GB=<whole number from 1 to 100000>         (default 30)
#   DANGLING_MAX_COUNT=<whole number from 0 to 1000000>  (default 50)
#   DANGLING_MAX_GB=<whole number from 0 to 100000>      (default 5)
#   TREEHOUSE_GROWTH_GB=<whole number from 1 to 100000>  (default 30)
# Blank lines and lines beginning with # are ignored. Unknown keys, duplicates,
# and malformed values are reported, never silently defaulted.
#
# `arm` atomically writes state/disk.check.sh with mode 0700 and binds its
# bytes through fm-check-register.sh, so the watcher runs it on its
# FM_CHECK_INTERVAL cadence. `disarm` unregisters it and removes the report
# record, the history, and the ~/.treehouse size cache.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/disk-watch"
CHECK_ID=disk
CHECK_SHIM="$STATE/$CHECK_ID.check.sh"
RECORD="$STATE/.disk-watch"
HISTORY="$STATE/.disk-watch-history"
TREE_CACHE="$STATE/.disk-watch-treehouse"
REGISTER_BIN="$SCRIPT_DIR/fm-check-register.sh"
UNREGISTER_BIN="$SCRIPT_DIR/fm-check-unregister.sh"
RECORD_SCHEMA=fm-disk-watch-v1
HISTORY_SCHEMA=fm-disk-watch-history-v1
TREE_SCHEMA=fm-disk-watch-treehouse-v1
TREEHOUSE="$HOME/.treehouse"
DAY=86400
HISTORY_KEEP=$((8 * DAY))
TREE_REFRESH=3600
MAX_LINE=480

# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-line-cap-lib.sh
. "$SCRIPT_DIR/fm-line-cap-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"

usage() {
  cat <<'EOF'
Usage:
  fm-disk-check.sh [check]   sample disk use; one wake line only when a leak threshold is crossed
  fm-disk-check.sh arm       write and register state/disk.check.sh
  fm-disk-check.sh disarm    unregister the check and remove its record, history, and cache
  fm-disk-check.sh --help    print this help

The check never prunes or deletes anything.
Optional thresholds live in config/disk-watch.
See docs/configuration.md for the schema.
EOF
}

die_usage() {
  printf 'fm-disk-check: %s\n' "$1" >&2
  usage >&2
  exit 2
}

now_epoch() {
  case "${FM_DISK_CHECK_NOW:-}" in
    ''|*[!0-9]*) date +%s ;;
    *) printf '%s\n' "$FM_DISK_CHECK_NOW" ;;
  esac
}

FREE_MIN_GB=300
FREE_DROP_GB=30
DANGLING_MAX_COUNT=50
DANGLING_MAX_GB=5
TREEHOUSE_GROWTH_GB=30
CONFIG_PROBLEM=

config_load() {
  local line key value min max seen=' '
  CONFIG_PROBLEM=
  [ -e "$CONFIG" ] || [ -L "$CONFIG" ] || return 0
  if [ ! -f "$CONFIG" ] || [ -L "$CONFIG" ] || [ ! -r "$CONFIG" ]; then
    CONFIG_PROBLEM='config/disk-watch is not a readable regular file'
    return 1
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    key=${line%%=*}
    if [ "$key" = "$line" ]; then
      CONFIG_PROBLEM='config/disk-watch has a malformed line'
      return 1
    fi
    value=${line#*=}
    case "$key" in
      FREE_MIN_GB|FREE_DROP_GB|TREEHOUSE_GROWTH_GB) min=1; max=100000 ;;
      DANGLING_MAX_GB) min=0; max=100000 ;;
      DANGLING_MAX_COUNT) min=0; max=1000000 ;;
      *)
        CONFIG_PROBLEM='config/disk-watch has an unknown key'
        return 1
        ;;
    esac
    case "$seen" in *" $key "*)
      CONFIG_PROBLEM="config/disk-watch sets $key more than once"
      return 1
      ;;
    esac
    seen="$seen$key "
    # Reject leading zeros so a value is never read as octal or as a long string.
    case "$value" in ''|*[!0-9]*|0?*) value=x ;; esac
    if [ "$value" = x ] || [ "${#value}" -gt 7 ] || [ "$value" -lt "$min" ] || [ "$value" -gt "$max" ]; then
      CONFIG_PROBLEM="$key must be a whole number from $min to $max"
      return 1
    fi
    printf -v "$key" '%s' "$value"
  done < "$CONFIG"
  return 0
}

CHECK_TIMEOUT=${FM_CHECK_TIMEOUT:-30}
case "$CHECK_TIMEOUT" in ''|*[!0-9]*|0) CHECK_TIMEOUT=30 ;; esac
# fm_run_timed counts a whole second before it alarms, so the whole run has to
# fit inside the watcher's own bound with the alarm and kill margins left over.
BUDGET_SECS=$((CHECK_TIMEOUT - 3))
[ "$BUDGET_SECS" -ge 1 ] || BUDGET_SECS=1
DEADLINE=0

# time_left [cap] - whole seconds left in this run's budget, optionally capped.
time_left() {
  local left
  left=$((DEADLINE - $(date +%s)))
  if [ -n "${1:-}" ] && [ "$left" -gt "$1" ]; then
    left=$1
  fi
  printf '%s\n' "$left"
}

# probe <cap> <command...> - the bounded command's stdout; 124 when the bound hit.
probe() {
  local bound status
  bound=$(time_left "$1")
  shift
  [ "$bound" -ge 1 ] || return 124
  fm_run_timed "$bound" "$@" 2>/dev/null
  status=$?
  case "$status" in
    0) return 0 ;;
    124|137) return 124 ;;
    *) return 1 ;;
  esac
}

# private_replace <dest> <tmp-content-file> - install a 0600 file by rename.
private_replace() {
  local dest=$1 src=$2 device
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || { rm -f -- "$src"; return 1; }
  device=$(fm_pr_file_device "$STATE") || { rm -f -- "$src"; return 1; }
  if ! chmod 0600 "$src" || ! fm_pr_private_file_valid "$src" 600 "$device" \
    || ! fm_pr_regular_destination_on_device_or_absent "$dest" "$device" \
    || ! mv -f -- "$src" "$dest"; then
    rm -f -- "$src"
    return 1
  fi
  return 0
}

state_tmp() {
  (umask 077; mktemp "$STATE/.fm-disk-check.XXXXXX" 2>/dev/null)
}

# GB with one decimal from KiB.
gb_from_kb() {
  awk -v k="$1" 'BEGIN { printf "%.1f", k * 1024 / 1000000000 }'
}

# KiB from a whole number of decimal GB.
kb_from_gb() {
  printf '%s\n' $(($1 * 1000000000 / 1024))
}

# Samples free KiB on the data volume into FREE_KB; empty when unreadable.
FREE_KB=
sample_free() {
  local mount=/ out
  FREE_KB=
  [ -d /System/Volumes/Data ] && mount=/System/Volumes/Data
  out=$(probe 5 df -Pk "$mount") || return 0
  FREE_KB=$(printf '%s\n' "$out" | awk 'NR == 2 && $4 ~ /^[0-9]+$/ { print $4 }')
}

# Samples DANGLING_COUNT and DANGLING_KB; DOCKER_STATE is ok or unreachable,
# and DANGLING_KB stays empty when the sizes could not be read.
DANGLING_COUNT=
DANGLING_KB=
DOCKER_STATE=unreachable
sample_docker() {
  local names sizes
  DANGLING_COUNT=
  DANGLING_KB=
  DOCKER_STATE=unreachable
  command -v docker >/dev/null 2>&1 || return 0
  names=$(probe 5 docker volume ls -q -f dangling=true) || return 0
  DOCKER_STATE=ok
  DANGLING_COUNT=$(printf '%s\n' "$names" | awk 'NF { n++ } END { print n + 0 }')
  if [ "$DANGLING_COUNT" -eq 0 ]; then
    DANGLING_KB=0
    return 0
  fi
  sizes=$(probe 8 docker system df -v --format '{{range .Volumes}}{{.Name}} {{.Size}}{{println}}{{end}}') || return 0
  DANGLING_KB=$(
    { printf '%s\n' "$names" | awk 'NF { print "N", $1 }'; printf '%s\n' "$sizes" | awk 'NF == 2 { print "S", $1, $2 }'; } \
      | awk '
        $1 == "N" { want[$2] = 1; next }
        $1 == "S" && ($2 in want) {
          s = $3
          if (match(s, /^[0-9.]+/) == 0) { bad = 1; next }
          n = substr(s, 1, RLENGTH) + 0
          u = substr(s, RLENGTH + 1)
          if (u == "B") m = 1
          else if (u == "kB" || u == "KB") m = 1e3
          else if (u == "MB") m = 1e6
          else if (u == "GB") m = 1e9
          else if (u == "TB") m = 1e12
          else { bad = 1; next }
          total += n * m
        }
        END { if (bad) exit 1; printf "%d\n", total / 1024 }'
  ) || DANGLING_KB=
}

# Refreshes the per-entry ~/.treehouse size cache inside the time left and sets
# TREE_KB to the total when every current entry has a size. TREE_BLIND names an
# entry that could not be measured even when given the whole time left.
TREE_KB=
TREE_BLIND=
sample_treehouse() {
  local now=$1 units loose merged out tmp kb epoch path bound status first=1 refreshed
  TREE_KB=
  TREE_BLIND=
  [ -d "$TREEHOUSE" ] || return 0
  units=$(probe 3 find "$TREEHOUSE" -mindepth 2 -maxdepth 2 -print) || return 0
  loose=$(probe 3 find "$TREEHOUSE" -mindepth 1 -maxdepth 1 ! -type d -print) || return 0
  units=$units$'\n'$loose
  # Old cache rows for entries that still exist, unmeasured entries first, then
  # oldest measurement first, as "kb<TAB>epoch<TAB>path" with - for no size.
  merged=$(
    {
      if [ -f "$TREE_CACHE" ] && [ ! -L "$TREE_CACHE" ] && [ "$(sed -n 1p "$TREE_CACHE")" = "$TREE_SCHEMA" ]; then
        sed -n '2,$p' "$TREE_CACHE" | awk -F '\t' 'NF == 3 { print "C\t" $0 }'
      fi
      printf '%s\n' "$units" | awk 'NF && $0 !~ /\t/ { print "U\t" $0 }'
    } | awk -F '\t' '
      $1 == "C" { kb[$4] = $2; at[$4] = $3; next }
      $1 == "U" { p = $2; if (p in kb) print kb[p] "\t" at[p] "\t" p; else print "-\t0\t" p }' \
      | sort -t "$(printf '\t')" -k2,2n
  )
  refreshed=
  while IFS="$(printf '\t')" read -r kb epoch path; do
    [ -n "$path" ] || continue
    if [ "$kb" = - ] || [ $((now - epoch)) -ge "$TREE_REFRESH" ]; then
      bound=$(time_left)
      if [ "$bound" -ge 1 ]; then
        out=$(fm_run_timed "$bound" du -sk "$path" 2>/dev/null)
        status=$?
        out=$(printf '%s\n' "$out" | awk 'NR == 1 && $1 ~ /^[0-9]+$/ { print $1 }')
        if ! fm_timed_out "$status" && [ -n "$out" ]; then
          kb=$out
          epoch=$now
        elif [ -e "$path" ] && { [ "$first" -eq 1 ] || ! fm_timed_out "$status"; }; then
          TREE_BLIND=$path
        fi
        first=0
      fi
    fi
    refreshed="$refreshed$kb	$epoch	$path"$'\n'
  done <<EOF
$merged
EOF
  tmp=$(state_tmp) || return 0
  { printf '%s\n' "$TREE_SCHEMA"; printf '%s' "$refreshed"; } > "$tmp" || { rm -f -- "$tmp"; return 0; }
  private_replace "$TREE_CACHE" "$tmp" || true
  TREE_KB=$(printf '%s' "$refreshed" | awk -F '\t' 'NF == 3 { if ($1 == "-") { miss = 1 } else total += $1 } END { if (!miss) printf "%d\n", total }')
}

# baseline <now> <age> <field> - the field (3 free, 7 treehouse) of the newest
# history sample at least <age> seconds old that has a value for it.
baseline() {
  local now=$1 age=$2 field=$3
  [ -f "$HISTORY" ] && [ ! -L "$HISTORY" ] || return 0
  [ "$(sed -n 1p "$HISTORY")" = "$HISTORY_SCHEMA" ] || return 0
  sed -n '2,$p' "$HISTORY" | awk -v cut=$((now - age)) -v f="$field" '
    $2 ~ /^[0-9]+$/ && $2 <= cut && $f ~ /^[0-9]+$/ && $2 >= best_at { best_at = $2; best = $f; found = 1 }
    END { if (found) print best }'
}

history_append() {
  local now=$1 sample=$2 tmp
  tmp=$(state_tmp) || return 1
  {
    printf '%s\n' "$HISTORY_SCHEMA"
    if [ -f "$HISTORY" ] && [ ! -L "$HISTORY" ] && [ "$(sed -n 1p "$HISTORY")" = "$HISTORY_SCHEMA" ]; then
      sed -n '2,$p' "$HISTORY" | awk -v keep=$((now - HISTORY_KEEP)) '$2 ~ /^[0-9]+$/ && $2 >= keep'
    fi
    printf '%s\n' "$sample"
  } > "$tmp" || { rm -f -- "$tmp"; return 1; }
  private_replace "$HISTORY" "$tmp"
}

RECORD_KEY=
RECORD_AT=0
record_read() {
  local line first=1
  RECORD_KEY=
  RECORD_AT=0
  [ -f "$RECORD" ] && [ ! -L "$RECORD" ] || return 0
  while IFS= read -r line; do
    if [ "$first" -eq 1 ]; then
      first=0
      [ "$line" = "$RECORD_SCHEMA" ] || return 0
      continue
    fi
    case "$line" in
      key=*) RECORD_KEY=${line#key=} ;;
      reported_at=*)
        line=${line#reported_at=}
        case "$line" in ''|*[!0-9]*) ;; *) RECORD_AT=$line ;; esac
        ;;
    esac
  done < "$RECORD"
}

record_write() { # <key> <reported-at>
  local tmp
  tmp=$(state_tmp) || return 1
  printf '%s\nkey=%s\nreported_at=%s\n' "$RECORD_SCHEMA" "$1" "$2" > "$tmp" || { rm -f -- "$tmp"; return 1; }
  private_replace "$RECORD" "$tmp"
}

# report <now> <key> <line> - print the line for a new or day-old episode.
# Report before recording, so a record that cannot be written costs a repeated
# report rather than a lost one.
report() {
  local now=$1 key=$2 line=$3 at=$RECORD_AT
  if [ -z "$key" ]; then
    [ -z "$RECORD_KEY" ] || record_write '' 0 || true
    return 0
  fi
  if [ "$key" != "$RECORD_KEY" ] || [ $((now - RECORD_AT)) -ge "$DAY" ]; then
    fm_cap_line_var "disk: $line" "$MAX_LINE"
    printf '%s\n' "$FM_LINE_CAP_LINE"
    at=$now
  fi
  record_write "$key" "$at" || true
}

action_check() {
  local now key='' line='' summary base drop growth dangling_text free_text tree_text
  mkdir -p "$STATE" 2>/dev/null || {
    printf 'disk: check failed: state directory is unavailable\n'
    return 0
  }
  now=$(now_epoch)
  record_read
  if ! config_load; then
    report "$now" config "check failed: $CONFIG_PROBLEM"
    return 0
  fi
  DEADLINE=$(($(date +%s) + BUDGET_SECS))
  sample_free
  sample_docker
  sample_treehouse "$now"

  if [ -n "$DANGLING_KB" ]; then
    dangling_text="$DANGLING_COUNT dangling Docker volumes ($(gb_from_kb "$DANGLING_KB") GB)"
  elif [ "$DOCKER_STATE" = ok ]; then
    dangling_text="$DANGLING_COUNT dangling Docker volumes (size unknown)"
  else
    dangling_text='docker unreachable'
  fi
  free_text=unknown
  [ -z "$FREE_KB" ] || free_text="$(gb_from_kb "$FREE_KB") GB"
  tree_text=unknown
  [ -z "$TREE_KB" ] || tree_text="$(gb_from_kb "$TREE_KB") GB"
  summary="free $free_text, $dangling_text, ~/.treehouse $tree_text"

  if [ -z "$FREE_KB" ]; then
    key="$key free-unreadable"
    line="$line; cannot read free space with df"
  else
    if [ "$FREE_KB" -lt "$(kb_from_gb "$FREE_MIN_GB")" ]; then
      key="$key free-low"
      line="$line; free space below $FREE_MIN_GB GB"
    fi
    base=$(baseline "$now" "$DAY" 3)
    if [ -n "$base" ]; then
      drop=$((base - FREE_KB))
      if [ "$drop" -gt "$(kb_from_gb "$FREE_DROP_GB")" ]; then
        key="$key free-drop"
        line="$line; free space fell $(gb_from_kb "$drop") GB in 24 hours (limit $FREE_DROP_GB GB)"
      fi
    fi
  fi
  if [ -n "$DANGLING_COUNT" ] && { [ "$DANGLING_COUNT" -gt "$DANGLING_MAX_COUNT" ] \
    || { [ -n "$DANGLING_KB" ] && [ "$DANGLING_KB" -gt "$(kb_from_gb "$DANGLING_MAX_GB")" ]; }; }; then
    key="$key dangling"
    line="$line; dangling Docker volumes over $DANGLING_MAX_COUNT or $DANGLING_MAX_GB GB"
  fi
  if [ -n "$TREE_KB" ]; then
    base=$(baseline "$now" $((7 * DAY)) 7)
    if [ -n "$base" ]; then
      growth=$((TREE_KB - base))
      if [ "$growth" -gt "$(kb_from_gb "$TREEHOUSE_GROWTH_GB")" ]; then
        key="$key treehouse-growth"
        line="$line; ~/.treehouse grew $(gb_from_kb "$growth") GB in 7 days (limit $TREEHOUSE_GROWTH_GB GB)"
      fi
    fi
  fi
  if [ -n "$TREE_BLIND" ]; then
    key="$key treehouse-blind"
    line="$line; cannot measure $TREE_BLIND"
  fi

  history_append "$now" "$(date -u -r "$now" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$now" +%Y-%m-%dT%H:%M:%SZ) $now ${FREE_KB:--} $DOCKER_STATE ${DANGLING_COUNT:--} ${DANGLING_KB:--} ${TREE_KB:--}" || true
  report "$now" "${key# }" "${line#; } [$summary]"
  return 0
}

shim_content() {
  local home=$1
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    '# Auto-generated by fm-disk-check.sh - disk leak watch shim.' \
    '# The watcher validates these bytes, then dispatches the trusted check script.' \
    "export FM_HOME=$(printf '%q' "$home")" \
    "exec $(printf '%q' "$SCRIPT_DIR/fm-disk-check.sh") check"
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
  tmp=$(state_tmp) || return 1
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
  tmp=$(state_tmp) || return 1
  if ! cat "$CHECK_SHIM" > "$tmp" 2>/dev/null || ! chmod 0700 "$tmp" \
    || ! fm_pr_private_file_valid "$tmp" 700 "$device"; then
    rm -f -- "$tmp"
    return 1
  fi
  printf '%s\n' "$tmp"
}

# An unregistered shim is not inert: the watcher rejects it on every cycle and
# wakes firstmate about unauthenticated state checks, so a failed arm never
# leaves a shim without a matching trust binding.
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
  printf 'fm-disk-check: arming was interrupted, so state/%s.check.sh is not armed\n' "$CHECK_ID" >&2
  exit 1
}

action_arm() {
  local want home
  if ! config_load; then
    printf 'fm-disk-check: %s\n' "$CONFIG_PROBLEM" >&2
    return 1
  fi
  mkdir -p "$STATE" || return 1
  case "$FM_HOME" in
    /*) home=$FM_HOME ;;
    *)
      home=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) || {
        printf 'fm-disk-check: cannot resolve FM_HOME %s\n' "$FM_HOME" >&2
        return 1
      }
      ;;
  esac
  want=$(shim_content "$home")
  ARM_BACKUP=
  if [ -f "$CHECK_SHIM" ] && [ ! -L "$CHECK_SHIM" ]; then
    ARM_BACKUP=$(shim_backup) || {
      printf 'fm-disk-check: could not save the existing %s\n' "$CHECK_SHIM" >&2
      return 1
    }
  fi
  trap arm_interrupted HUP INT TERM
  if ! shim_write "$want"; then
    trap - HUP INT TERM
    arm_rollback
    printf 'fm-disk-check: could not write %s\n' "$CHECK_SHIM" >&2
    return 1
  fi
  if ! FM_HOME="$home" "$REGISTER_BIN" "$CHECK_ID" >/dev/null; then
    trap - HUP INT TERM
    arm_rollback
    printf 'fm-disk-check: could not register %s\n' "$CHECK_SHIM" >&2
    return 1
  fi
  trap - HUP INT TERM
  [ -z "$ARM_BACKUP" ] || rm -f -- "$ARM_BACKUP"
  ARM_BACKUP=
  printf 'armed: state/%s.check.sh\n' "$CHECK_ID"
}

action_disarm() {
  local device file
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || {
    printf 'fm-disk-check: state directory is unavailable\n' >&2
    return 1
  }
  device=$(fm_pr_file_device "$STATE") || return 1
  for file in "$RECORD" "$HISTORY" "$TREE_CACHE"; do
    if [ -e "$file" ] || [ -L "$file" ]; then
      fm_pr_private_file_valid "$file" 600 "$device" || {
        printf 'fm-disk-check: %s is unsafe to remove\n' "$file" >&2
        return 1
      }
    fi
  done
  FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$UNREGISTER_BIN" "$CHECK_ID" >/dev/null || return 1
  rm -f -- "$RECORD" "$HISTORY" "$TREE_CACHE"
  printf 'disarmed: state/%s.check.sh\n' "$CHECK_ID"
}

case "${1:-check}" in
  check) action_check ;;
  arm) action_arm ;;
  disarm) action_disarm ;;
  -h|--help) usage ;;
  *) die_usage "unknown action: $1" ;;
esac
