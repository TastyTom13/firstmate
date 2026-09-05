#!/usr/bin/env bash
# tests/bridge-watcher-reap.sh - reap bridge-ownership watchers a test run started.
#
# Any test that runs a real fm-spawn also starts a real bridge-ownership watcher
# for that task (bin/fm-spawn.sh). Those watchers are backgrounded and
# reparented, so nothing else in the run reaps them: without this, a suite that
# spawns dozens of tasks leaves dozens of process-table scanners behind and
# buries the host.
#
# This lives in its own file rather than in tests/lib.sh because the suites that
# spawn the most real tasks (the live-backend Herdr e2e files) do not source the
# shared library at all, and the reap has to be available to them too.
#
# Only watchers whose state-dir argument is one of THIS run's fixture roots are
# killed, so a concurrent suite's or a real task's watcher is never touched.
fm_test_kill_bridge_watchers() {  # <fixture-root>...
  local root real pid args
  command -v pgrep >/dev/null 2>&1 || return 0
  for root in "$@"; do
    [ -n "$root" ] || continue
    # A spawn records the physical path, while mktemp hands back the symlinked
    # one (/var/folders vs /private/var/folders on macOS), so match both or the
    # reap silently matches nothing on the platform that needs it most.
    real=$(cd "$root" 2>/dev/null && pwd -P) || real=
    while IFS= read -r pid; do
      [ -n "$pid" ] || continue
      args=$(ps -p "$pid" -o command= 2>/dev/null) || continue
      case "$args" in
        *"fm-chrome-bridge-sweep.sh --watch-owner "*) ;;
        *) continue ;;
      esac
      case "$args" in
        *"$root"*) kill "$pid" 2>/dev/null || true; continue ;;
      esac
      if [ -n "$real" ] && [ "$real" != "$root" ]; then
        case "$args" in
          *"$real"*) kill "$pid" 2>/dev/null || true ;;
        esac
      fi
    done < <(pgrep -f "fm-chrome-bridge-sweep.sh --watch-owner" 2>/dev/null)
  done
}
