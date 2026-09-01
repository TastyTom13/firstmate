#!/usr/bin/env bash
# Behavior tests for bin/fm-model-scorecard.sh - the read-only per-model
# delivery scorecard.
#
# Covers: parsing "model=<model> effort=<effort>" (and the local-only
# "local main model=<model> effort=<effort>" variant) out of a backlog's
# Done section and its configured archive; the fix-round and ask-user proxy
# tallies read from state/<id>.status; a Done row with no attribution note
# being silently skipped rather than crashing the tally; and the empty/no-op
# and missing-backlog paths.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-model-scorecard)
SCORECARD="$ROOT/bin/fm-model-scorecard.sh"

test_script_parses() {
  local out rc
  out=$(bash -n "$SCORECARD" 2>&1); rc=$?
  expect_code 0 "$rc" "bash -n bin/fm-model-scorecard.sh must parse cleanly (got: $out)"
  pass "fm-model-scorecard.sh: bash -n succeeds"
}

test_help_renders() {
  local out
  out=$("$SCORECARD" --help)
  assert_contains "$out" "read-only per-model delivery scorecard" \
    "fm-model-scorecard.sh --help lost its header"
  pass "fm-model-scorecard.sh: --help renders"
}

test_missing_backlog_is_refused() {
  local home out rc
  home="$TMP_ROOT/no-backlog"
  mkdir -p "$home/data" "$home/state"
  out=$(FM_HOME="$home" "$SCORECARD" 2>&1); rc=$?
  expect_code 1 "$rc" "a home with no backlog.md should refuse rather than print an empty table"
  assert_contains "$out" "no backlog at" \
    "the missing-backlog refusal did not name the expected path"
  pass "fm-model-scorecard.sh: a home with no backlog.md is refused, not silently empty"
}

test_no_attributed_done_rows_is_a_clean_no_op() {
  local home out rc
  home="$TMP_ROOT/empty-done"
  mkdir -p "$home/data" "$home/state"
  cat > "$home/data/backlog.md" <<'EOF'
# Backlog

## In flight

## Queued

## Done
- [x] pre-attribution-task - shipped before this contract existed (done 2026-01-01)
EOF
  out=$(FM_HOME="$home" "$SCORECARD" 2>&1); rc=$?
  expect_code 0 "$rc" "an unattributed-only Done section should still exit cleanly"
  assert_contains "$out" "no attributed Done tasks found" \
    "an unattributed Done row was not reported as the clean no-op it is"
  pass "fm-model-scorecard.sh: a Done section with no attributed rows is a clean no-op, not a parse failure"
}

# The real per-model tally, exercising every note shape bin/fm-teardown.sh's
# backlog_done_args can produce (PR, local-only, report) plus the archive
# file, plus the fix-round and ask-user status-log proxies.
test_tallies_every_note_shape_and_status_proxy() {
  local home out
  home="$TMP_ROOT/full-tally"
  mkdir -p "$home/data" "$home/state"
  cat > "$home/.tasks.toml" <<'EOF'
[markdown]
archive = "data/done-archive.md"
EOF
  cat > "$home/data/backlog.md" <<'EOF'
# Backlog

## In flight

## Queued

## Done
- [x] task-pr - shipped a PR https://github.com/o/r/pull/1 (merged 2026-08-02)
  model=claude-sonnet-5 effort=low
- [x] task-local - landed locally (done 2026-08-01)
  local main model=claude-sonnet-5 effort=medium
- [x] task-report - filed a report data/task-report/report.md (reported 2026-07-30)
  model=claude-opus-5 effort=high
- [x] task-no-status - no status log survived teardown (done 2026-07-01)
  model=claude-opus-5 effort=high
EOF
  mkdir -p "$home/data"
  cat > "$home/data/done-archive.md" <<'EOF'

## Archived 2026-06-01
- [x] task-archived - pruned into the archive https://github.com/o/r/pull/2 (merged 2026-06-01)
  model=claude-sonnet-5 effort=low
EOF
  cat > "$home/state/task-pr.status" <<'EOF'
working: setup complete
working: applying fix round 1
needs-decision: [key=x] which approach?
working: applying fix round 2
done: PR https://github.com/o/r/pull/1 checks green
EOF
  cat > "$home/state/task-local.status" <<'EOF'
working: setup complete
done: ready in branch fm/task-local
EOF
  cat > "$home/state/task-report.status" <<'EOF'
working: investigating
done: report at data/task-report/report.md
EOF
  cat > "$home/state/task-archived.status" <<'EOF'
working: setup complete
needs-decision: [key=y] ask-user finding F1
resolved: [key=y] answered
done: PR https://github.com/o/r/pull/2 checks green
EOF

  out=$(FM_HOME="$home" "$SCORECARD")

  assert_contains "$out" "MODEL" "the scorecard table lost its header"
  assert_contains "$out" "TASKS" "the scorecard table lost its TASKS column header"
  assert_contains "$out" "FIX-ROUNDS" "the scorecard table lost its FIX-ROUNDS column header"
  assert_contains "$out" "ASK-USER" "the scorecard table lost its ASK-USER column header"

  # claude-sonnet-5/low: task-pr (fix=2 ask=1) + task-archived (fix=0 ask=1) = 2 tasks, fix=2, ask=2.
  echo "$out" | grep -E '^claude-sonnet-5 +low +2 +2 +2$' >/dev/null \
    || fail "claude-sonnet-5/low row did not fold the PR-mode task with the archived task (got: $out)"

  # claude-sonnet-5/medium: task-local alone, no fix/ask-user status lines.
  echo "$out" | grep -E '^claude-sonnet-5 +medium +1 +0 +0$' >/dev/null \
    || fail "claude-sonnet-5/medium (local-only note) row is missing or wrong (got: $out)"

  # claude-opus-5/high: task-report (report-mode note, no fix/ask-user text) +
  # task-no-status (no status log at all, so it must contribute zeros rather
  # than erroring) = 2 tasks, fix=0, ask=0.
  echo "$out" | grep -E '^claude-opus-5 +high +2 +0 +0$' >/dev/null \
    || fail "claude-opus-5/high row did not combine the report-mode task with the status-less task (got: $out)"

  pass "fm-model-scorecard.sh: tallies tasks, fix-rounds, and ask-user findings per model/effort across every note shape and the archive"
}

# Regression: tasks-axi appends the close note to the END of the task body, so
# a Done entry with body text renders as bullet / body lines / note. The note
# must still be found, not only when it is the line right after the checkbox.
test_note_after_body_lines_is_attributed() {
  local home out
  home="$TMP_ROOT/note-after-body"
  mkdir -p "$home/data" "$home/state"
  cat > "$home/data/backlog.md" <<'EOF'
# Backlog

## Done
- [x] task-bodied - shipped a PR https://github.com/o/r/pull/9 (merged 2026-08-05)
  Intent: ship it

  More body text, including a mention of model= in prose.
  model=claude-opus-5 effort=xhigh
- [x] task-plain - landed locally (done 2026-08-05)
  model=claude-opus-5 effort=xhigh
EOF
  out=$(FM_HOME="$home" "$SCORECARD")
  echo "$out" | grep -E '^claude-opus-5 +xhigh +2 +0 +0$' >/dev/null \
    || fail "a Done entry whose note follows body lines was not attributed (got: $out)"
  pass "fm-model-scorecard.sh: an attribution note after body lines is still tallied"
}

# Regression: bin/fm-classify-lib.sh documents keyed and correlated
# needs-decision shapes alongside the bare one; all three are ask-user
# escalations and must be counted.
test_ask_user_counts_every_needs_decision_shape() {
  local home out
  home="$TMP_ROOT/ask-user-shapes"
  mkdir -p "$home/data" "$home/state"
  cat > "$home/data/backlog.md" <<'EOF'
# Backlog

## Done
- [x] task-shapes - shipped a PR https://github.com/o/r/pull/10 (merged 2026-08-06)
  model=claude-sonnet-5 effort=high
EOF
  cat > "$home/state/task-shapes.status" <<'EOF'
working: setup complete
needs-decision [key=a]: which one?
needs-decision: [key=b] other?
needs-decision corr=0123456789abcdef [key=c]: third?
working: not a needs-decision line
EOF
  out=$(FM_HOME="$home" "$SCORECARD")
  echo "$out" | grep -E '^claude-sonnet-5 +high +1 +0 +3$' >/dev/null \
    || fail "the ask-user proxy did not count every documented needs-decision shape (got: $out)"
  pass "fm-model-scorecard.sh: ask-user proxy counts bare, keyed, and correlated needs-decision lines"
}

# Regression: tasks-axi resolves an absolute `archive` value as-is, so joining
# it onto the home root silently dropped every archived task from the tally.
test_absolute_archive_path_is_read_as_is() {
  local home out
  home="$TMP_ROOT/absolute-archive"
  mkdir -p "$home/data" "$home/state" "$home/elsewhere"
  cat > "$home/.tasks.toml" <<EOF
[markdown]
archive = "$home/elsewhere/done.md"
EOF
  cat > "$home/data/backlog.md" <<'EOF'
# Backlog

## Done
- [x] task-live - shipped a PR https://github.com/o/r/pull/11 (merged 2026-08-07)
  model=claude-opus-5 effort=medium
EOF
  cat > "$home/elsewhere/done.md" <<'EOF'

## Archived 2026-07-01
- [x] task-filed-away - pruned into the archive https://github.com/o/r/pull/12 (merged 2026-07-01)
  model=claude-opus-5 effort=medium
EOF
  out=$(FM_HOME="$home" "$SCORECARD")
  echo "$out" | grep -E '^claude-opus-5 +medium +2 +0 +0$' >/dev/null \
    || fail "an absolute .tasks.toml archive path was not read, so archived tasks went missing (got: $out)"
  pass "fm-model-scorecard.sh: an absolute archive path in .tasks.toml is read as-is"
}

# Regression: tasks-axi honours only [markdown].archive (an archive key under
# any other table is ignored), and the no-op message must not name an archive
# that was never read.
test_archive_key_outside_markdown_table_is_ignored() {
  local home out
  home="$TMP_ROOT/foreign-archive-table"
  mkdir -p "$home/data" "$home/state"
  cat > "$home/.tasks.toml" <<EOF
[markdown]
archive = "$home/data/real-archive.md"

[other]
archive = "$home/data/decoy-archive.md"
EOF
  cat > "$home/data/backlog.md" <<'EOF'
# Backlog

## Done
EOF
  cat > "$home/data/real-archive.md" <<'EOF'

## Archived 2026-05-01
- [x] task-real - archived https://github.com/o/r/pull/13 (merged 2026-05-01)
  model=claude-sonnet-5 effort=xhigh
EOF
  cat > "$home/data/decoy-archive.md" <<'EOF'

## Archived 2026-05-01
- [x] task-decoy - archived https://github.com/o/r/pull/14 (merged 2026-05-01)
  model=decoy-model effort=low
EOF
  out=$(FM_HOME="$home" "$SCORECARD")
  echo "$out" | grep -E '^claude-sonnet-5 +xhigh +1 +0 +0$' >/dev/null \
    || fail "[markdown].archive was not the archive the scorecard read (got: $out)"
  echo "$out" | grep -q 'decoy-model' \
    && fail "an archive key outside the [markdown] table was honoured (got: $out)"
  pass "fm-model-scorecard.sh: only [markdown].archive selects the archive file"
}

test_no_op_message_names_only_files_it_read() {
  local home out
  home="$TMP_ROOT/no-archive-on-disk"
  mkdir -p "$home/data" "$home/state"
  cat > "$home/data/backlog.md" <<'EOF'
# Backlog

## Done
- [x] pre-attribution-task - shipped before this contract existed (done 2026-01-01)
EOF
  out=$(FM_HOME="$home" "$SCORECARD")
  echo "$out" | grep -q 'done-archive.md' \
    && fail "the no-op message named an archive file that does not exist (got: $out)"
  assert_contains "$out" "no attributed Done tasks found in $home/data/backlog.md" \
    "the no-op message did not name the backlog it actually read"
  pass "fm-model-scorecard.sh: the no-op message names only the files it read"
}

# Regression: bin/fm-fleet-snapshot.sh treats `- [X]` as a Done row too, so a
# hand-edited or foreign-written uppercase checkbox must not silently drop a
# task from the tally.
test_uppercase_checkbox_done_rows_are_tallied() {
  local home out
  home="$TMP_ROOT/uppercase-checkbox"
  mkdir -p "$home/data" "$home/state"
  cat > "$home/data/backlog.md" <<'EOF'
# Backlog

## Done
- [X] task-upper - hand-edited close https://github.com/o/r/pull/15 (merged 2026-08-08)
  model=claude-sonnet-5 effort=low
- [x] task-lower - shipped https://github.com/o/r/pull/16 (merged 2026-08-08)
  model=claude-sonnet-5 effort=low
EOF
  out=$(FM_HOME="$home" "$SCORECARD")
  echo "$out" | grep -E '^claude-sonnet-5 +low +2 +0 +0$' >/dev/null \
    || fail "an uppercase [X] Done row was dropped from the tally (got: $out)"
  pass "fm-model-scorecard.sh: an uppercase [X] Done row is tallied like a lowercase one"
}

test_script_parses
test_help_renders
test_missing_backlog_is_refused
test_no_attributed_done_rows_is_a_clean_no_op
test_tallies_every_note_shape_and_status_proxy
test_note_after_body_lines_is_attributed
test_ask_user_counts_every_needs_decision_shape
test_absolute_archive_path_is_read_as_is
test_archive_key_outside_markdown_table_is_ignored
test_no_op_message_names_only_files_it_read
test_uppercase_checkbox_done_rows_are_tallied
