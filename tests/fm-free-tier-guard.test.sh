#!/usr/bin/env bash
# Behavior tests for fm-free-tier-guard.sh: refuse without an allowlist, refuse
# an unlisted repo, refuse a multi-line repo value carrying a listed name,
# refuse an empty brief and a deny term carried next to a non-UTF-8 byte,
# refuse deny-term brief text without over-refusing an innocent word, allow
# only a listed repo with clean brief text, and keep every non-checking
# invocation out of the eligible exit class.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GUARD="$ROOT/bin/fm-free-tier-guard.sh"
TMP_ROOT=$(fm_test_tmproot fm-free-tier-guard)

make_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/config"
  printf '%s\n' "$home"
}

run_guard() {
  local home=$1 repo=$2 brief=$3 out err status
  out="$home/out.txt"
  err="$home/err.txt"
  status=0
  printf '%s\n' "$brief" \
    | FM_CONFIG_OVERRIDE="$home/config" "$GUARD" --repo "$repo" --brief-stdin \
      >"$out" 2>"$err" || status=$?
  printf '%s\n' "$status"
}

test_missing_allowlist_refuses() {
  local home status
  home=$(make_home no-allowlist)

  status=$(run_guard "$home" demo-repo "write table fixtures")
  expect_code 1 "$status" "guard allowed a repo with no allowlist present"
  assert_contains "$(cat "$home/err.txt")" "allowlist" \
    "missing-allowlist refusal did not name the allowlist"
  assert_not_contains "$(cat "$home/out.txt")" "eligible" \
    "missing-allowlist refusal still printed an eligible verdict"

  pass "an absent allowlist refuses free-tier routing"
}

test_unlisted_repo_refuses() {
  local home status
  home=$(make_home unlisted)
  printf 'demo-repo\n' > "$home/config/free-tier-repos"

  status=$(run_guard "$home" scout-core "write table fixtures")
  expect_code 1 "$status" "guard allowed a repo missing from the allowlist"
  assert_contains "$(cat "$home/err.txt")" "scout-core" \
    "unlisted-repo refusal did not name the repo"

  pass "a repo missing from the allowlist is refused"
}

test_deny_terms_refuse_and_innocent_words_do_not() {
  local home status term
  home=$(make_home deny-terms)
  printf '# pilot repos\ndemo-repo\n' > "$home/config/free-tier-repos"

  for term in credential credentials secret secrets token tokens \
    candidate candidates PII "Article 9" "article-9" Bull strategy strategies \
    env .env envs environment environments key keys database databases \
    db dbs email emails \
    "user data" "User-data" user_data userdata \
    candidateProfile secretKey credentialStore apiToken SecretKey \
    dbConnection userSecrets dataBase eMail; do
    status=$(run_guard "$home" demo-repo "Add tests. Context: $term handling.")
    expect_code 1 "$status" "deny term '$term' did not refuse"
    assert_contains "$(cat "$home/err.txt")" "deny term" \
      "deny term '$term' refused with the wrong reason"
  done

  for term in bulletin bullet secretary tokenizer strategic; do
    status=$(run_guard "$home" demo-repo "Add tests for the $term module.")
    expect_code 0 "$status" "innocent word '$term' was refused"
  done

  pass "deny terms refuse while similar innocent words still pass"
}

test_multiline_repo_value_refuses() {
  local home status
  home=$(make_home multiline-repo)
  printf 'demo-repo\n' > "$home/config/free-tier-repos"

  status=$(run_guard "$home" "$(printf 'scout-core\ndemo-repo')" "write table fixtures")
  expect_code 1 "$status" "guard allowed a multi-line repo value containing a listed name"
  assert_not_contains "$(cat "$home/out.txt")" "eligible" \
    "multi-line repo value still printed an eligible verdict"

  pass "a multi-line repo value carrying a listed name is refused"
}

test_empty_brief_refuses_on_both_input_paths() {
  local home status err
  home=$(make_home empty-brief)
  printf 'demo-repo\n' > "$home/config/free-tier-repos"
  err="$home/empty-err.txt"

  status=0
  : | FM_CONFIG_OVERRIDE="$home/config" "$GUARD" --repo demo-repo --brief-stdin \
    >"$home/empty-out.txt" 2>"$err" || status=$?
  expect_code 1 "$status" "empty stdin was not refused"
  assert_contains "$(cat "$err")" "empty" \
    "empty-stdin refusal used the wrong reason"
  assert_not_contains "$(cat "$home/empty-out.txt")" "eligible" \
    "empty stdin still printed an eligible verdict"

  : > "$home/empty.md"
  status=0
  FM_CONFIG_OVERRIDE="$home/config" "$GUARD" --repo demo-repo \
    --brief-file "$home/empty.md" >"$home/empty-out.txt" 2>"$err" || status=$?
  expect_code 1 "$status" "a zero-byte brief file was not refused"
  assert_not_contains "$(cat "$home/empty-out.txt")" "eligible" \
    "a zero-byte brief file still printed an eligible verdict"

  pass "an empty brief refuses on both input paths"
}

test_deny_term_refuses_next_to_a_non_utf8_byte() {
  local home status
  home=$(make_home non-utf8)
  printf 'demo-repo\n' > "$home/config/free-tier-repos"
  printf 'Add tests for the candidate\x92s parser.\n' > "$home/cp1252.md"
  printf 'Add tests for the candidate\xe2\x80\x99s parser.\n' > "$home/utf8.md"

  status=0
  FM_CONFIG_OVERRIDE="$home/config" "$GUARD" --repo demo-repo \
    --brief-file "$home/cp1252.md" >"$home/out.txt" 2>"$home/err.txt" || status=$?
  expect_code 1 "$status" "a deny term next to a cp1252 byte was not refused"
  assert_contains "$(cat "$home/err.txt")" "deny term" \
    "the cp1252 brief refused with the wrong reason"

  status=0
  FM_CONFIG_OVERRIDE="$home/config" "$GUARD" --repo demo-repo \
    --brief-file "$home/utf8.md" >"$home/out.txt" 2>"$home/err.txt" || status=$?
  expect_code 1 "$status" "the valid-UTF-8 control brief was not refused"

  pass "a deny term refuses regardless of the brief's byte encoding"
}

test_listed_repo_with_clean_brief_is_eligible() {
  local home status
  home=$(make_home eligible)
  printf 'demo-repo\nother-repo\n' > "$home/config/free-tier-repos"

  status=$(run_guard "$home" other-repo \
    "Write boilerplate table fixtures and assertion scaffolding for the parser.")
  expect_code 0 "$status" "clean brief on a listed repo was refused"
  assert_contains "$(cat "$home/out.txt")" "eligible: other-repo" \
    "eligible verdict did not name the repo"

  pass "a listed repo with clean brief text is eligible"
}

test_usage_errors_are_distinct_from_refusals() {
  local home status out err
  home=$(make_home usage)
  printf 'demo-repo\n' > "$home/config/free-tier-repos"
  out="$home/usage-out.txt"
  err="$home/usage-err.txt"

  status=0
  FM_CONFIG_OVERRIDE="$home/config" "$GUARD" --brief-stdin </dev/null \
    >"$out" 2>"$err" || status=$?
  expect_code 2 "$status" "missing --repo was not a usage error"

  status=0
  FM_CONFIG_OVERRIDE="$home/config" "$GUARD" --repo demo-repo \
    >"$out" 2>"$err" || status=$?
  expect_code 2 "$status" "missing brief source was not a usage error"

  status=0
  FM_CONFIG_OVERRIDE="$home/config" "$GUARD" --repo demo-repo \
    --brief-file "$home/absent.md" >"$out" 2>"$err" || status=$?
  expect_code 1 "$status" "an unreadable brief file was not refused"
  assert_contains "$(cat "$err")" "unreadable" \
    "unreadable brief refusal used the wrong reason"

  status=0
  FM_CONFIG_OVERRIDE="$home/config" "$GUARD" --help >"$out" 2>"$err" || status=$?
  expect_code 2 "$status" "--help did not exit in the non-eligible class"
  ! grep -q '^eligible: ' "$out" \
    || fail "--help printed an eligible verdict"
  assert_grep "credential" "$out" \
    "--help did not print the deny set the operator page points at"

  pass "usage errors exit 2, --help exits 2, and an unreadable brief refuses"
}

test_missing_allowlist_refuses
test_unlisted_repo_refuses
test_multiline_repo_value_refuses
test_deny_terms_refuse_and_innocent_words_do_not
test_empty_brief_refuses_on_both_input_paths
test_deny_term_refuses_next_to_a_non_utf8_byte
test_listed_repo_with_clean_brief_is_eligible
test_usage_errors_are_distinct_from_refusals
