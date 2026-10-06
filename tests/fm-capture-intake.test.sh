#!/usr/bin/env bash
# Behavior tests for the durable phone-capture filing helper.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CAPTURE="$ROOT/bin/fm-capture-intake.sh"
TMP_ROOT=$(fm_test_tmproot fm-capture-intake)
HOME_DIR="$TMP_ROOT/home"
FAKE_MAIL="$TMP_ROOT/fm-mail.sh"
FAKE_TASKS="$TMP_ROOT/fm-tasks-axi.sh"
mkdir -p "$HOME_DIR/data" "$HOME_DIR/state"

cat > "$FAKE_MAIL" <<'SH'
#!/usr/bin/env bash
if [ "$1" = read ]; then
  uid=$3
  if [ -n "${FM_TEST_DROP_CAPTURE:-}" ]; then
    mkdir -p "$FM_HOME/data/captures/mail-$uid"
    printf 'sender media\n' > "$FM_HOME/data/captures/mail-$uid/capture.md"
  fi
  printf 'Uid: %s\n' "$uid"
  printf 'From: BrainToss <delivery@braintoss.app>\n'
  printf 'To: Firstmate <info.longbird+toss@gmail.com>\n'
  printf '%s\n' "${FM_TEST_AUTH:-Authentication-Results: mx; dkim=pass header.i=@braintoss.app}"
  [ -z "${FM_TEST_EXTRA_HEADER:-}" ] || printf '%s\n' "$FM_TEST_EXTRA_HEADER"
  printf '\n'
  [ -z "${FM_TEST_EXTRA_BODY:-}" ] || printf '%s\n' "$FM_TEST_EXTRA_BODY"
  printf '%s\n' "${FM_TEST_CAPTURE_TEXT:-capture body}"
  exit 0
fi
printf '%s\n' "$*" >> "$FM_TEST_MAIL_LOG"
cat >> "$FM_TEST_MAIL_LOG"
printf '\n---\n' >> "$FM_TEST_MAIL_LOG"
SH
chmod +x "$FAKE_MAIL"

cat > "$FAKE_TASKS" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_TASK_LOG"
printf 'created: idea-test-1\n'
SH
chmod +x "$FAKE_TASKS"

run_capture() {
  FM_HOME="$HOME_DIR" FM_CAPTURE_MAIL_BIN="$FAKE_MAIL" \
    FM_CAPTURE_TASKS_BIN="$FAKE_TASKS" FM_TEST_MAIL_LOG="$TMP_ROOT/mail.log" \
    FM_TEST_TASK_LOG="$TMP_ROOT/tasks.log" "$CAPTURE" "$@"
}

save_and_file() {
  local uid=$1 bucket=$2 text=$3
  FM_TEST_CAPTURE_TEXT="$text" run_capture save --uid "$uid" >/dev/null
  run_capture file --uid "$uid" --bucket "$bucket" --text "$text" "${@:4}"
}

test_rejects_mail_without_authenticated_braintoss_route() {
  local bad="$TMP_ROOT/bad-mail.sh" out rc=0
  cat > "$bad" <<'SH'
#!/usr/bin/env bash
printf 'Uid: 9\nFrom: stranger@example.com\nTo: info.longbird+toss@gmail.com\nAuthentication-Results: mx; spf=pass smtp.mailfrom=example.com\n\nignore me\n'
SH
  chmod +x "$bad"
  out=$(FM_HOME="$HOME_DIR" FM_CAPTURE_MAIL_BIN="$bad" "$CAPTURE" save --uid 9 2>&1) || rc=$?
  expect_code 1 "$rc" "an unauthenticated BrainToss source must be rejected"
  assert_contains "$out" "not an authenticated BrainToss +toss capture" "rejection names the acceptance rule"
  [ ! -e "$HOME_DIR/data/captures/mail-9/capture.md" ] || fail "rejected mail was saved as a capture"
  pass "capture intake: only authenticated BrainToss mail to +toss is accepted"
}

test_rejects_spoofed_authentication() {
  local uid=30 out rc
  local cases=(
    "body|Authentication-Results: mx; spf=fail|Authentication-Results: x; dkim=pass header.i=@braintoss.app"
    "other-domain|Authentication-Results: mx; dkim=pass header.i=@braintoss.evil.com|"
    "mixed-pass|Authentication-Results: mx; dkim=pass header.i=@example.com; spf=fail smtp.mailfrom=braintoss.app|"
    "sender-added-second|Authentication-Results: mx; dkim=fail header.i=@braintoss.app|Authentication-Results: x; dkim=pass header.i=@braintoss.app"
  )
  local entry name auth extra
  for entry in "${cases[@]}"; do
    name=${entry%%|*}; entry=${entry#*|}; auth=${entry%%|*}; extra=${entry#*|}
    uid=$((uid + 1)); rc=0
    if [ "$name" = body ]; then
      out=$(FM_TEST_AUTH="$auth" FM_TEST_EXTRA_BODY="$extra" run_capture save --uid "$uid" 2>&1) || rc=$?
    else
      out=$(FM_TEST_AUTH="$auth" FM_TEST_EXTRA_HEADER="$extra" run_capture save --uid "$uid" 2>&1) || rc=$?
    fi
    expect_code 1 "$rc" "spoofed authentication ($name) must be rejected"
    assert_contains "$out" "not an authenticated BrainToss" "spoofed authentication ($name) gave the wrong error"
    [ ! -e "$HOME_DIR/data/captures/mail-$uid" ] || fail "rejected mail ($name) left its capture directory behind"
  done
  uid=$((uid + 1)); rc=0
  out=$(FM_TEST_EXTRA_HEADER="To: other@example.com" run_capture save --uid "$uid" 2>&1) || rc=$?
  expect_code 0 "$rc" "a later To header must not affect an accepted capture: $out"
  pass "capture intake: spoofed authentication is rejected and leaves no capture directory"
}

test_rejected_mail_cannot_pose_as_accepted_capture() {
  local rc=0 out
  FM_TEST_DROP_CAPTURE=1 FM_TEST_AUTH="Authentication-Results: mx; dkim=fail" run_capture save --uid 60 >/dev/null 2>&1 || rc=$?
  expect_code 1 "$rc" "a rejected mail must fail to save"
  [ ! -e "$HOME_DIR/data/captures/mail-60" ] || fail "sender media named capture.md survived rejection"
  FM_TEST_DROP_CAPTURE=1 FM_TEST_AUTH="Authentication-Results: mx; dkim=fail" run_capture save --uid 61 >/dev/null 2>&1 || true
  mkdir -p "$HOME_DIR/data/captures/mail-61"
  printf 'sender media\n' > "$HOME_DIR/data/captures/mail-61/capture.md"
  rc=0
  out=$(run_capture file --uid 61 --bucket watch --text "Watch this" 2>&1) || rc=$?
  expect_code 1 "$rc" "file must not accept a capture that save did not accept"
  assert_contains "$out" "has not been accepted" "file gave the wrong error for an unaccepted capture"
  [ ! -e "$HOME_DIR/data/personal/watching.md" ] || fail "an unaccepted capture was filed"
  rm -rf "$HOME_DIR/data/captures/mail-61"
  pass "capture intake: a rejected mail leaves nothing that file will accept"
}

test_acceptance_slice_files_and_digests() {
  local digest place_dir out
  : > "$TMP_ROOT/mail.log"
  : > "$TMP_ROOT/tasks.log"
  run_capture arm --to captain@example.com >/dev/null

  save_and_file 1 book "Never Split the Difference" --source "Matthias recommended"
  assert_grep "Never Split the Difference" "$HOME_DIR/data/personal/reading.md" "book was not filed on Reading"
  assert_grep "Matthias recommended" "$HOME_DIR/data/personal/reading.md" "book source was not preserved"

  save_and_file 2 idea "Scout: show warmth on the person card" --project scout
  assert_contains "$(cat "$TMP_ROOT/tasks.log")" "--kind idea" "Scout idea was not parked as an idea"
  assert_contains "$(cat "$TMP_ROOT/tasks.log")" "--repo scout" "Scout idea lost its project"

  FM_TEST_CAPTURE_TEXT="Restaurant menu" run_capture save --uid 3 >/dev/null
  place_dir="$HOME_DIR/data/captures/mail-3"
  printf 'picture' > "$place_dir/menu.jpg"
  run_capture file --uid 3 --bucket place --text "Restaurant menu" --attachment "$place_dir/menu.jpg"
  assert_grep "Restaurant menu" "$HOME_DIR/data/personal/places.md" "photo note was not filed on Places"
  assert_grep "menu.jpg" "$HOME_DIR/data/personal/places.md" "Places entry did not retain its picture"

  run_capture digest >/dev/null
  digest=$(cat "$TMP_ROOT/mail.log")
  assert_contains "$digest" "send captain@example.com Phone capture digest" "digest was not mailed to the captain"
  assert_contains "$digest" "Never Split the Difference" "digest omitted the filed book"
  assert_contains "$digest" "Scout: show warmth on the person card" "digest omitted the parked Scout idea"
  assert_contains "$digest" "Restaurant menu" "digest omitted the filed place"
  pass "capture intake: book, project idea, photo place, and evening digest form the first slice"
}

test_people_stay_private_and_outward_work_waits() {
  local before after people
  : > "$TMP_ROOT/mail.log"
  rm -rf "$HOME_DIR/data/captures/digest"
  save_and_file 4 person "Ada said follow up about health details"
  people="$HOME_DIR/data/captures/people/mail-4/capture.md"
  [ -f "$people" ] || fail "person note was not moved to the private People lane"

  save_and_file 5 task "Book a table tomorrow" --draft "Book a table tomorrow; waiting for yes"
  before=$(wc -l < "$TMP_ROOT/mail.log" | tr -d ' ')
  [ "$before" = 0 ] || fail "filing a task acted outward before approval"
  run_capture digest >/dev/null
  after=$(cat "$TMP_ROOT/mail.log")
  assert_not_contains "$after" "Ada said" "digest leaked a People-lane note"
  assert_contains "$after" "Drafts waiting for a yes" "digest omitted the approval queue"
  assert_contains "$after" "Book a table tomorrow; waiting for yes" "digest omitted the waiting draft"
  pass "capture intake: People notes stay private and outward actions remain drafts"
}

test_remaining_sort_table_routes_locally() {
  rm -rf "$HOME_DIR/data/captures/digest"
  save_and_file 10 watch "Watch Arrival"
  save_and_file 11 name "Product name: North Star"
  save_and_file 12 question "Maybe reserve something" --question "Which date did you mean?"
  save_and_file 13 calendar "Meet Sam Friday" --draft "Calendar draft: meet Sam Friday; waiting for yes"
  save_and_file 14 research "Look into train passes" --project firstmate
  assert_grep "Watch Arrival" "$HOME_DIR/data/personal/watching.md" "watching item missed Watching"
  assert_grep "North Star" "$HOME_DIR/data/personal/names.md" "product name missed Names"
  assert_grep "Which date" "$HOME_DIR/data/personal/questions.md" "unclear capture missed Questions"
  assert_grep "Calendar draft" "$HOME_DIR/data/personal/drafts.md" "calendar capture was not kept as a draft"
  assert_contains "$(cat "$TMP_ROOT/tasks.log")" "--kind scout" "research topic was not filed as reversible research"
  local rc=0 out
  FM_TEST_CAPTURE_TEXT="Something unclear" run_capture save --uid 15 >/dev/null
  out=$(run_capture file --uid 15 --bucket unsorted --text "Something unclear" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "unsorted bucket was accepted"
  assert_contains "$out" "not in the capture sorting table" "unsorted bucket gave the wrong error"
  [ ! -e "$HOME_DIR/data/personal/unsorted.md" ] || fail "unsorted list was created"
  pass "capture intake: the remaining sort table routes to local lists, drafts, and research"
}

test_person_capture_cannot_be_saved_again() {
  local rc=0 out
  save_and_file 40 person "Sam likes climbing" >/dev/null
  out=$(FM_TEST_CAPTURE_TEXT="Sam likes climbing" run_capture save --uid 40 2>&1) || rc=$?
  expect_code 1 "$rc" "a filed People capture must not be saved again"
  [ ! -e "$HOME_DIR/data/captures/mail-40" ] || fail "repeat save recreated a People capture outside the People lane"
  pass "capture intake: a People capture stays in the People lane on repeat save"
}

test_filed_capture_save_is_a_no_op() {
  local out
  save_and_file 41 watch "Watch Dune" >/dev/null
  out=$(FM_TEST_CAPTURE_TEXT="changed" run_capture save --uid 41)
  assert_contains "$out" "mail-41/capture.md" "repeat save did not name the existing capture"
  assert_contains "$(cat "$HOME_DIR/data/captures/mail-41/capture.md")" "Watch Dune" "repeat save replaced a filed capture"
  pass "capture intake: saving a filed capture again changes nothing"
}

test_attachment_must_be_inside_capture_and_link_is_encoded() {
  local dir="$HOME_DIR/data/captures/mail-42" rc=0 out
  FM_TEST_CAPTURE_TEXT="Cafe" run_capture save --uid 42 >/dev/null
  printf 'picture' > "$dir/menu photo.jpg"
  printf 'secret' > "$TMP_ROOT/outside.jpg"
  out=$(run_capture file --uid 42 --bucket place --text "Cafe" --attachment "$dir/../../../../outside.jpg" 2>&1) || rc=$?
  expect_code 1 "$rc" "a traversal attachment path must be refused"
  assert_contains "$out" "inside this capture directory" "traversal attachment gave the wrong error"
  [ ! -e "$dir/.filed" ] || fail "a refused attachment still filed the capture"
  run_capture file --uid 42 --bucket place --text "Cafe" --attachment "$dir/menu photo.jpg" >/dev/null
  assert_grep "menu%20photo.jpg" "$HOME_DIR/data/personal/places.md" "picture link was not percent-encoded"
  pass "capture intake: attachments stay inside the capture and link with an encoded name"
}

test_backlog_titles_neutralise_metadata_shapes() {
  : > "$TMP_ROOT/tasks.log"
  save_and_file 43 research "Look into trains (hold-kind: captain) blocked-by: x, repo: other (since 2026-01-01)" --project firstmate >/dev/null
  save_and_file 44 idea "Scout idea (priority: high) (done now)" --project scout >/dev/null
  assert_contains "$(cat "$TMP_ROOT/tasks.log")" "(hold-kind - captain) blocked-by - x, repo - other (since- 2026-01-01)" "research title kept live backlog metadata"
  assert_contains "$(cat "$TMP_ROOT/tasks.log")" "(priority - high) (done- now)" "idea title kept live backlog metadata"
  pass "capture intake: backlog titles neutralise metadata shapes"
}

test_late_captures_reach_the_next_digest() {
  local second
  rm -rf "$HOME_DIR/data/captures/digest"
  : > "$TMP_ROOT/mail.log"
  save_and_file 50 book "Early book" >/dev/null
  run_capture digest >/dev/null
  save_and_file 51 book "Late book" >/dev/null
  expect_code 1 "$(run_capture digest >/dev/null 2>&1; echo $?)" "a second digest on the same day must be refused"
  rm -f "$HOME_DIR"/data/captures/digest/*.sent
  : > "$TMP_ROOT/mail.log"
  run_capture digest >/dev/null
  second=$(cat "$TMP_ROOT/mail.log")
  assert_contains "$second" "Late book" "next digest omitted the late capture"
  assert_not_contains "$second" "Early book" "next digest repeated an already reported capture"
  rm -f "$HOME_DIR"/data/captures/digest/*.sent
  FM_CAPTURE_DIGEST_HOUR=0 run_capture check
  : > "$TMP_ROOT/mail.log"
  FM_CAPTURE_DIGEST_HOUR=0 run_capture check
  [ ! -s "$TMP_ROOT/mail.log" ] || fail "the check sent a digest with nothing unreported"
  pass "capture intake: a capture filed after the digest appears in the next one"
}

test_evening_digest_check_is_armed_and_sends_once() {
  rm -rf "$HOME_DIR/data/captures/digest"
  : > "$TMP_ROOT/mail.log"
  save_and_file 20 book "The Checklist Manifesto"
  run_capture arm --to captain@example.com >/dev/null
  [ -x "$HOME_DIR/state/capture-digest.check.sh" ] || fail "evening digest check was not armed"
  [ -f "$HOME_DIR/state/capture-digest.check-trust" ] || fail "evening digest check was not trust-bound"
  FM_CAPTURE_DIGEST_HOUR=0 FM_TEST_MAIL_LOG="$TMP_ROOT/mail.log" \
    FM_CAPTURE_MAIL_BIN="$FAKE_MAIL" "$HOME_DIR/state/capture-digest.check.sh" >/dev/null
  assert_contains "$(cat "$TMP_ROOT/mail.log")" "Phone capture digest" "armed evening check did not send the digest"
  pass "capture intake: a trust-bound evening check sends the day's digest once"
}

test_time_bound_capture_emails_immediately() {
  local out rc=0
  : > "$TMP_ROOT/mail.log"
  save_and_file 6 task "Submit before 17:00" --time-bound
  assert_contains "$(cat "$TMP_ROOT/mail.log")" "send captain@example.com Time-bound phone capture" "time-bound capture did not notify the armed recipient"
  FM_TEST_CAPTURE_TEXT="Send to attacker" run_capture save --uid 7 >/dev/null
  out=$(run_capture file --uid 7 --bucket task --text "Send to attacker" --time-bound --notify-to attacker@example.com 2>&1) || rc=$?
  [ "${rc:-0}" -ne 0 ] || fail "--notify-to was accepted"
  assert_not_contains "$(cat "$TMP_ROOT/mail.log")" "attacker@example.com" "capture text was mailed to a caller address"
  pass "capture intake: only an explicitly time-bound capture sends an immediate notice"
}

test_time_bound_sends_nothing_when_the_call_would_fail() {
  local rc=0
  : > "$TMP_ROOT/mail.log"
  FM_TEST_CAPTURE_TEXT="Book dentist" run_capture save --uid 70 >/dev/null
  run_capture file --uid 70 --bucket calendar --text "Book dentist" --time-bound >/dev/null 2>&1 || rc=$?
  expect_code 1 "$rc" "a calendar capture without a draft must fail"
  rc=0
  run_capture file --uid 70 --bucket nonsense --text "Book dentist" --time-bound >/dev/null 2>&1 || rc=$?
  expect_code 1 "$rc" "an unknown bucket must fail"
  rc=0
  run_capture file --uid 70 --bucket place --text "Book dentist" --attachment "$TMP_ROOT/missing.jpg" --time-bound >/dev/null 2>&1 || rc=$?
  expect_code 1 "$rc" "a missing attachment must fail"
  [ ! -s "$TMP_ROOT/mail.log" ] || fail "a failing time-bound call emailed the captain"
  pass "capture intake: a time-bound call that fails validation sends no notice"
}

test_arm_never_replaces_the_recipient() {
  local rc=0
  run_capture arm --to attacker@example.com >/dev/null 2>&1 || rc=$?
  expect_code 1 "$rc" "arm must refuse to replace the armed recipient"
  assert_equals "captain@example.com" "$(cat "$HOME_DIR/state/.capture-digest-to")" "arm replaced the armed recipient"
  run_capture arm --to captain@example.com >/dev/null || fail "re-arming the same recipient must succeed"
  pass "capture intake: arm keeps the first recipient until the captain clears it"
}

test_time_bound_without_armed_recipient_files_nothing() {
  local rc=0 out
  mv "$HOME_DIR/state/.capture-digest-to" "$TMP_ROOT/recipient.saved"
  FM_TEST_CAPTURE_TEXT="Pay today" run_capture save --uid 8 >/dev/null
  out=$(run_capture file --uid 8 --bucket task --text "Pay today" --time-bound 2>&1) || rc=$?
  mv "$TMP_ROOT/recipient.saved" "$HOME_DIR/state/.capture-digest-to"
  expect_code 1 "$rc" "a time-bound capture without an armed recipient must fail"
  [ ! -e "$HOME_DIR/data/captures/mail-8/.filed" ] || fail "a failed time-bound capture was marked filed"
  run_capture file --uid 8 --bucket task --text "Pay today" --time-bound >/dev/null
  assert_contains "$(cat "$TMP_ROOT/mail.log")" "Pay today" "retry after arming did not send the notice"
  pass "capture intake: a time-bound capture fails before filing when no recipient is armed"
}

test_rejects_mail_without_authenticated_braintoss_route
test_rejects_spoofed_authentication
test_rejected_mail_cannot_pose_as_accepted_capture
test_acceptance_slice_files_and_digests
test_people_stay_private_and_outward_work_waits
test_remaining_sort_table_routes_locally
test_person_capture_cannot_be_saved_again
test_filed_capture_save_is_a_no_op
test_attachment_must_be_inside_capture_and_link_is_encoded
test_backlog_titles_neutralise_metadata_shapes
test_late_captures_reach_the_next_digest
test_evening_digest_check_is_armed_and_sends_once
test_time_bound_capture_emails_immediately
test_time_bound_sends_nothing_when_the_call_would_fail
test_arm_never_replaces_the_recipient
test_time_bound_without_armed_recipient_files_nothing
