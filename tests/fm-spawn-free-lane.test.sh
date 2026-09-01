#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh's free-tier lane wiring (fm-free-lane-spawn-wiring).
#
# A dispatch profile routes a whole pi crewmate through a free-tier lane by
# naming that lane's own provider/model as --model - no new profile field, the
# same string docs/free-tier-routing.md's dispatch rule already ships. These
# tests drive the real spawn path (real worktree, fake tmux capturing the
# literal launch command).
#
# The launcher itself is a hand-written stand-in, not a real generated
# `av inject` launcher: that shape is already covered by
# tests/fm-free-lane-run.test.sh, and a generated launcher's shebang line
# embeds an absolute interpreter path plus all four lane keys, which this
# machine's kernel silently mis-execs (falls back to running the launcher's
# BODY as a literal shell script, skipping the interpreter entirely, no
# error) once that line crosses a length this suite's own tmp-root prefix
# reliably exceeds - verified empirically, not documented, and not worth
# chasing here. What these tests exist to prove is fm-spawn's OWN behavior:
# detecting a free-lane model, bounding the wait, surfacing the probe's
# stderr, and wrapping the real launch command - so each stand-in just needs
# fm-spawn's static "looks like a launcher" shape (a "#!" line naming
# "av inject") and the exact observable behavior (fast success, fast
# failure, or a hang) that behavior is under test.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-free-lane)

# A minimal pi standing in for the real binary: answers --help (for the
# regular-TUI probe) and otherwise just exits 0. It is never actually
# executed by these tests - fm-spawn only builds and logs the launch command
# via the fake tmux, it does not run it.
make_fake_pi() {
  local fakebin=$1
  cat > "$fakebin/pi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --help ]; then
  printf '%s\n' 'Pi 0.84.0' 'Options: --help --tui-mode <mode>'
fi
exit 0
SH
  chmod +x "$fakebin/pi"
}

# fm_test_make_spawn_fakebin already installs the spawn-world tmux; add pi.
make_free_lane_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_test_make_spawn_fakebin "$dir")
  make_fake_pi "$fakebin"
  printf '%s\n' "$fakebin"
}

make_case() {
  local name=$1 id=$2 case_dir home proj wt fakebin launchlog
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  fakebin=$(make_free_lane_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" pi
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fm_test_spawn_brief "$home" "$id"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$launchlog"
}

read_case_record() {
  # shellcheck disable=SC2034  # CASE_DIR is part of the shared record shape; unused by these tests
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG <<EOF
$1
EOF
}

# A stand-in for the real `av` binary, used as the launcher stand-ins'
# shebang interpreter so their FIRST line genuinely names "av inject", the
# way a generated launcher's does. Darwin hands the whole shebang tail to the
# interpreter as one argument, so dropping $1 leaves the launcher path and
# its own arguments, which is all these stand-ins need to run.
make_fake_av() {
  cat > "$TMP_ROOT/av" <<'SH'
#!/usr/bin/env bash
shift
exec /bin/bash "$@"
SH
  chmod +x "$TMP_ROOT/av"
}

# Writes a launcher stand-in at HOME_DIR/config/free-lane-launcher whose
# shebang line satisfies fm-spawn.sh's static shape check (a "#!" line naming
# "av inject") and whose body is the caller's own script, so the free-lane
# preflight probe exercises exactly the behavior under test.
write_launcher_stub() {
  local home=$1 body=$2
  make_fake_av
  mkdir -p "$home/config"
  {
    printf '#!%s inject +GROQ_API_KEY -- /bin/bash\n' "$TMP_ROOT/av"
    printf '%s\n' "$body"
  } > "$home/config/free-lane-launcher"
  chmod +x "$home/config/free-lane-launcher"
}

run_free_lane_spawn() {
  local home=$1 wt=$2 fakebin=$3 launchlog=$4
  shift 4
  : > "$launchlog"
  FM_FAKE_LAUNCH_LOG="$launchlog" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" "$@" --mode no-mistakes --yolo off
}

test_paid_pi_model_is_completely_unaffected() {
  local rec id out status launch
  id=free-lane-paid-z1
  rec=$(make_case paid "$id")
  read_case_record "$rec"

  out=$(run_free_lane_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --model openai-codex/gpt-5.6-sol --effort max)
  status=$?
  expect_code 0 "$status" "an ordinary paid pi model spawn should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "FM_PI_HARNESS=pi '$FAKEBIN_DIR/pi' --tui-mode regular --model 'openai-codex/gpt-5.6-sol' --thinking 'max' -e" \
    "a paid model's launch command must be byte-identical to the pre-existing pi shape"
  assert_not_contains "$launch" "free-lane-launcher" \
    "a paid model must never be routed through the free-lane launcher"
  assert_not_contains "$launch" "  " \
    "a paid model launch must not carry a stray double space from the free-lane placeholder"

  pass "a paid pi model spawns exactly as before, with no free-lane probing at all"
}

test_free_lane_model_with_no_launcher_refuses_before_launch() {
  local rec id out status
  id=free-lane-no-launcher-z1
  rec=$(make_case no-launcher "$id")
  read_case_record "$rec"
  # No launcher installed at HOME_DIR/config/free-lane-launcher.

  out=$(run_free_lane_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --model groq/openai/gpt-oss-120b --effort low)
  status=$?
  expect_code 1 "$status" "a free-lane model with no launcher installed should refuse"
  assert_contains "$out" "not installed" "the refusal did not explain the launcher is missing"
  [ ! -s "$LAUNCH_LOG" ] || fail "a spawn refused for a missing launcher still sent a launch command"

  pass "a free-lane model refuses before any launch command when the launcher is not installed"
}

test_free_lane_model_with_a_malformed_launcher_refuses() {
  local rec id out status
  id=free-lane-malformed-z1
  rec=$(make_case malformed "$id")
  read_case_record "$rec"
  mkdir -p "$HOME_DIR/config"
  printf '#!/usr/bin/env bash\necho not a real launcher\n' > "$HOME_DIR/config/free-lane-launcher"
  chmod +x "$HOME_DIR/config/free-lane-launcher"

  out=$(run_free_lane_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --model groq/openai/gpt-oss-120b --effort low)
  status=$?
  expect_code 1 "$status" "a launcher whose shebang is not an av inject line should refuse"
  assert_contains "$out" "does not look like a generated free-lane launcher" \
    "the refusal did not explain the launcher's shape is wrong"
  [ ! -s "$LAUNCH_LOG" ] || fail "a spawn refused for a malformed launcher still sent a launch command"

  pass "a launcher that is not shaped like a generated av-inject launcher refuses"
}

test_free_lane_model_with_absent_vault_key_refuses_fast() {
  local rec id out status
  id=free-lane-absent-key-z1
  rec=$(make_case absent-key "$id")
  read_case_record "$rec"
  write_launcher_stub "$HOME_DIR" \
    'echo "error: lane '"'"'groq'"'"' needs GROQ_API_KEY in the environment" >&2
exit 3'

  out=$(FM_FREE_LANE_PREFLIGHT_TIMEOUT=3 \
    run_free_lane_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --model groq/openai/gpt-oss-120b --effort low)
  status=$?
  expect_code 1 "$status" "a free-lane model with an absent vault key should refuse"
  assert_contains "$out" "GROQ_API_KEY" "the refusal did not name the missing key"
  [ ! -s "$LAUNCH_LOG" ] || fail "a spawn refused for an absent vault key still sent a launch command"

  pass "a free-lane model refuses fast, naming the missing vault key, when it is absent from the vault"
}

test_unblessed_launcher_times_out_and_refuses() {
  local rec id out status start end elapsed
  id=free-lane-unblessed-z1
  rec=$(make_case unblessed "$id")
  read_case_record "$rec"
  write_launcher_stub "$HOME_DIR" \
    'echo "automic vault: human approval required" >&2
exec sleep 3600'

  start=$(date +%s)
  out=$(FM_FREE_LANE_PREFLIGHT_TIMEOUT=2 \
    run_free_lane_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --model groq/openai/gpt-oss-120b --effort low)
  status=$?
  end=$(date +%s)
  elapsed=$((end - start))

  expect_code 1 "$status" "an unblessed launcher should refuse the spawn"
  assert_contains "$out" "av bless" "the refusal did not point at the av bless remedy"
  [ "$elapsed" -lt 8 ] || fail "the bounded probe did not bound the wait (took ${elapsed}s)"
  [ ! -s "$LAUNCH_LOG" ] || fail "a spawn refused for an unblessed launcher still sent a launch command"

  pass "an unblessed launcher refuses within the bounded probe window instead of hanging the spawn"
}

test_blessed_launcher_with_key_present_wraps_the_real_launch() {
  local rec id out status launch
  id=free-lane-success-z1
  rec=$(make_case success "$id")
  read_case_record "$rec"
  write_launcher_stub "$HOME_DIR" 'shift 3
exec "$@"'

  out=$(FM_FREE_LANE_PREFLIGHT_TIMEOUT=3 \
    run_free_lane_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --model groq/openai/gpt-oss-120b --effort low)
  status=$?
  expect_code 0 "$status" "a blessed launcher with its key present should spawn"

  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "$HOME_DIR/config/free-lane-launcher' --exec 'groq' -- '$FAKEBIN_DIR/pi'" \
    "the real pi launch was not wrapped through the blessed launcher's --exec mode"
  assert_contains "$launch" "--model 'groq/openai/gpt-oss-120b'" \
    "the wrapped launch did not carry the lane's model"

  pass "a blessed launcher with its key present wraps the real pi launch through --exec"
}

test_raw_launch_command_is_left_alone() {
  local rec id out status launch
  id=free-lane-raw-launch-z1
  rec=$(make_case raw-launch "$id")
  read_case_record "$rec"
  # No launcher installed: the raw-launch escape hatch must not be refused for
  # a launcher it could never have used.

  out=$(run_free_lane_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" "pi --resume" --model groq/openai/gpt-oss-120b --effort low)
  status=$?
  expect_code 0 "$status" "a raw launch command should spawn even with no free-lane launcher installed"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "pi --resume" "the raw launch command was not sent verbatim"
  assert_not_contains "$launch" "free-lane-launcher" \
    "a raw launch command must never be routed through the free-lane launcher"

  pass "a raw launch command is neither wrapped nor refused by the free-lane path"
}

test_secondmate_pinned_to_a_free_lane_model_is_wrapped() {
  local rec id out status launch sm_home
  id=free-lane-secondmate-z1
  rec=$(make_case secondmate "$id")
  read_case_record "$rec"
  printf 'pi groq/openai/gpt-oss-120b low\n' > "$HOME_DIR/config/secondmate-harness"
  write_launcher_stub "$HOME_DIR" 'shift 3
exec "$@"'
  sm_home="$CASE_DIR/sm"
  mkdir -p "$sm_home/bin" "$sm_home/data"
  printf '# Firstmate\n' > "$sm_home/AGENTS.md"
  printf '%s\n' "$id" > "$sm_home/.fm-secondmate-home"
  printf 'charter for %s\n' "$id" > "$sm_home/data/charter.md"

  : > "$LAUNCH_LOG"
  out=$(FM_FREE_LANE_PREFLIGHT_TIMEOUT=3 FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" \
    fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$sm_home" --secondmate)
  status=$?
  expect_code 0 "$status" "a secondmate pinned to a free-lane model should spawn"

  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "$HOME_DIR/config/free-lane-launcher' --exec 'groq' -- " \
    "a secondmate's pinned free-lane model was launched without the blessed launcher wrap"

  pass "a secondmate pinned to a free-lane model is wrapped through the blessed launcher"
}

# The lane table has a single owner (bin/fm-free-lane-run.sh --list). If that
# sibling cannot be read at all, a pi spawn cannot know whether its --model is
# a free lane, so it must refuse rather than launch unwrapped with no key.
# Driving that needs fm-spawn's OWN sibling lookup to fail, so this case runs
# fm-spawn from a mirrored root whose bin/ is symlinks to the real ones except
# for a fm-free-lane-run.sh stand-in that fails.
make_broken_lane_table_root() {
  local case_dir=$1 mirror entry
  mirror="$case_dir/root"
  mkdir -p "$mirror/bin"
  for entry in "$ROOT"/* "$ROOT"/.[!.]*; do
    [ -e "$entry" ] || continue
    [ "$(basename "$entry")" != bin ] || continue
    ln -s "$entry" "$mirror/$(basename "$entry")"
  done
  for entry in "$ROOT"/bin/*; do
    [ "$(basename "$entry")" != fm-free-lane-run.sh ] || continue
    ln -s "$entry" "$mirror/bin/$(basename "$entry")"
  done
  cat > "$mirror/bin/fm-free-lane-run.sh" <<'SH'
#!/usr/bin/env bash
echo "error: lane table unavailable" >&2
exit 9
SH
  chmod +x "$mirror/bin/fm-free-lane-run.sh"
  printf '%s\n' "$mirror"
}

test_unreadable_lane_table_refuses_instead_of_launching_unwrapped() {
  local rec id mirror out status
  id=free-lane-broken-table-z1
  rec=$(make_case broken-table "$id")
  read_case_record "$rec"
  mirror=$(make_broken_lane_table_root "$CASE_DIR")
  write_launcher_stub "$HOME_DIR" 'shift 3
exec "$@"'

  : > "$LAUNCH_LOG"
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" TMUX="${TMUX:-fake,1,0}" \
    FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" PATH="$FAKEBIN_DIR:$PATH" \
    "$mirror/bin/fm-spawn.sh" "$id" "$PROJ_DIR" --model groq/openai/gpt-oss-120b --effort low \
    --mode no-mistakes --yolo off 2>&1)
  status=$?
  expect_code 1 "$status" "an unreadable lane table should refuse the spawn"
  assert_contains "$out" "cannot read the free-tier lane table" \
    "the refusal did not explain the lane table could not be read"
  [ ! -s "$LAUNCH_LOG" ] || fail "a spawn whose lane table could not be read still sent a launch command"

  pass "an unreadable lane table refuses instead of launching a possible free-lane model unwrapped"
}

test_paid_pi_model_is_completely_unaffected
test_free_lane_model_with_no_launcher_refuses_before_launch
test_free_lane_model_with_a_malformed_launcher_refuses
test_free_lane_model_with_absent_vault_key_refuses_fast
test_unblessed_launcher_times_out_and_refuses
test_blessed_launcher_with_key_present_wraps_the_real_launch
test_secondmate_pinned_to_a_free_lane_model_is_wrapped
test_raw_launch_command_is_left_alone
test_unreadable_lane_table_refuses_instead_of_launching_unwrapped
