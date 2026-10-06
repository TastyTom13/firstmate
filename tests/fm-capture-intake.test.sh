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
  printf 'Uid: %s\n' "$uid"
  printf 'From: BrainToss <delivery@braintoss.app>\n'
  printf 'To: Firstmate <info.longbird+toss@gmail.com>\n'
  printf 'Authentication-Results: mx; dkim=pass header.i=@braintoss.app\n\n'
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

test_acceptance_slice_files_and_digests() {
  local digest place_dir out
  : > "$TMP_ROOT/mail.log"
  : > "$TMP_ROOT/tasks.log"

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

  run_capture digest --to captain@example.com >/dev/null
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
  run_capture digest --to captain@example.com >/dev/null
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
  : > "$TMP_ROOT/mail.log"
  save_and_file 6 task "Submit before 17:00" --time-bound --notify-to captain@example.com
  assert_contains "$(cat "$TMP_ROOT/mail.log")" "Time-bound phone capture" "time-bound capture did not notify immediately"
  pass "capture intake: only an explicitly time-bound capture sends an immediate notice"
}

test_rejects_mail_without_authenticated_braintoss_route
test_acceptance_slice_files_and_digests
test_people_stay_private_and_outward_work_waits
test_remaining_sort_table_routes_locally
test_evening_digest_check_is_armed_and_sends_once
test_time_bound_capture_emails_immediately
