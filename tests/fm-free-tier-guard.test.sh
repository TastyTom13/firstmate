#!/usr/bin/env bash
# Behavior tests for fm-free-tier-guard.sh: refuse without an allowlist, refuse
# an unlisted repo, refuse deny-term brief text without over-refusing an
# innocent word, and allow only a listed repo with clean brief text.
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
    candidate candidates PII "Article 9" "article-9" Bull strategy strategies; do
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

  pass "usage errors exit 2 and an unreadable brief refuses"
}

test_missing_allowlist_refuses
test_unlisted_repo_refuses
test_deny_terms_refuse_and_innocent_words_do_not
test_listed_repo_with_clean_brief_is_eligible
test_usage_errors_are_distinct_from_refusals
