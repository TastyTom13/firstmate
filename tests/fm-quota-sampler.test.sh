#!/usr/bin/env bash
# Behavior tests for bin/fm-quota-sampler.sh. Every case drives the real
# executable with fake readers, so tests neither read credentials nor use the
# network.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SAMPLER="$ROOT/bin/fm-quota-sampler.sh"
TMP_ROOT=$(fm_test_tmproot fm-quota-sampler)

make_fake_readers() {  # <home>
  local home=$1 quota_bin
  quota_bin="$home/.nvm/versions/node/v99.0.0/bin"
  mkdir -p "$quota_bin" "$home/fakebin"
  cat > "$quota_bin/quota-axi" <<'SH'
#!/bin/sh
printf '%s\n' "$@" > "$FAKE_QUOTA_ARGV"
printf '%s\n' "$PATH" > "$FAKE_QUOTA_PATH"
printf '%s\n' "$HOME" > "$FAKE_QUOTA_HOME"
printf '%s\n' '{"schemaVersion":5,"providers":[{"provider":"claude","windows":[]}]}'
SH
  cat > "$home/fakebin/gpt-reader" <<'SH'
#!/bin/sh
printf '%s\n' "$@" > "$FAKE_GPT_ARGV"
printf '%s\n' '{"schema":"fm-gpt-quota.v1","status":"known","windows":[]}'
SH
  chmod +x "$quota_bin/quota-axi" "$home/fakebin/gpt-reader"
}

test_launchd_environment_discovers_node_install_and_passes_read_only_args() {
  local home="$TMP_ROOT/launchd" history="$TMP_ROOT/launchd/history.jsonl" actual expected
  make_fake_readers "$home"

  env -i \
    HOME="$home" \
    PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    FM_QUOTA_SAMPLE_HISTORY="$history" \
    FM_QUOTA_SAMPLE_GPT_READER="$home/fakebin/gpt-reader" \
    FAKE_QUOTA_ARGV="$home/quota-argv" \
    FAKE_QUOTA_PATH="$home/quota-path" \
    FAKE_QUOTA_HOME="$home/quota-home" \
    FAKE_GPT_ARGV="$home/gpt-argv" \
    /bin/sh "$SAMPLER" || fail "the sampler failed in a launchd-like environment"

  actual=$(cat "$home/quota-argv")
  expected=$(printf '%s\n' --provider claude --no-credential-refresh --json)
  [ "$actual" = "$expected" ] || fail "quota-axi did not receive the exact noninteractive Claude arguments"
  [ "$(cat "$home/quota-home")" = "$home" ] || fail "the sampler did not preserve the account home"
  case "$(cat "$home/quota-path")" in
    "$home/.nvm/versions/node/v99.0.0/bin:"*) : ;;
    *) fail "the discovered node bin was not prepended to PATH" ;;
  esac
  [ "$(cat "$home/gpt-argv")" = --json ] || fail "the ChatGPT reader did not receive --json"
  jq -e '.claude.providers[0].provider == "claude" and .gpt.status == "known"' "$history" \
    >/dev/null || fail "the sampler did not append both fake readings"
  pass "a launchd-like environment discovers quota-axi and passes noninteractive provider arguments"
}

test_missing_quota_axi_preserves_independent_chatgpt_sample() {
  local home="$TMP_ROOT/missing-quota" history="$TMP_ROOT/missing-quota/history.jsonl"
  mkdir -p "$home"
  cat > "$home/gpt-reader" <<'SH'
#!/bin/sh
printf '%s\n' '{"schema":"fm-gpt-quota.v1","status":"known","windows":[]}'
SH
  chmod +x "$home/gpt-reader"

  env -i \
    HOME="$home" \
    PATH=/usr/bin:/bin \
    FM_QUOTA_SAMPLE_HISTORY="$history" \
    FM_QUOTA_SAMPLE_GPT_READER="$home/gpt-reader" \
    /bin/sh "$SAMPLER" || fail "the sampler failed without quota-axi"

  jq -e '.claude == null and .gpt.status == "known"' "$history" \
    >/dev/null || fail "the sampler did not preserve the independent ChatGPT reading"
  pass "missing quota-axi records null Claude and preserves ChatGPT"
}

test_explicit_reader_overrides_work_with_an_empty_path() {
  local home="$TMP_ROOT/overrides" history="$TMP_ROOT/overrides/history.jsonl"
  make_fake_readers "$home"

  env -i \
    HOME="$home" \
    PATH= \
    FM_QUOTA_SAMPLE_HISTORY="$history" \
    FM_QUOTA_SAMPLE_QUOTA_AXI="$home/.nvm/versions/node/v99.0.0/bin/quota-axi" \
    FM_QUOTA_SAMPLE_GPT_READER="$home/fakebin/gpt-reader" \
    FM_QUOTA_SAMPLE_PYTHON="$(command -v python3)" \
    FAKE_QUOTA_ARGV="$home/quota-argv" \
    FAKE_QUOTA_PATH="$home/quota-path" \
    FAKE_QUOTA_HOME="$home/quota-home" \
    FAKE_GPT_ARGV="$home/gpt-argv" \
    /bin/sh "$SAMPLER" || fail "the sampler rejected explicit executable overrides"

  [ "$(wc -l < "$history" | tr -d ' ')" -eq 1 ] || fail "the sampler did not append exactly one record"
  jq -e '.ts | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T")' "$history" >/dev/null \
    || fail "the sample timestamp was absent or malformed"
  pass "explicit executable overrides work even when the inherited PATH is empty"
}

test_launchd_environment_discovers_node_install_and_passes_read_only_args
test_missing_quota_axi_preserves_independent_chatgpt_sample
test_explicit_reader_overrides_work_with_an_empty_path
