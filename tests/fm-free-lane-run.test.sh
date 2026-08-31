#!/usr/bin/env bash
# Behavior tests for fm-free-lane-run.sh: every lane is listed with the env var
# it needs, an unknown lane and a bare invocation are usage errors, a lane whose
# key is absent refuses without launching pi, a lane whose key is present
# launches pi with that lane's provider and model, and --install-launcher writes
# an executable launcher whose shebang names the operator's av path and exactly
# the four lane keys while refusing an av path a shebang cannot express.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RUNNER="$ROOT/bin/fm-free-lane-run.sh"
TMP_ROOT=$(fm_test_tmproot fm-free-lane-run)

# A fake pi that records the arguments it was launched with, so the test
# observes the runner's dispatch through the public command interface.
make_fakebin() {
  local dir=$1
  mkdir -p "$dir"
  cat > "$dir/pi" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$FM_TEST_PI_ARGS"
FAKE
  chmod +x "$dir/pi"
}

test_list_names_every_lane_and_its_variable() {
  local out
  out=$("$RUNNER" --list) || fail "--list did not exit 0"

  local lane
  for lane in groq cerebras cloudflare openrouter; do
    assert_contains "$out" "$lane" "--list omitted the $lane lane"
  done
  for lane in GROQ_API_KEY CEREBRAS_API_KEY CLOUDFLARE_API_KEY OPENROUTER_API_KEY; do
    assert_contains "$out" "$lane" "--list omitted the $lane variable"
  done

  pass "--list names every lane and the variable it needs"
}

test_usage_errors_are_distinct_from_lane_failures() {
  local status

  status=0
  "$RUNNER" >/dev/null 2>&1 || status=$?
  expect_code 2 "$status" "a bare invocation was not a usage error"

  status=0
  "$RUNNER" --help >/dev/null 2>&1 || status=$?
  expect_code 2 "$status" "--help was not a usage error"

  status=0
  "$RUNNER" nosuchlane >/dev/null 2>&1 || status=$?
  expect_code 2 "$status" "an unknown lane was not a usage error"

  pass "a bare invocation, --help, and an unknown lane all exit 2"
}

test_absent_key_refuses_without_launching_pi() {
  local dir status err
  dir="$TMP_ROOT/absent-key"
  make_fakebin "$dir/bin"
  err="$dir/err.txt"
  export FM_TEST_PI_ARGS="$dir/pi-args.txt"

  status=0
  env -u GROQ_API_KEY PATH="$dir/bin:$PATH" "$RUNNER" groq -p "hi" \
    >/dev/null 2>"$err" || status=$?

  expect_code 3 "$status" "an absent lane key did not refuse with exit 3"
  assert_contains "$(cat "$err")" "GROQ_API_KEY" \
    "the refusal did not name the missing variable"
  [ ! -e "$FM_TEST_PI_ARGS" ] \
    || fail "the runner launched pi despite the lane key being absent"

  unset FM_TEST_PI_ARGS
  pass "a lane with no key refuses with exit 3 and never launches pi"
}

test_present_key_dispatches_that_lanes_provider_and_model() {
  local dir args
  dir="$TMP_ROOT/present-key"
  make_fakebin "$dir/bin"
  export FM_TEST_PI_ARGS="$dir/pi-args.txt"

  CLOUDFLARE_API_KEY=not-a-real-value PATH="$dir/bin:$PATH" \
    "$RUNNER" cloudflare -p "hi" >/dev/null 2>&1 \
    || fail "a lane with its key present did not dispatch"

  args=$(cat "$FM_TEST_PI_ARGS")
  assert_contains "$args" "--provider" "the runner did not pass --provider to pi"
  assert_contains "$args" "cloudflare" "the runner did not pass the lane's provider"
  assert_contains "$args" "@cf/openai/gpt-oss-120b" \
    "the runner did not pass the lane's model"
  assert_contains "$args" "hi" "the runner dropped the caller's own arguments"

  unset FM_TEST_PI_ARGS
  pass "a lane with its key present dispatches that lane's provider and model"
}

test_install_launcher_writes_a_blessable_shebang() {
  local dir launcher shebang
  dir="$TMP_ROOT/launcher"
  mkdir -p "$dir/config" "$dir/avbin"
  : > "$dir/avbin/av"
  chmod +x "$dir/avbin/av"

  FM_CONFIG_OVERRIDE="$dir/config" "$RUNNER" --install-launcher --av "$dir/avbin/av" \
    >/dev/null 2>&1 || fail "--install-launcher did not exit 0"

  launcher="$dir/config/free-lane-launcher"
  [ -x "$launcher" ] || fail "--install-launcher did not write an executable launcher"

  shebang=$(head -1 "$launcher")
  # The runner canonicalizes the av path, because av bless refuses a
  # non-canonical script interpreter.
  local canonical_av
  canonical_av="$(cd "$dir/avbin" && pwd -P)/av"
  assert_contains "$shebang" "$canonical_av" \
    "the launcher shebang did not name the operator's own canonical av path"
  assert_contains "$shebang" "inject" "the launcher shebang was not an av inject line"

  local key
  for key in GROQ_API_KEY CEREBRAS_API_KEY CLOUDFLARE_API_KEY OPENROUTER_API_KEY; do
    assert_contains "$shebang" "+$key" "the launcher shebang omitted +$key"
  done

  assert_grep "fm-free-lane-run.sh" "$launcher" \
    "the launcher does not hand off to the tracked runner"
  assert_not_contains "$(cat "$launcher")" "not-a-real-value" \
    "the launcher captured a value instead of a variable name"

  pass "--install-launcher writes an executable av inject launcher naming every lane key"
}

test_install_launcher_refuses_an_unexpressible_av_path() {
  local dir status err
  dir="$TMP_ROOT/launcher-spaces"
  mkdir -p "$dir/config" "$dir/av bin"
  : > "$dir/av bin/av"
  chmod +x "$dir/av bin/av"
  err="$dir/err.txt"

  status=0
  FM_CONFIG_OVERRIDE="$dir/config" "$RUNNER" --install-launcher --av "$dir/av bin/av" \
    >/dev/null 2>"$err" || status=$?

  expect_code 2 "$status" "an av path a shebang cannot express was accepted"
  assert_contains "$(cat "$err")" "whitespace" \
    "the refusal did not explain why the av path is unusable"
  [ ! -e "$dir/config/free-lane-launcher" ] \
    || fail "a launcher was written despite the av path being unusable"

  pass "an av path a shebang cannot express refuses instead of writing a broken launcher"
}

test_list_names_every_lane_and_its_variable
test_usage_errors_are_distinct_from_lane_failures
test_absent_key_refuses_without_launching_pi
test_present_key_dispatches_that_lanes_provider_and_model
test_install_launcher_writes_a_blessable_shebang
test_install_launcher_refuses_an_unexpressible_av_path
