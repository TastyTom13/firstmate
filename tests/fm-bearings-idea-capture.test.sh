#!/usr/bin/env bash
# Behavior tests for the bearings board's idea-capture answer shape: a
# captured idea rides the ordinary fm-bearings-board.v1 "choice" answer
# channel with a `idea.<unique-suffix>` key (bin/fm-bearings-board.sh's
# header owns the shape), and bin/fm-procevent-lavish.sh's generic `answers`
# reader must surface every distinct idea rather than collapsing them.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-bearings-idea-capture)

command -v perl >/dev/null 2>&1 || { echo "skip: perl not found"; exit 0; }

make_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/data"
  printf '%s\n' "$home"
}

run_lavish() {  # <home> <command args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    "$ROOT/bin/fm-procevent-lavish.sh" "$@"
}

test_two_distinct_ideas_both_survive_the_answer_read() {
  local home result out
  home=$(make_home two-ideas)
  result="$home/result.txt"
  cat > "$result" <<'EOF'
session:
  status: feedback
  session_ended: false
prompts[2]{uid,prompt,selector,tag,text}:
  "2","Parked idea: try a dark theme\n\nContext data:\n{\n  \"question\": \"idea.m1a2b3-c4d5\",\n  \"answer\": \"try a dark theme\"\n}","form",choice,"Idea -> try a dark theme"
  "3","Parked idea: batch the merges\n\nContext data:\n{\n  \"question\": \"idea.m1a2b4-e6f7\",\n  \"answer\": \"batch the merges\"\n}","form",choice,"Idea -> batch the merges"
EOF
  out=$(run_lavish "$home" answers "$result") || fail "could not read the captured idea answers"
  assert_contains "$out" "$(printf 'idea.m1a2b3-c4d5\ttry a dark theme\tIdea -> try a dark theme')" \
    "the first idea did not round-trip with its own key: $out"
  assert_contains "$out" "$(printf 'idea.m1a2b4-e6f7\tbatch the merges\tIdea -> batch the merges')" \
    "the second idea did not round-trip with its own key: $out"
  [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 2 ] \
    || fail "two distinct idea keys did not produce two rows: $out"
  pass "two ideas queued with distinct keys both survive the answer read"
}

test_an_idea_and_a_decision_answer_coexist_in_one_read() {
  local home result out
  home=$(make_home mixed)
  result="$home/result.txt"
  cat > "$result" <<'EOF'
session:
  status: feedback
  session_ended: false
prompts[2]{uid,prompt,selector,tag,text}:
  "2","Captain's Call answer - Merge now: merge\n\nContext data:\n{\n  \"question\": \"merge.sample-task\",\n  \"answer\": \"merge\"\n}","form",choice,"Merge: sample-task -> merge"
  "3","Parked idea: automate the changelog\n\nContext data:\n{\n  \"question\": \"idea.m1c9d8-a1b2\",\n  \"answer\": \"automate the changelog\"\n}","form",choice,"Idea -> automate the changelog"
EOF
  out=$(run_lavish "$home" answers "$result") || fail "could not read the mixed answers"
  assert_contains "$out" "$(printf 'merge.sample-task\tmerge\t')" \
    "the decision-style answer key was lost alongside an idea key: $out"
  assert_contains "$out" "$(printf 'idea.m1c9d8-a1b2\tautomate the changelog\t')" \
    "the idea answer key was lost alongside a decision-style key: $out"
  pass "an idea key and a decision key coexist in one read without either dropping the other"
}

test_a_repeated_idea_key_still_keeps_only_the_last_like_any_other_key() {
  # Documents the existing generic last-wins behavior of `answers` (shared
  # with every other key kind) as the reason the board mints a fresh key per
  # idea instead of reusing one: two submissions under the SAME key collapse
  # to one, so a real idea box must never repeat a key across submissions.
  local home result out lines
  home=$(make_home repeated-key)
  result="$home/result.txt"
  cat > "$result" <<'EOF'
session:
  status: feedback
  session_ended: false
prompts[2]{uid,prompt,selector,tag,text}:
  "2","Parked idea: first try\n\nContext data:\n{\n  \"question\": \"idea.fixed-key\",\n  \"answer\": \"first try\"\n}","form",choice,"Idea -> first try"
  "3","Parked idea: second try\n\nContext data:\n{\n  \"question\": \"idea.fixed-key\",\n  \"answer\": \"second try\"\n}","form",choice,"Idea -> second try"
EOF
  out=$(run_lavish "$home" answers "$result") || fail "could not read the repeated-key answers"
  lines=$(printf '%s\n' "$out" | wc -l | tr -d ' ')
  [ "$lines" = 1 ] || fail "a repeated idea key produced more than one row: $out"
  assert_contains "$out" "$(printf 'idea.fixed-key\tsecond try\t')" \
    "a repeated idea key did not keep the last submission: $out"
  pass "a repeated idea key keeps only the last submission, confirming why keys must be unique per idea"
}

test_two_distinct_ideas_both_survive_the_answer_read
test_an_idea_and_a_decision_answer_coexist_in_one_read
test_a_repeated_idea_key_still_keeps_only_the_last_like_any_other_key
