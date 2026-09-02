#!/usr/bin/env bash
# Behavior tests for fm-free-lane-run.sh: every lane is listed with the env var
# it needs, an unknown lane and a bare invocation are usage errors, a lane whose
# key is absent refuses without launching pi, a lane whose key is present
# launches pi with that lane's provider and model, and --install-launcher writes
# an executable launcher whose shebang names the operator's av path and exactly
# the four lane keys while refusing an av path a shebang cannot express.
# The cloudflare lane additionally refuses when the account segment of its pi
# provider baseUrl is still an unfilled blank, while every shape problem in
# that models file warns and dispatches anyway.
# The lane pi starts sees only the invoked lane's own key, never the other
# three, it carries the FM_FREE_LANE_ACTIVE marker, a lane invocation that
# already sees that marker refuses with exit 4, and the generated launcher
# records variable names rather than values.
# Every lane dispatch also passes a slim --system-prompt, --no-builtin-tools,
# --no-context-files, and --no-extensions to pi instead of its default
# coding-agent prompt, tool set, AGENTS.md/CLAUDE.md auto-discovery, and
# extension discovery, and a caller can still override the default system
# prompt with its own flag, because the runner's own flags always precede the
# caller's and pi takes the last occurrence.
# A fake pi accepts whatever argv it is handed, so that those four flags still
# mean what the runner assumes is proven separately against the real binary by
# tests/fm-free-lane-slim-prompt-live-e2e.test.sh.
# --exec <lane> -- <command...> shares the default form's key-presence check,
# cloudflare guard, narrowing, and re-entry guard, but runs the caller's own
# command verbatim instead of a hardcoded slim-prompt pi invocation - the
# worker-spawn path bin/fm-spawn.sh drives.
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
env | grep -E '^(GROQ|CEREBRAS|CLOUDFLARE|OPENROUTER)_API_KEY=|^FM_FREE_LANE_ACTIVE=' \
  > "$FM_TEST_PI_ARGS.env" || : > "$FM_TEST_PI_ARGS.env"
FAKE
  chmod +x "$dir/pi"
}

# Writes a pi models file at the path pi itself resolves from
# PI_CODING_AGENT_DIR, carrying one cloudflare baseUrl.
write_models() {
  local agent_dir=$1 base_url=$2
  mkdir -p "$agent_dir"
  printf '{"providers":{"cloudflare":{"baseUrl":"%s","api":"openai-completions"}}}\n' \
    "$base_url" > "$agent_dir/models.json"
}

# Resolves a repeated flag the way pi itself does, taking the last
# occurrence, from the argv the fake pi recorded one argument per line.
last_flag_value() {  # <argv-file> <flag>
  local file=$1 flag=$2 line value="" take=0
  while IFS= read -r line; do
    if [ "$take" = 1 ]; then
      value=$line
      take=0
    elif [ "$line" = "$flag" ]; then
      take=1
    fi
  done < "$file"
  printf '%s' "$value"
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

  write_models "$dir/pi" "https://api.cloudflare.com/client/v4/accounts/abc123/ai/v1"
  CLOUDFLARE_API_KEY=not-a-real-value PI_CODING_AGENT_DIR="$dir/pi" \
    PATH="$dir/bin:$PATH" "$RUNNER" cloudflare -p "hi" >/dev/null 2>&1 \
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

  (
    export GROQ_API_KEY=sentinel-groq-9f1 CEREBRAS_API_KEY=sentinel-cerebras-9f2
    export CLOUDFLARE_API_KEY=sentinel-cloudflare-9f3 OPENROUTER_API_KEY=sentinel-openrouter-9f4
    FM_CONFIG_OVERRIDE="$dir/config" "$RUNNER" --install-launcher --av "$dir/avbin/av" \
      >/dev/null 2>&1
  ) || fail "--install-launcher did not exit 0"

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
  local sentinel
  for sentinel in sentinel-groq-9f1 sentinel-cerebras-9f2 sentinel-cloudflare-9f3 \
    sentinel-openrouter-9f4; do
    assert_not_contains "$(cat "$launcher")" "$sentinel" \
      "the launcher captured the value of a lane key instead of its name"
  done

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




test_launcher_works_from_a_root_whose_path_has_a_space() {
  local dir root args installed
  dir="$TMP_ROOT/launcher-spaced-root"
  root="$dir/fm home"
  mkdir -p "$root/bin" "$root/config" "$dir/avbin" "$dir/bin"
  cp "$RUNNER" "$root/bin/fm-free-lane-run.sh"
  chmod +x "$root/bin/fm-free-lane-run.sh"
  : > "$dir/avbin/av"
  chmod +x "$dir/avbin/av"
  make_fakebin "$dir/bin"
  export FM_TEST_PI_ARGS="$dir/pi-args.txt"

  installed=$(FM_CONFIG_OVERRIDE="$root/config" "$root/bin/fm-free-lane-run.sh" \
    --install-launcher --av "$dir/avbin/av" 2>&1) \
    || fail "--install-launcher did not exit 0 from a root path containing a space"

  # The generated launcher is run through bash so the test exercises its own
  # body, not the machine's av interpreter.
  GROQ_API_KEY=not-a-real-value PATH="$dir/bin:$PATH" \
    bash "$root/config/free-lane-launcher" groq -p "hi" >/dev/null 2>&1 \
    || fail "the generated launcher could not reach a runner under a spaced path"

  args=$(cat "$FM_TEST_PI_ARGS")
  assert_contains "$args" "openai/gpt-oss-120b" \
    "the launcher did not dispatch the groq lane's model"

  assert_contains "$installed" "av bless '$root/config/free-lane-launcher'" \
    "the printed av bless command did not quote a launcher path containing a space"

  unset FM_TEST_PI_ARGS

  pass "a generated launcher works when the firstmate root path contains a space"
}

test_install_launcher_rejects_arguments_it_does_not_recognise() {
  local dir status
  dir="$TMP_ROOT/launcher-bad-args"
  mkdir -p "$dir/config" "$dir/avbin"
  : > "$dir/avbin/av"
  chmod +x "$dir/avbin/av"

  status=0
  FM_CONFIG_OVERRIDE="$dir/config" "$RUNNER" --install-launcher "$dir/avbin/av" \
    >/dev/null 2>&1 || status=$?
  expect_code 2 "$status" "a bare path after --install-launcher was not a usage error"

  status=0
  FM_CONFIG_OVERRIDE="$dir/config" "$RUNNER" --install-launcher --nope \
    >/dev/null 2>&1 || status=$?
  expect_code 2 "$status" "an unknown flag after --install-launcher was not a usage error"

  status=0
  FM_CONFIG_OVERRIDE="$dir/config" "$RUNNER" --install-launcher --av "$dir/avbin/av" extra \
    >/dev/null 2>&1 || status=$?
  expect_code 2 "$status" "an extra trailing argument was not a usage error"

  [ ! -e "$dir/config/free-lane-launcher" ] \
    || fail "a launcher was written despite the arguments being a usage error"

  pass "--install-launcher rejects every argument it does not recognise with exit 2"
}

test_cloudflare_refuses_an_unfilled_account_segment() {
  local dir status err blank
  dir="$TMP_ROOT/cloudflare-unfilled"
  make_fakebin "$dir/bin"

  # shellcheck disable=SC2016  # the unexpanded reference is the input under test
  for blank in '' '${CLOUDFLARE_ACCOUNT_ID}' '$CLOUDFLARE_ACCOUNT_ID' '<your-cloudflare-account-id>'; do
    err="$dir/err.txt"
    export FM_TEST_PI_ARGS="$dir/pi-args.txt"
    rm -f "$FM_TEST_PI_ARGS"
    write_models "$dir/pi" "https://api.cloudflare.com/client/v4/accounts/$blank/ai/v1"

    status=0
    CLOUDFLARE_API_KEY=not-a-real-value PI_CODING_AGENT_DIR="$dir/pi" \
      PATH="$dir/bin:$PATH" "$RUNNER" cloudflare -p "hi" \
      >/dev/null 2>"$err" || status=$?

    expect_code 3 "$status" "an unfilled account segment '$blank' did not refuse"
    assert_contains "$(cat "$err")" "$dir/pi/models.json" \
      "the refusal did not name the models file to fix"
    [ ! -e "$FM_TEST_PI_ARGS" ] \
      || fail "the runner launched pi despite the unfilled account segment '$blank'"
  done

  unset FM_TEST_PI_ARGS
  pass "every unfilled cloudflare account segment refuses with exit 3 and never launches pi"
}

test_cloudflare_shape_problems_warn_and_still_dispatch() {
  local dir err args case_name
  dir="$TMP_ROOT/cloudflare-shapes"
  make_fakebin "$dir/bin"
  export FM_TEST_PI_ARGS="$dir/pi-args.txt"

  for case_name in missing malformed no-provider no-base-url; do
    local agent_dir="$dir/$case_name"
    mkdir -p "$agent_dir"
    case $case_name in
      missing) ;;
      malformed) printf 'not json at all\n' > "$agent_dir/models.json" ;;
      no-provider) printf '{"providers":{"groq":{"baseUrl":"https://api.groq.com/openai/v1"}}}\n' \
        > "$agent_dir/models.json" ;;
      no-base-url) printf '{"providers":{"cloudflare":{"api":"openai-completions"}}}\n' \
        > "$agent_dir/models.json" ;;
    esac

    rm -f "$FM_TEST_PI_ARGS"
    err="$dir/$case_name-err.txt"
    CLOUDFLARE_API_KEY=not-a-real-value PI_CODING_AGENT_DIR="$agent_dir" \
      PATH="$dir/bin:$PATH" "$RUNNER" cloudflare -p "hi" >/dev/null 2>"$err" \
      || fail "a $case_name models file blocked the cloudflare lane instead of warning"

    assert_contains "$(cat "$err")" "warning" \
      "a $case_name models file did not warn on stderr"
    args=$(cat "$FM_TEST_PI_ARGS")
    assert_contains "$args" "@cf/openai/gpt-oss-120b" \
      "a $case_name models file stopped the cloudflare lane from dispatching"
  done

  unset FM_TEST_PI_ARGS
  pass "an unusable models file warns once and the cloudflare lane still dispatches"
}

test_the_account_guard_is_scoped_to_the_cloudflare_lane() {
  local dir lane key args
  dir="$TMP_ROOT/guard-scope"
  make_fakebin "$dir/bin"
  export FM_TEST_PI_ARGS="$dir/pi-args.txt"
  write_models "$dir/pi" "https://api.cloudflare.com/client/v4/accounts//ai/v1"

  for lane in groq cerebras openrouter; do
    case $lane in
      groq) key=GROQ_API_KEY ;;
      cerebras) key=CEREBRAS_API_KEY ;;
      openrouter) key=OPENROUTER_API_KEY ;;
    esac
    rm -f "$FM_TEST_PI_ARGS"
    env "$key=not-a-real-value" PI_CODING_AGENT_DIR="$dir/pi" \
      PATH="$dir/bin:$PATH" "$RUNNER" "$lane" -p "hi" >/dev/null 2>&1 \
      || fail "the cloudflare account guard refused the $lane lane"
    args=$(cat "$FM_TEST_PI_ARGS")
    assert_contains "$args" "--model" "the $lane lane did not reach pi"
  done

  unset FM_TEST_PI_ARGS
  pass "an unfilled cloudflare account segment does not affect the other three lanes"
}

test_pi_sees_only_the_invoked_lanes_own_key() {
  local dir lane keep other seen
  dir="$TMP_ROOT/key-narrowing"
  make_fakebin "$dir/bin"
  export FM_TEST_PI_ARGS="$dir/pi-args.txt"
  write_models "$dir/pi" "https://api.cloudflare.com/client/v4/accounts/abc123/ai/v1"

  for lane in groq openrouter cloudflare; do
    case $lane in
      groq) keep=GROQ_API_KEY ;;
      openrouter) keep=OPENROUTER_API_KEY ;;
      cloudflare) keep=CLOUDFLARE_API_KEY ;;
    esac
    rm -f "$FM_TEST_PI_ARGS.env"

    GROQ_API_KEY=sentinel-groq-1a CEREBRAS_API_KEY=sentinel-cerebras-2b \
      CLOUDFLARE_API_KEY=sentinel-cloudflare-3c OPENROUTER_API_KEY=sentinel-openrouter-4d \
      PI_CODING_AGENT_DIR="$dir/pi" PATH="$dir/bin:$PATH" \
      "$RUNNER" "$lane" -p "hi" >/dev/null 2>&1 \
      || fail "the $lane lane did not dispatch with every lane key present"

    seen=$(cat "$FM_TEST_PI_ARGS.env")
    assert_contains "$seen" "$keep=" "the $lane lane did not pass its own key to pi"
    assert_contains "$seen" "FM_FREE_LANE_ACTIVE=" \
      "the $lane lane did not mark its session as already inside a lane"
    for other in GROQ_API_KEY CEREBRAS_API_KEY CLOUDFLARE_API_KEY OPENROUTER_API_KEY; do
      if [ "$other" != "$keep" ]; then
        assert_not_contains "$seen" "$other=" \
          "the $lane lane left $other readable by pi"
      fi
    done
  done

  unset FM_TEST_PI_ARGS
  pass "pi sees the invoked lane's own key and none of the other three"
}

test_lane_dispatch_uses_a_slim_prompt_and_no_builtin_tools() {
  local dir args
  dir="$TMP_ROOT/slim-prompt"
  make_fakebin "$dir/bin"
  export FM_TEST_PI_ARGS="$dir/pi-args.txt"

  GROQ_API_KEY=not-a-real-value PATH="$dir/bin:$PATH" "$RUNNER" groq -p "hi" \
    >/dev/null 2>&1 || fail "the groq lane did not dispatch"

  args=$(cat "$FM_TEST_PI_ARGS")
  assert_contains "$args" "--system-prompt" \
    "the runner did not pass a system prompt to pi"
  assert_contains "$args" "one-shot text generator" \
    "the runner did not pass its slim free-lane system prompt to pi"
  assert_contains "$args" "--no-builtin-tools" \
    "the runner did not disable pi's built-in tools"
  assert_contains "$args" "--no-context-files" \
    "the runner did not disable pi's AGENTS.md/CLAUDE.md context-file discovery"
  assert_contains "$args" "--no-extensions" \
    "the runner did not disable pi's extension discovery"

  unset FM_TEST_PI_ARGS
  pass "a lane invocation passes a slim system prompt and disables built-in tools, context files, and extensions"
}

test_caller_can_still_override_the_default_system_prompt() {
  local dir resolved
  dir="$TMP_ROOT/slim-prompt-override"
  make_fakebin "$dir/bin"
  export FM_TEST_PI_ARGS="$dir/pi-args.txt"

  GROQ_API_KEY=not-a-real-value PATH="$dir/bin:$PATH" \
    "$RUNNER" groq --system-prompt "caller prompt" -p "hi" \
    >/dev/null 2>&1 || fail "the groq lane did not dispatch with a caller override"

  resolved=$(last_flag_value "$FM_TEST_PI_ARGS" --system-prompt)
  [ "$resolved" = "caller prompt" ] \
    || fail "pi would resolve --system-prompt to '$resolved', not the caller's own"

  unset FM_TEST_PI_ARGS
  pass "the caller's --system-prompt is the last one pi sees, so it wins the override"
}

test_a_lane_session_may_not_start_another_lane() {
  local dir status err lane
  dir="$TMP_ROOT/reentry"
  make_fakebin "$dir/bin"
  export FM_TEST_PI_ARGS="$dir/pi-args.txt"
  write_models "$dir/pi" "https://api.cloudflare.com/client/v4/accounts/abc123/ai/v1"
  err="$dir/err.txt"

  for lane in groq groq cloudflare; do
    rm -f "$FM_TEST_PI_ARGS"
    status=0
    FM_FREE_LANE_ACTIVE=1 GROQ_API_KEY=sentinel-groq-5e \
      CLOUDFLARE_API_KEY=sentinel-cloudflare-6f PI_CODING_AGENT_DIR="$dir/pi" \
      PATH="$dir/bin:$PATH" "$RUNNER" "$lane" -p "hi" >/dev/null 2>"$err" || status=$?

    expect_code 4 "$status" "re-entering the $lane lane did not refuse with exit 4"
    [ ! -e "$FM_TEST_PI_ARGS" ] \
      || fail "a refused re-entry into the $lane lane still launched pi"
  done
  assert_contains "$(cat "$err")" "free-tier lane" \
    "the refusal did not say a lane may not start another lane"

  rm -f "$FM_TEST_PI_ARGS"
  GROQ_API_KEY=sentinel-groq-5e PI_CODING_AGENT_DIR="$dir/pi" PATH="$dir/bin:$PATH" \
    "$RUNNER" groq -p "hi" >/dev/null 2>&1 \
    || fail "a first lane invocation was refused, so the guard is permanently on"

  unset FM_TEST_PI_ARGS
  pass "a lane session refuses to start another lane, and a first invocation still runs"
}

test_exec_runs_the_given_command_with_no_forced_flags() {
  local dir args
  dir="$TMP_ROOT/exec-basic"
  make_fakebin "$dir/bin"
  export FM_TEST_PI_ARGS="$dir/pi-args.txt"

  GROQ_API_KEY=not-a-real-value PATH="$dir/bin:$PATH" \
    "$RUNNER" --exec groq -- pi --tools everything -p "hi" \
    >/dev/null 2>&1 || fail "--exec did not dispatch a present-key lane"

  args=$(cat "$FM_TEST_PI_ARGS")
  assert_contains "$args" "--tools" \
    "--exec should run the caller's own command verbatim"
  assert_contains "$args" "everything" \
    "--exec dropped the caller's own arguments"
  assert_not_contains "$args" "one-shot text generator" \
    "--exec must not force the one-shot slim system prompt onto a worker launch"
  assert_not_contains "$args" "--no-builtin-tools" \
    "--exec must not force --no-builtin-tools onto a worker launch"

  unset FM_TEST_PI_ARGS
  pass "--exec runs the caller's own command with none of the one-shot lane's forced flags"
}

test_exec_shares_key_presence_and_narrowing_with_the_default_form() {
  local dir status err seen
  dir="$TMP_ROOT/exec-shared-checks"
  make_fakebin "$dir/bin"
  err="$dir/err.txt"

  status=0
  env -u GROQ_API_KEY PATH="$dir/bin:$PATH" "$RUNNER" --exec groq -- true \
    >/dev/null 2>"$err" || status=$?
  expect_code 3 "$status" "--exec with an absent key did not refuse with exit 3"
  assert_contains "$(cat "$err")" "GROQ_API_KEY" \
    "--exec's refusal did not name the missing variable"

  export FM_TEST_PI_ARGS="$dir/pi-args.txt.env"
  GROQ_API_KEY=sentinel-groq-7a CEREBRAS_API_KEY=sentinel-cerebras-7b \
    PATH="$dir/bin:$PATH" "$RUNNER" --exec groq -- \
    env | grep -E '^(GROQ|CEREBRAS)_API_KEY=|^FM_FREE_LANE_ACTIVE=' > "$FM_TEST_PI_ARGS" \
    || fail "--exec with a present key did not dispatch"
  seen=$(cat "$FM_TEST_PI_ARGS")
  assert_contains "$seen" "GROQ_API_KEY=" "--exec dropped the invoked lane's own key"
  assert_contains "$seen" "FM_FREE_LANE_ACTIVE=" "--exec dropped the re-entry marker"
  assert_not_contains "$seen" "CEREBRAS_API_KEY=" \
    "--exec left another lane's key readable by the command"

  status=0
  FM_FREE_LANE_ACTIVE=1 GROQ_API_KEY=sentinel-groq-7a PATH="$dir/bin:$PATH" \
    "$RUNNER" --exec groq -- true >/dev/null 2>"$err" || status=$?
  expect_code 4 "$status" "--exec did not honor the re-entry guard"

  unset FM_TEST_PI_ARGS
  pass "--exec shares the default form's key-presence check, narrowing, and re-entry guard"
}

test_exec_usage_errors() {
  local dir status
  dir="$TMP_ROOT/exec-usage"

  status=0
  "$RUNNER" --exec >/dev/null 2>&1 || status=$?
  expect_code 2 "$status" "--exec with no lane was not a usage error"

  status=0
  "$RUNNER" --exec groq >/dev/null 2>&1 || status=$?
  expect_code 2 "$status" "--exec with no -- separator was not a usage error"

  status=0
  "$RUNNER" --exec groq -- >/dev/null 2>&1 || status=$?
  expect_code 2 "$status" "--exec with no command after -- was not a usage error"

  status=0
  "$RUNNER" --exec bogus -- true >/dev/null 2>&1 || status=$?
  expect_code 2 "$status" "--exec with an unknown lane was not a usage error"

  pass "--exec rejects a missing lane, missing separator, missing command, and unknown lane"
}

test_list_names_every_lane_and_its_variable
test_usage_errors_are_distinct_from_lane_failures
test_absent_key_refuses_without_launching_pi
test_present_key_dispatches_that_lanes_provider_and_model
test_install_launcher_writes_a_blessable_shebang
test_install_launcher_refuses_an_unexpressible_av_path
test_launcher_works_from_a_root_whose_path_has_a_space
test_install_launcher_rejects_arguments_it_does_not_recognise
test_cloudflare_refuses_an_unfilled_account_segment
test_cloudflare_shape_problems_warn_and_still_dispatch
test_the_account_guard_is_scoped_to_the_cloudflare_lane
test_pi_sees_only_the_invoked_lanes_own_key
test_lane_dispatch_uses_a_slim_prompt_and_no_builtin_tools
test_caller_can_still_override_the_default_system_prompt
test_a_lane_session_may_not_start_another_lane
test_exec_runs_the_given_command_with_no_forced_flags
test_exec_shares_key_presence_and_narrowing_with_the_default_form
test_exec_usage_errors
