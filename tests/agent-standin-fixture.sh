# shellcheck shell=bash
# tests/agent-standin-fixture.sh - a live process that keeps a harness name.
#
# Liveness tests need a live process whose executable identity is a harness
# name (`pi`, `claude`, ...). The construction is a SYMLINK named after the
# harness whose target is a real native binary, never a copy: a copied platform
# binary fails code-signing validation and is killed on macOS arm64, and the
# symlink name is what the kernel records as the executable identity.
#
# The target must not dispatch on its own argv[0]. A multicall coreutils binary
# does: busybox resolves the applet from argv[0], and uutils (the default
# coreutils on Ubuntu 26.04) refuses outright with "Security violation:
# Requested utility `pi` does not match executable name". Through such a
# symlink no process stays alive and every positive liveness case reads as not
# alive. So the stand-in is a dedicated spinner compiled here, and the host's
# `sleep` is used only when it demonstrably survives the rename.
#
# Sourcing this file defines functions only.

# fm_agent_standin_alive <path>: the binary stays alive for a moment when run.
fm_agent_standin_alive() {
  local pid
  "$1" 60 >/dev/null 2>&1 &
  pid=$!
  sleep 0.2
  kill -0 "$pid" 2>/dev/null || { wait "$pid" 2>/dev/null; return 1; }
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

# fm_agent_standin <dir>
# Prints the path of a binary under <dir> that, run through a symlink of any
# name with a seconds argument like `sleep`, stays alive for that long (600s
# without one). Reuses the binary an earlier call built in the same <dir>.
# Returns nonzero when this host has neither a C compiler nor a `sleep` that
# survives a rename; the caller decides whether that skips or fails.
fm_agent_standin() {
  local dir=$1 cc_bin sleep_bin
  if [ -x "$dir/standin" ] && fm_agent_standin_alive "$dir/standin"; then
    printf '%s\n' "$dir/standin"
    return 0
  fi
  mkdir -p "$dir" || return 1
  rm -f "$dir/standin"
  cc_bin=$(command -v cc 2>/dev/null || command -v gcc 2>/dev/null || true)
  if [ -n "$cc_bin" ] &&
    printf '%s\n' '#include <stdlib.h>' '#include <unistd.h>' \
      'int main(int argc, char **argv){int i, n = argc > 1 ? atoi(argv[1]) : 600; for (i = 0; i < n; i++) sleep(1); return 0;}' \
      > "$dir/standin.c" &&
    "$cc_bin" -o "$dir/standin" "$dir/standin.c" 2>/dev/null &&
    fm_agent_standin_alive "$dir/standin"; then
    printf '%s\n' "$dir/standin"
    return 0
  fi
  rm -f "$dir/standin"
  sleep_bin=$(command -v sleep 2>/dev/null) || return 1
  ln -s "$sleep_bin" "$dir/standin" 2>/dev/null || return 1
  if fm_agent_standin_alive "$dir/standin"; then
    printf '%s\n' "$dir/standin"
    return 0
  fi
  rm -f "$dir/standin"
  return 1
}
