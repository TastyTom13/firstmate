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
  assert_contains "$out" "collected 2 owner-words file(s) from copy-board" "collect did not report what it collected"
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
  mkdir -p "$home/data/path-task" "$home/data/home-task"
  printf '%s\n' 'You are in a disposable git worktree of projects/forge, at a detached HEAD on a clean default branch.' \
    > "$home/data/path-task/brief.md"
  printf '%s\n' 'Path words.' > "$home/data/path-task/captain-notes-2026-10-18.md"
  printf '%s\n' 'You are in a disposable git worktree of ., at a detached HEAD on a clean default branch.' \
    > "$home/data/home-task/brief.md"
  printf '%s\n' 'Home words.' > "$home/data/home-task/captain-notes-2026-10-17.md"
  out=$(run_notes "$home" backfill 2>&1) || fail "backfill failed: $out"
  assert_exact_line "$home/data/owner-notes/forge.md" 'Live words.' "backfill missed a live task's notes"
  assert_exact_line "$home/data/owner-notes/lens.md" 'Gone words.' "backfill missed a cleaned-up task's notes"
  assert_exact_line "$home/data/owner-notes/forge.md" 'Path words.' "backfill did not name a project given by a relative path"
  assert_exact_line "$home/data/owner-notes/firstmate.md" 'Home words.' "backfill did not name the firstmate home given as ."
  assert_contains "$out" "no project could be resolved for orphan; collecting into general" "backfill did not list the unresolved task"
  assert_exact_line "$home/data/owner-notes/general.md" 'Orphan words.' "backfill lost an unresolved task's notes"
  pass "backfill collects from live and cleaned-up tasks and keeps what it cannot resolve in general"
}

test_file_refuses_unsafe_project_names() {
  local home out rc
  home=$(new_home file)
  out=$(run_notes "$home" file forge) || fail "file refused a plain project name"
  assert_equals "$home/data/owner-notes/forge.md" "$out" "file printed the wrong path"
  for name in '' '.' '..' '...'; do
    rc=0
    run_notes "$home" file "$name" >/dev/null 2>&1 || rc=$?
    [ "$rc" -ne 0 ] || fail "file accepted the empty project name '$name'"
  done
  out=$(run_notes "$home" file '../escape') || fail "file refused a name with slashes"
  assert_equals "$home/data/owner-notes/-escape.md" "$out" "file let a slash escape the owner-notes directory"
  pass "file maps unsafe project names to one safe file and refuses only empty ones"
}

test_unsafe_project_paths_collect_into_the_file_the_brief_names() {
  local home path out dest slug
  home=$(new_home unsafe)
  mkdir -p "$home/data/copy-board"
  printf '%s\n' 'Spaced words.' > "$home/data/copy-board/captain-notes-2026-10-23.md"
  for slug in 'My App:My-App' '.hidden:hidden'; do
    path="$home/projects/${slug%%:*}"
    mkdir -p "$path"
    out=$(run_notes "$home" collect copy-board --project-path "$path") || fail "collect failed for '${slug%%:*}': $out"
    dest=$(run_notes "$home" file "$(basename "$path")") || fail "file refused '${slug%%:*}'"
    assert_equals "$home/data/owner-notes/${slug##*:}.md" "$dest" "file named a different file than collect fills"
    assert_exact_line "$dest" 'Spaced words.' "notes for '${slug%%:*}' did not land in the file the brief names"
  done
  pass "unsafe project paths collect into the same file that file names"
}

test_task_without_notes_collects_cleanly_for_any_project_name() {
  local home path out
  home=$(new_home nonotes)
  mkdir -p "$home/data/quiet"
  for path in "$home/projects/My App" "$home/projects/.hidden"; do
    mkdir -p "$path"
    out=$(run_notes "$home" collect quiet --project-path "$path" 2>&1) || fail "collect refused a task with no notes: $out"
  done
  [ ! -e "$home/data/owner-notes" ] || fail "collect created owner notes for a task with no notes"
  pass "a task with no notes collects cleanly whatever its project is called"
}

test_backfill_sweeps_board_and_chat_answer_files() {
  local home before out
  home=$(new_home boards)
  mkdir -p "$home/data/lens-board" "$home/data/draft-board"
  printf '%s\n' 'You are in a disposable git worktree of lens, at a detached HEAD on a clean default branch.' \
    > "$home/data/lens-board/brief.md"
  cp "$home/data/lens-board/brief.md" "$home/data/draft-board/brief.md"
  printf '%s\n' 'C1: keep the default.' > "$home/data/lens-board/captain-answers-2026-09-25.md"
  printf '%s\n' 'D1: own menu item.' > "$home/data/lens-board/board-answers.md"
  printf '%s\n' "# Lens board, the captain's answers" 'Q1: weekly digest.' > "$home/data/lens-board/answers.md"
  printf '%s\n' "# Owner's words, verbatim, 2026-10-24 (chat)" 'Show me where each one went.' \
    > "$home/data/lens-board/chat-2026-10-24.md"
  printf '%s\n' '## Round 1 applied.' 'Firstmate reply text.' > "$home/data/lens-board/reply-round1.md"
  printf '%s\n' '# Answers drafted for the owner to edit' 'Drafted text.' > "$home/data/draft-board/answers.md"
  out=$(run_notes "$home" backfill 2>&1) || fail "backfill failed: $out"
  assert_exact_line "$home/data/owner-notes/lens.md" 'C1: keep the default.' "backfill missed a captain-answers file"
  assert_exact_line "$home/data/owner-notes/lens.md" 'D1: own menu item.' "backfill missed a board-answers file"
  assert_exact_line "$home/data/owner-notes/lens.md" 'Q1: weekly digest.' "backfill missed an answers file headed as the captain's"
  assert_exact_line "$home/data/owner-notes/lens.md" 'Show me where each one went.' "backfill missed a file headed as verbatim owner words"
  assert_exact_line "$home/data/owner-notes/lens.md" "## 2026-09-25 - lens-board" "a dated answers file was not headed with its date"
  assert_no_grep 'Firstmate reply text.' "$home/data/owner-notes/lens.md" "backfill swept a firstmate board reply as owner words"
  assert_no_grep 'Drafted text.' "$home/data/owner-notes/lens.md" "backfill swept an answers file not headed as the captain's"
  assert_no_grep 'disposable git worktree' "$home/data/owner-notes/lens.md" "backfill swept a brief as owner words"
  before=$(cat "$home/data/owner-notes/lens.md")
  run_notes "$home" backfill >/dev/null 2>&1 || fail "repeated backfill failed"
  assert_equals "$before" "$(cat "$home/data/owner-notes/lens.md")" "a repeated backfill changed the owner notes"
  pass "backfill sweeps board and chat answer files once and leaves replies and drafts alone"
}

test_backfill_sweeps_dated_captain_md_entries_by_project() {
  local home before_md before_notes out
  home=$(new_home captainmd)
  printf '%s\n' '# Projects' '' '- scout [no-mistakes +yolo] - Search.' '- bull [direct-PR] - Trading.' \
    '- doc-creator [direct-PR] - Decks.' > "$home/data/projects.md"
  cat > "$home/data/captain.md" <<'MD'
# Captain preferences

## Working style
- Undated standing rule about Scout.
- 2026-08-30: Scout words from before September.

## 2026-10-12 ledger (captain words)
"The Scout ledger should feel like an operating room."
- an undated note inside the dated section.

## Rulings
- 2026-10-13 Bull: "paper trading only until the risk limits hold."
  continued on a second line.
- 6 Oct 2026: "nothing the captain says may get lost."
- 2026-10-14, the doc creator deploy: guide me step by step.
MD
  before_md=$(cat "$home/data/captain.md")
  out=$(run_notes "$home" backfill 2>&1) || fail "backfill failed: $out"
  assert_equals "$before_md" "$(cat "$home/data/captain.md")" "backfill rewrote data/captain.md"
  assert_exact_line "$home/data/owner-notes/scout.md" '"The Scout ledger should feel like an operating room."' \
    "a dated captain.md section was not routed to the project it names"
  assert_exact_line "$home/data/owner-notes/scout.md" '- an undated note inside the dated section.' \
    "a dated section lost its undated lines"
  assert_exact_line "$home/data/owner-notes/scout.md" '## 2026-10-12 - captain.md' "a captain.md entry lacks its date heading"
  assert_exact_line "$home/data/owner-notes/bull.md" '- 2026-10-13 Bull: "paper trading only until the risk limits hold."' \
    "a dated captain.md bullet was not routed to the project it names"
  assert_exact_line "$home/data/owner-notes/bull.md" '  continued on a second line.' "a dated bullet lost its continuation line"
  assert_exact_line "$home/data/owner-notes/general.md" '- 6 Oct 2026: "nothing the captain says may get lost."' \
    "a dated captain.md bullet naming no project did not land in general"
  assert_exact_line "$home/data/owner-notes/general.md" '## 2026-10-06 - captain.md' "a written-out date was not read as 2026-10-06"
  assert_exact_line "$home/data/owner-notes/doc-creator.md" '- 2026-10-14, the doc creator deploy: guide me step by step.' \
    "a bullet naming a hyphenated project in words was not routed to it"
  cat "$home/data/owner-notes/"*.md > "$home/all-notes"
  assert_no_grep 'Undated standing rule' "$home/all-notes" "backfill swept an undated captain.md line"
  assert_no_grep 'before September' "$home/all-notes" "backfill swept a captain.md entry dated before 2026-09-01"
  before_notes=$(cat "$home/data/owner-notes/"*.md)
  run_notes "$home" backfill >/dev/null 2>&1 || fail "repeated backfill failed"
  assert_equals "$before_notes" "$(cat "$home/data/owner-notes/"*.md)" "a repeated backfill appended captain.md entries again"
  pass "backfill sweeps dated captain.md entries since September once, by the project each names"
}

test_index_lists_every_note_and_every_unplaced_note() {
  local home index
  home=$(new_home index)
  mkdir -p "$home/data/forge-board" "$home/data/lens-task"
  printf '%s\n' '# Captain notes' 'one two three four five six seven eight nine ten eleven twelve thirteen fourteen' \
    > "$home/data/forge-board/captain-notes-2026-10-23.md"
  printf '%s\n' 'Lens | weekly digest.' > "$home/data/lens-task/captain-notes-2026-10-20.md"
  run_notes "$home" collect forge-board --project forge >/dev/null || fail "collect forge failed"
  run_notes "$home" collect lens-task --project lens >/dev/null || fail "collect lens failed"
  run_notes "$home" index >/dev/null || fail "index failed"
  index="$home/data/owner-notes/index.md"
  assert_present "$index" "index did not write data/owner-notes/index.md"
  assert_grep '| 2026-10-23 | forge | forge-board | one two three four five six seven eight nine ten eleven twelve | not yet placed |' \
    "$index" "index row lacks the date, project, source, first twelve words, or unplaced destination"
  assert_no_grep 'thirteen' "$index" "index copied more than the first twelve words"
  assert_grep '| 2026-10-20 | lens | lens-task | Lens \| weekly digest. | not yet placed |' "$index" \
    "index did not escape a pipe in the note"
  assert_grep '## Not yet placed' "$index" "index has no unplaced section"
  assert_grep '### forge' "$index" "the unplaced section does not group forge's notes"
  assert_grep '### lens' "$index" "the unplaced section does not group lens's notes"
  assert_grep '| forge | 1 | 0 | 1 |' "$index" "the summary does not count forge's notes"
  pass "index lists one row per note and names every unplaced note by project"
}

test_place_records_the_destination_the_index_shows() {
  local home dest sha out before rc
  home=$(new_home place)
  mkdir -p "$home/data/forge-board"
  printf '%s\n' 'Retained Search for AI-leaders.' > "$home/data/forge-board/captain-notes-2026-10-23.md"
  printf '%s\n' 'Second words.' > "$home/data/forge-board/captain-notes-2026-10-24.md"
  run_notes "$home" collect forge-board --project forge >/dev/null || fail "collect failed"
  dest="$home/data/owner-notes/forge.md"
  sha=$(sed -n 's/^<!-- fm-owner-notes task=forge-board file=captain-notes-2026-10-23.md sha256=\([0-9a-f]*\) -->$/\1/p' "$dest")
  [ -n "$sha" ] || fail "collect wrote no entry marker: $(cat "$dest")"
  out=$(run_notes "$home" place forge "${sha:0:12}" docs/IDEAL_STATE.md:42) || fail "place failed: $out"
  assert_exact_line "$dest" '<!-- fm-owner-notes placed=docs/IDEAL_STATE.md:42 -->' "place did not write the placement marker"
  [ "$(grep -A1 -F "sha256=$sha -->" "$dest" | tail -n 1)" = '<!-- fm-owner-notes placed=docs/IDEAL_STATE.md:42 -->' ] \
    || fail "the placement marker is not next to its entry: $(cat "$dest")"
  before=$(cat "$dest")
  run_notes "$home" place forge "${sha:0:12}" docs/IDEAL_STATE.md:42 >/dev/null || fail "repeated place failed"
  assert_equals "$before" "$(cat "$dest")" "a repeated place wrote a second marker"
  rc=0; run_notes "$home" place forge 0000000000 docs/x.md:1 >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "place accepted a hash that names no entry"
  rc=0; run_notes "$home" place forge "${sha:0:12}" /abs/path.md:1 >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "place accepted an absolute destination"
  rc=0; run_notes "$home" place forge "${sha:0:12}" 'docs/x.md:1 -->' >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "place accepted a destination that closes the marker"
  run_notes "$home" index >/dev/null || fail "index failed"
  assert_grep '| Retained Search for AI-leaders. | docs/IDEAL_STATE.md:42 |' "$home/data/owner-notes/index.md" \
    "index did not show the placed destination"
  sed -n '/^## Not yet placed/,$p' "$home/data/owner-notes/index.md" > "$home/unplaced"
  assert_no_grep 'Retained Search' "$home/unplaced" "index still lists a placed note as unplaced"
  assert_grep 'Second words.' "$home/unplaced" "index dropped the still-unplaced note from its worklist"
  pass "place writes a placement marker next to its entry once and the index shows it"
}

test_collect_appends_verbatim_with_date_and_task
test_collect_is_idempotent_and_never_edits_earlier_entries
test_firstmate_home_tasks_collect_into_firstmate
test_undated_notes_use_the_file_date
test_backfill_resolves_projects_and_lists_the_unresolved
test_file_refuses_unsafe_project_names
test_unsafe_project_paths_collect_into_the_file_the_brief_names
test_task_without_notes_collects_cleanly_for_any_project_name
test_backfill_sweeps_board_and_chat_answer_files
test_backfill_sweeps_dated_captain_md_entries_by_project
test_index_lists_every_note_and_every_unplaced_note
test_place_records_the_destination_the_index_shows
