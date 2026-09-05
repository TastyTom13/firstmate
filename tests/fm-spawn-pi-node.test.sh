#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh's config/pi-node wiring.
#
# `pi` is a JavaScript file whose `#!/usr/bin/env node` shebang resolves node
# through PATH. config/pi-node names one node explicitly so a Pi worker runs
# under an interpreter the operator has already authorised. These tests drive
# the real spawn path (real worktree, fake tmux capturing the literal launch
# command); nothing is ever executed from that command.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-pi-node)

# A minimal pi standing in for the real binary: answers --help (for the
# regular-TUI probe) and otherwise exits 0. fm-spawn only builds and logs the
# launch command via the fake tmux, it never runs it.
make_fake_pi() {
  local fakebin=$1
  cat > "$fakebin/pi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --help ]; then
  printf '%s\n' 'Pi 0.84.3' 'Options: --help --tui-mode <mode>'
fi
exit 0
SH
  chmod +x "$fakebin/pi"
}

# A node stand-in: given the pi stub's path it forwards the remaining
# arguments to it, so the --tui-mode probe answers the same way under the
# configured node as it does through PATH.
make_fake_node() {
  local path=$1
  mkdir -p "$(dirname "$path")"
  cat > "$path" <<'SH'
#!/usr/bin/env bash
exec /bin/bash "$@"
SH
  chmod +x "$path"
}

make_case() {
  local name=$1 id=$2 case_dir home proj wt fakebin launchlog
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake")
  make_fake_pi "$fakebin"
  fm_test_spawn_home "$home" pi
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fm_test_spawn_brief "$home" "$id"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$launchlog"
}

read_case_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG <<EOR
$1
EOR
}

run_pi_spawn() {
  local home=$1 wt=$2 fakebin=$3 launchlog=$4
  shift 4
  : > "$launchlog"
  FM_FAKE_LAUNCH_LOG="$launchlog" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" "$@" --mode no-mistakes --yolo off
}

test_absent_config_leaves_the_launch_command_untouched() {
  local rec id out status launch
  id=pi-node-absent-z1
  rec=$(make_case absent "$id")
  read_case_record "$rec"
  # No config/pi-node written.

  out=$(run_pi_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --effort low)
  status=$?
  expect_code 0 "$status" "a pi spawn with no config/pi-node should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "FM_PI_HARNESS=pi '$FAKEBIN_DIR/pi' --tui-mode regular" \
    "with config/pi-node absent the launch command must be byte-identical to today's"
  assert_not_contains "$launch" "__PINODE__" \
    "the node placeholder must never survive into the launch command"

  pass "an absent config/pi-node leaves the pi launch command exactly as it was"
}

test_valid_config_prefixes_the_configured_node() {
  local rec id out status launch node
  id=pi-node-valid-z1
  rec=$(make_case valid "$id")
  read_case_record "$rec"
  node="$CASE_DIR/fm-node"
  make_fake_node "$node"
  printf '%s\n' "$node" > "$HOME_DIR/config/pi-node"

  out=$(run_pi_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --effort low)
  status=$?
  expect_code 0 "$status" "a pi spawn with a valid config/pi-node should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "FM_PI_HARNESS=pi '$node' '$FAKEBIN_DIR/pi'" \
    "the launch command must start the resolved pi path with the configured node"
  assert_contains "$launch" "'$FAKEBIN_DIR/pi' --tui-mode regular" \
    "the regular-TUI probe must still resolve through the configured node"

  pass "a valid config/pi-node runs the resolved pi path under the configured node"
}

test_missing_node_refuses_the_spawn() {
  local rec id out status
  id=pi-node-missing-z1
  rec=$(make_case missing "$id")
  read_case_record "$rec"
  printf '%s\n' "$CASE_DIR/not-installed/fm-node" > "$HOME_DIR/config/pi-node"

  out=$(run_pi_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --effort low)
  status=$?
  expect_code 1 "$status" "config/pi-node naming a missing path should refuse the spawn"
  assert_contains "$out" "not executable" \
    "the refusal did not explain the configured node is not executable"
  [ ! -s "$LAUNCH_LOG" ] || fail "a spawn refused for a missing node still sent a launch command"

  pass "config/pi-node naming a missing path refuses before any launch command"
}

test_non_executable_node_refuses_the_spawn() {
  local rec id out status node
  id=pi-node-nonexec-z1
  rec=$(make_case nonexec "$id")
  read_case_record "$rec"
  node="$CASE_DIR/fm-node"
  printf '%s\n' '#!/usr/bin/env bash' > "$node"
  chmod 0644 "$node"
  printf '%s\n' "$node" > "$HOME_DIR/config/pi-node"

  out=$(run_pi_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --effort low)
  status=$?
  expect_code 1 "$status" "config/pi-node naming a non-executable file should refuse the spawn"
  assert_contains "$out" "$node" "the refusal did not name the configured path"
  [ ! -s "$LAUNCH_LOG" ] || fail "a spawn refused for a non-executable node still sent a launch command"

  pass "config/pi-node naming a non-executable file refuses before any launch command"
}

test_relative_path_refuses_the_spawn() {
  local rec id out status
  id=pi-node-relative-z1
  rec=$(make_case relative "$id")
  read_case_record "$rec"
  printf '%s\n' 'fm-node' > "$HOME_DIR/config/pi-node"

  out=$(run_pi_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --effort low)
  status=$?
  expect_code 1 "$status" "a relative config/pi-node path should refuse the spawn"
  assert_contains "$out" "must hold one absolute path" \
    "the refusal did not explain an absolute path is required"
  [ ! -s "$LAUNCH_LOG" ] || fail "a spawn refused for a relative node path still sent a launch command"

  pass "a relative config/pi-node path refuses before any launch command"
}

test_comments_and_whitespace_are_ignored() {
  local rec id out status launch node
  id=pi-node-comments-z1
  rec=$(make_case comments "$id")
  read_case_record "$rec"
  node="$CASE_DIR/fm-node"
  make_fake_node "$node"
  {
    printf '%s\n' '# the node this home launches Pi workers under'
    printf '\n'
    printf '   %s   \n' "$node"
  } > "$HOME_DIR/config/pi-node"

  out=$(run_pi_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --effort low)
  status=$?
  expect_code 0 "$status" "a config/pi-node with comments and padding should still spawn"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "FM_PI_HARNESS=pi '$node' '$FAKEBIN_DIR/pi'" \
    "the configured node was not read past the comment, blank line, and surrounding padding"

  pass "comment lines, blank lines, and surrounding whitespace do not break config/pi-node"
}

test_raw_launch_command_is_left_alone() {
  local rec id out status launch
  id=pi-node-raw-z1
  rec=$(make_case raw "$id")
  read_case_record "$rec"
  # A broken config that the raw launch command could never have used: the
  # escape hatch must be neither refused nor rewritten for it.
  printf '%s\n' "$CASE_DIR/not-installed/fm-node" > "$HOME_DIR/config/pi-node"

  out=$(run_pi_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" "pi --resume" --effort low)
  status=$?
  expect_code 0 "$status" "a raw launch command should spawn regardless of config/pi-node"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "pi --resume" "the raw launch command was not sent verbatim"
  assert_not_contains "$launch" "fm-node" \
    "a raw launch command must never be rewritten by config/pi-node"

  pass "a raw launch command is neither refused nor rewritten by config/pi-node"
}

test_absent_config_leaves_the_launch_command_untouched
test_valid_config_prefixes_the_configured_node
test_missing_node_refuses_the_spawn
test_non_executable_node_refuses_the_spawn
test_relative_path_refuses_the_spawn
test_comments_and_whitespace_are_ignored
test_raw_launch_command_is_left_alone
