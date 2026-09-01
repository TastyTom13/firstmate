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

test_script_parses
test_help_renders
test_missing_backlog_is_refused
test_no_attributed_done_rows_is_a_clean_no_op
test_tallies_every_note_shape_and_status_proxy
