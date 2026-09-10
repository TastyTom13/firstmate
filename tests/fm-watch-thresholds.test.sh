#!/usr/bin/env bash
# tests/fm-watch-thresholds.test.sh - the per-home supervision cadence file
# config/watch-thresholds (docs/configuration.md "Watcher thresholds").
#
# Three claims are defended here, each through the interface that owns it:
#   1. Precedence. An explicit environment value beats the file, the file beats
#      the built-in default, and an absent file leaves every default untouched.
#   2. Tolerance. An unknown key, a malformed line, a non-integer value, and an
#      unreadable file are ignored after one report, and a usable key in the
#      same file still applies - the watcher must never fail to start over a
#      local preference file.
#   3. Agreement. The always-on watcher (bin/fm-watch.sh) and the away-mode
#      daemon (bin/fm-supervise-daemon.sh) resolve the SAME key to the SAME
#      value from the same home, because a home that retunes its cadence must
#      not get two supervisors that disagree about when a pane is stale.
# Every value is read back through the real production scripts, sourced in their
# library mode, rather than from the library in isolation.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WATCH="$ROOT/bin/fm-watch.sh"
DAEMON="$ROOT/bin/fm-supervise-daemon.sh"

TMP_ROOT=$(fm_test_tmproot fm-watch-thresholds)

# A home with a state dir and a config dir, optionally carrying a
# config/watch-thresholds with the given body.
make_home() {  # <name> [file body]
  local name=$1 dir
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/state" "$dir/config"
  if [ "$#" -ge 2 ]; then
    printf '%s' "$2" > "$dir/config/watch-thresholds"
  fi
  printf '%s\n' "$dir"
}

# Print one of the watcher's resolved cadence variables, read from the real
# bin/fm-watch.sh sourced in library mode (its source guard returns before the
# singleton lock and the blocking loop).
watcher_value() {  # <home> <variable name> [KEY=VALUE env ...]
  local home=$1 var=$2
  shift 2
  env "$@" \
    FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    FM_ROOT_OVERRIDE="$ROOT" \
    bash -c '
      set -u
      # shellcheck disable=SC1090
      . "$1"
      printf "%s\n" "${!2}"
    ' _ "$WATCH" "$var" 2>/dev/null
}

# Print the daemon's resolved value for one key, read from the real
# bin/fm-supervise-daemon.sh sourced in library mode so the daemon's own
# built-in default constant is the fallback under test.
daemon_value() {  # <home> <KEY> <default constant name> [KEY=VALUE env ...]
  local home=$1 key=$2 defvar=$3
  shift 3
  env "$@" \
    FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    FM_ROOT_OVERRIDE="$ROOT" \
    bash -c '
      set -u
      # shellcheck disable=SC1090
      . "$1"
      fm_watch_threshold "$2" "${!3}"
      printf "%s\n" "$FM_WATCH_THRESHOLD"
    ' _ "$DAEMON" "$key" "$defvar" 2>/dev/null
}

# Print everything the watcher writes to stderr while resolving, so the
# report-once claim is asserted on the real startup path.
watcher_stderr() {  # <home>
  local home=$1
  env FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    FM_ROOT_OVERRIDE="$ROOT" \
    bash -c '
      set -u
      # shellcheck disable=SC1090
      . "$1"
      printf "%s %s %s\n" "$SIGNAL_GRACE" "$STALE_ESCALATE_SECS" "$PAUSE_RESURFACE_SECS" >/dev/null
    ' _ "$WATCH" 2>&1 >/dev/null
}

# --- 1. precedence ----------------------------------------------------------

test_defaults_hold_with_no_file() {
  local home got
  home=$(make_home no-file)

  got=$(watcher_value "$home" SIGNAL_GRACE)
  [ "$got" = 30 ] || fail "signal grace default changed with no file present: [$got]"
  got=$(watcher_value "$home" STALE_ESCALATE_SECS)
  [ "$got" = 240 ] || fail "stale escalate default changed with no file present: [$got]"
  got=$(watcher_value "$home" PAUSE_RESURFACE_SECS)
  [ "$got" = 3600 ] || fail "pause resurface default changed with no file present: [$got]"
  got=$(daemon_value "$home" FM_HEARTBEAT_SCAN_SECS HEARTBEAT_SCAN_SECS_DEFAULT)
  [ "$got" = 300 ] || fail "heartbeat scan default changed with no file present: [$got]"

  pass "an absent config/watch-thresholds leaves every built-in default unchanged"
}

test_file_beats_default() {
  local home got
  home=$(make_home file-beats-default '# this home queues long CI runs
FM_PAUSE_RESURFACE_SECS=10800
FM_STALE_ESCALATE_SECS = 900

FM_SIGNAL_GRACE=45
FM_HEARTBEAT_SCAN_SECS=1200
')

  got=$(watcher_value "$home" PAUSE_RESURFACE_SECS)
  [ "$got" = 10800 ] || fail "the file did not set the pause resurface cadence: [$got]"
  got=$(watcher_value "$home" STALE_ESCALATE_SECS)
  [ "$got" = 900 ] || fail "the file did not set the stale escalate threshold (whitespace around = must be ignored): [$got]"
  got=$(watcher_value "$home" SIGNAL_GRACE)
  [ "$got" = 45 ] || fail "the file did not set the signal grace: [$got]"
  got=$(daemon_value "$home" FM_HEARTBEAT_SCAN_SECS HEARTBEAT_SCAN_SECS_DEFAULT)
  [ "$got" = 1200 ] || fail "the file did not set the heartbeat scan cadence: [$got]"

  pass "config/watch-thresholds beats the built-in defaults for all four keys"
}

test_environment_beats_file() {
  local home got
  home=$(make_home env-beats-file 'FM_PAUSE_RESURFACE_SECS=10800
FM_STALE_ESCALATE_SECS=900
FM_SIGNAL_GRACE=45
FM_HEARTBEAT_SCAN_SECS=1200
')

  got=$(watcher_value "$home" STALE_ESCALATE_SECS FM_STALE_ESCALATE_SECS=60)
  [ "$got" = 60 ] || fail "an explicit FM_STALE_ESCALATE_SECS did not beat the file: [$got]"
  got=$(watcher_value "$home" SIGNAL_GRACE FM_SIGNAL_GRACE=1)
  [ "$got" = 1 ] || fail "an explicit FM_SIGNAL_GRACE did not beat the file: [$got]"
  got=$(daemon_value "$home" FM_HEARTBEAT_SCAN_SECS HEARTBEAT_SCAN_SECS_DEFAULT FM_HEARTBEAT_SCAN_SECS=7)
  [ "$got" = 7 ] || fail "an explicit FM_HEARTBEAT_SCAN_SECS did not beat the file: [$got]"

  # The unset key in the same process still comes from the file, so the
  # environment override is per key rather than a whole-file bypass.
  got=$(watcher_value "$home" PAUSE_RESURFACE_SECS FM_STALE_ESCALATE_SECS=60)
  [ "$got" = 10800 ] || fail "one environment override suppressed the rest of the file: [$got]"

  # An empty environment value is not an explicit choice, exactly as the
  # pre-existing ${VAR:-default} form treated it.
  got=$(watcher_value "$home" STALE_ESCALATE_SECS FM_STALE_ESCALATE_SECS=)
  [ "$got" = 900 ] || fail "an empty environment value did not fall through to the file: [$got]"

  pass "an explicit environment value beats the file, per key"
}

# --- 2. tolerance -----------------------------------------------------------

test_malformed_file_is_tolerated() {
  local home got err
  home=$(make_home malformed 'FM_STALE_ESCALATE_SECS=900
FM_NOT_A_THRESHOLD=5
this line has no equals sign
FM_SIGNAL_GRACE=thirty
FM_PAUSE_RESURFACE_SECS=-90
=42
')

  got=$(watcher_value "$home" STALE_ESCALATE_SECS)
  [ "$got" = 900 ] || fail "a usable key was lost because other lines were unusable: [$got]"
  got=$(watcher_value "$home" SIGNAL_GRACE)
  [ "$got" = 30 ] || fail "a non-integer value was accepted instead of ignored: [$got]"
  got=$(watcher_value "$home" PAUSE_RESURFACE_SECS)
  [ "$got" = 3600 ] || fail "a negative value was accepted instead of ignored: [$got]"

  err=$(watcher_stderr "$home")
  case "$err" in
    *'fm-watch-thresholds'*) : ;;
    *) fail "unusable lines were dropped silently instead of reported: [$err]" ;;
  esac
  [ "$(printf '%s\n' "$err" | grep -c 'fm-watch-thresholds')" = 1 ] \
    || fail "the same unusable file was reported more than once in one process: [$err]"

  pass "unknown keys, malformed lines, and bad values are reported once and ignored"
}

test_unreadable_file_is_tolerated() {
  local home got
  home=$(make_home unreadable 'FM_STALE_ESCALATE_SECS=900
')
  chmod 000 "$home/config/watch-thresholds"
  if [ -r "$home/config/watch-thresholds" ]; then
    # Running as a user that bypasses the mode bit (root in some CI images):
    # the claim cannot be observed here, so do not assert a vacuous pass.
    chmod 600 "$home/config/watch-thresholds"
    pass "unreadable-file case skipped: this user can read a mode-000 file"
    return 0
  fi

  got=$(watcher_value "$home" STALE_ESCALATE_SECS)
  [ "$got" = 240 ] || fail "an unreadable file did not fall back to the built-in default: [$got]"
  got=$(watcher_value "$home" PAUSE_RESURFACE_SECS)
  [ "$got" = 3600 ] || fail "an unreadable file disturbed another key's default: [$got]"
  chmod 600 "$home/config/watch-thresholds"

  pass "an unreadable config/watch-thresholds falls back to the built-in defaults"
}

test_a_directory_in_place_of_the_file_is_tolerated() {
  local home got
  home=$(make_home directory-in-place)
  mkdir -p "$home/config/watch-thresholds"

  got=$(watcher_value "$home" STALE_ESCALATE_SECS)
  [ "$got" = 240 ] || fail "a directory in place of the file did not fall back to the default: [$got]"

  pass "a directory in place of config/watch-thresholds falls back to the built-in defaults"
}

# --- 3. the two supervisors agree -------------------------------------------

test_watcher_and_daemon_agree() {
  local home w d
  home=$(make_home agreement 'FM_STALE_ESCALATE_SECS=900
FM_PAUSE_RESURFACE_SECS=10800
')

  w=$(watcher_value "$home" STALE_ESCALATE_SECS)
  d=$(daemon_value "$home" FM_STALE_ESCALATE_SECS STALE_ESCALATE_SECS_DEFAULT)
  [ -n "$w" ] || fail "the watcher resolved no stale escalate threshold"
  [ "$w" = "$d" ] || fail "watcher and daemon disagree on the stale escalate threshold: watcher=[$w] daemon=[$d]"
  [ "$w" = 900 ] || fail "both supervisors ignored the home's stale escalate threshold: [$w]"

  w=$(watcher_value "$home" PAUSE_RESURFACE_SECS)
  d=$(daemon_value "$home" FM_PAUSE_RESURFACE_SECS FM_PAUSE_RESURFACE_SECS_DEFAULT)
  [ "$w" = "$d" ] || fail "watcher and daemon disagree on the pause resurface cadence: watcher=[$w] daemon=[$d]"
  [ "$w" = 10800 ] || fail "both supervisors ignored the home's pause resurface cadence: [$w]"

  # With no file both must still land on the same untouched defaults.
  home=$(make_home agreement-defaults)
  w=$(watcher_value "$home" STALE_ESCALATE_SECS)
  d=$(daemon_value "$home" FM_STALE_ESCALATE_SECS STALE_ESCALATE_SECS_DEFAULT)
  [ "$w" = "$d" ] && [ "$w" = 240 ] \
    || fail "watcher and daemon disagree on the default stale escalate threshold: watcher=[$w] daemon=[$d]"

  pass "the watcher and the away-mode daemon resolve the same key to the same value"
}

test_defaults_hold_with_no_file
test_file_beats_default
test_environment_beats_file
test_malformed_file_is_tolerated
test_unreadable_file_is_tolerated
test_a_directory_in_place_of_the_file_is_tolerated
test_watcher_and_daemon_agree
