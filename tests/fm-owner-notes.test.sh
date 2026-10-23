#!/usr/bin/env bash
# Behavior tests for bin/fm-owner-notes.sh: the captain's verbatim notes from a
# task land in the project's owner notes, append-only and idempotently.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-owner-notes)
NOTES="$ROOT/bin/fm-owner-notes.sh"

run_notes() {  # <home> <args...>
  local home=$1
  shift
  FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" \
    bash "$NOTES" "$@"
}

new_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/data" "$home/state" "$home/projects/forge"
  printf '%s' "$home"
}

test_collect_appends_verbatim_with_date_and_task() {
  local home dest out
  home=$(new_home collect)
  mkdir -p "$home/data/copy-board"
  printf '%s\n' '# Captain notes' '"Retained Search for AI-leaders."' 'Applied: kept as the hero line.' \
    > "$home/data/copy-board/captain-notes-2026-10-23.md"
  printf '%s\n' 'Second session words.' > "$home/data/copy-board/captain-notes-2026-10-24-chat.md"
  out=$(run_notes "$home" collect copy-board --project-path "$home/projects/forge") \
    || fail "collect failed: $out"
  dest="$home/data/owner-notes/forge.md"
  assert_present "$dest" "collect did not create the project's owner notes"
  assert_exact_line "$dest" "## 2026-10-23 - copy-board" "first entry heading lacks its date or task id"
  assert_exact_line "$dest" "## 2026-10-24 - copy-board" "second entry heading lacks its date or task id"
  assert_exact_line "$dest" '"Retained Search for AI-leaders."' "the captain's words were not copied verbatim"
  assert_exact_line "$dest" 'Applied: kept as the hero line.' "what the worker did was not copied"
  assert_exact_line "$dest" 'Second session words.' "a suffixed notes file was not collected"
  assert_present "$home/data/copy-board/captain-notes-2026-10-23.md" "collect removed the task's own copy"
  assert_contains "$out" "collected 2 captain-notes file(s) from copy-board" "collect did not report what it collected"
  pass "collect appends each captain-notes file verbatim under a date and task heading"
}

test_collect_is_idempotent_and_never_edits_earlier_entries() {
  local home dest before after first
  home=$(new_home idempotent)
  mkdir -p "$home/data/copy-board"
  printf '%s\n' 'Original words.' > "$home/data/copy-board/captain-notes-2026-10-23.md"
  run_notes "$home" collect copy-board --project forge >/dev/null || fail "first collect failed"
  dest="$home/data/owner-notes/forge.md"
  before=$(cat "$dest")
  run_notes "$home" collect copy-board --project forge >/dev/null || fail "repeated collect failed"
  after=$(cat "$dest")
  assert_equals "$before" "$after" "a repeated collect changed the owner notes"

  printf '%s\n' 'Later words.' >> "$home/data/copy-board/captain-notes-2026-10-23.md"
  run_notes "$home" collect copy-board --project forge >/dev/null || fail "collect after growth failed"
  first=$(head -c "${#before}" "$dest")
  assert_equals "$before" "$first" "collect edited an earlier entry instead of appending"
  [ "$(grep -c '^## 2026-10-23 - copy-board$' "$dest")" = 2 ] \
    || fail "a grown notes file did not land again as a new entry: $(cat "$dest")"
  assert_exact_line "$dest" 'Later words.' "the grown notes were not collected"
  pass "collect appends nothing on repeat and lands a grown notes file as a new entry"
}

test_firstmate_home_tasks_collect_into_firstmate() {
  local home
  home=$(new_home firstmate)
  mkdir -p "$home/data/fm-task"
  printf '%s\n' 'Firstmate words.' > "$home/data/fm-task/captain-notes-2026-10-23.md"
  run_notes "$home" collect fm-task --project-path "$home" >/dev/null || fail "collect failed"
  assert_present "$home/data/owner-notes/firstmate.md" "a firstmate-home task did not collect into firstmate.md"
  pass "a task whose project is the firstmate home collects into firstmate.md"
}

test_undated_notes_use_the_file_date() {
  local home
  home=$(new_home undated)
  mkdir -p "$home/data/board"
  printf '%s\n' 'Round four words.' > "$home/data/board/captain-notes-round4.md"
  touch -t 202610151200 "$home/data/board/captain-notes-round4.md"
  run_notes "$home" collect board --project forge >/dev/null || fail "collect failed"
  assert_exact_line "$home/data/owner-notes/forge.md" "## 2026-10-15 - board" \
    "an undated notes file was not headed with its modification date"
  pass "an undated notes file is headed with its modification date"
}

test_backfill_resolves_projects_and_lists_the_unresolved() {
  local home out
  home=$(new_home backfill)
  mkdir -p "$home/data/live-task" "$home/data/gone-task" "$home/data/orphan"
  printf '%s\n' "project=$home/projects/forge" > "$home/state/live-task.meta"
  printf '%s\n' 'Live words.' > "$home/data/live-task/captain-notes-2026-10-23.md"
  printf '%s\n' 'You are in a disposable git worktree of lens, at a detached HEAD on a clean default branch.' \
    > "$home/data/gone-task/brief.md"
  printf '%s\n' 'Gone words.' > "$home/data/gone-task/captain-notes-2026-10-20.md"
  printf '%s\n' 'Orphan words.' > "$home/data/orphan/captain-notes-2026-10-19.md"
  out=$(run_notes "$home" backfill 2>&1) || fail "backfill failed: $out"
  assert_exact_line "$home/data/owner-notes/forge.md" 'Live words.' "backfill missed a live task's notes"
  assert_exact_line "$home/data/owner-notes/lens.md" 'Gone words.' "backfill missed a cleaned-up task's notes"
  assert_contains "$out" "skipped orphan: no project could be resolved" "backfill did not list the unresolved task"
  pass "backfill collects from live and cleaned-up tasks and lists what it cannot resolve"
}

test_file_refuses_unsafe_project_names() {
  local home out rc
  home=$(new_home file)
  out=$(run_notes "$home" file forge) || fail "file refused a plain project name"
  assert_equals "$home/data/owner-notes/forge.md" "$out" "file printed the wrong path"
  for name in '../escape' '.hidden' ''; do
    rc=0
    run_notes "$home" file "$name" >/dev/null 2>&1 || rc=$?
    [ "$rc" -ne 0 ] || fail "file accepted the unsafe project name '$name'"
  done
  pass "file prints the owner-notes path and refuses unsafe project names"
}

test_collect_appends_verbatim_with_date_and_task
test_collect_is_idempotent_and_never_edits_earlier_entries
test_firstmate_home_tasks_collect_into_firstmate
test_undated_notes_use_the_file_date
test_backfill_resolves_projects_and_lists_the_unresolved
test_file_refuses_unsafe_project_names
