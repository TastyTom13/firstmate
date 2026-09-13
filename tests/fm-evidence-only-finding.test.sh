#!/usr/bin/env bash
# tests/fm-evidence-only-finding.test.sh - the info-severity evidence-only
# ask-user finding shape (bin/fm-classify-lib.sh) and the away-mode routing that
# consumes it (bin/fm-supervise-daemon.sh).
#
# `.agents/skills/ask-user-authority/SKILL.md` makes that exact shape firstmate's
# own call, so the away daemon must self-handle it with a durable note instead of
# spending a captain digest slot on it. Everything else about a `needs-decision`
# line must keep escalating exactly as before, so these cases drive the shape
# test's four gates apart one at a time and assert the daemon's routing verdict
# through the real classifier over real status files.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-classify-lib.sh
. "$ROOT/bin/fm-classify-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-supervise-daemon.sh"

TMP_ROOT=$(fm_test_tmproot fm-evidence-only-finding)

EVIDENCE_LINE='needs-decision [key=shot] [severity=info]: screenshot evidence missing for the accepted settings screen'

assert_shape() {  # <status-line> <yes|no> <label>
  local line=$1 want=$2 label=$3 got=no
  status_is_evidence_only_finding "$line" && got=yes
  [ "$got" = "$want" ] \
    || fail "$label: shape test returned '$got', want '$want' for: $line"
}

test_shape_gates() {
  assert_shape "$EVIDENCE_LINE" yes "declared info severity asking only for a screenshot"
  assert_shape 'needs-decision: severity=info the log excerpt backing the 40ms measurement is missing' \
    yes "colon-first severity declaration with a log-excerpt ask"
  assert_shape 'needs-decision [severity=info]: no citation for the rate limit the retry loop relies on' \
    yes "citation ask"

  assert_shape 'needs-decision [key=shot]: screenshot evidence missing for the settings screen' \
    no "undeclared severity"
  assert_shape 'needs-decision [severity=high]: screenshot evidence missing for the settings screen' \
    no "declared non-info severity"
  assert_shape 'needs-decision [severity=info]: add a screenshot step to the uploader and guarantee it retries' \
    no "an ask to change what is delivered"
  assert_shape 'needs-decision [severity=info]: pick REST or RPC for the sync endpoint' \
    no "a product call with no evidence ask"
  assert_shape 'blocked [severity=info]: screenshot evidence missing for the settings screen' \
    no "a blocker rather than a finding"
  assert_shape 'working [severity=info]: screenshot evidence missing for the settings screen' \
    no "nonterminal progress prose"
  assert_shape '' no "an empty line"
  pass "the shape test admits only a declared info-severity, evidence-only needs-decision line"
}

test_span_requires_every_event_to_have_the_shape() {
  local both mixed
  both="$EVIDENCE_LINE ; needs-decision [key=cite] [severity=info]: citation missing for the quoted limit"
  mixed="$EVIDENCE_LINE ; blocked [key=auth]: the deploy token expired"

  status_events_all_evidence_only "$both" \
    || fail "a span of only evidence-only findings was rejected"
  ! status_events_all_evidence_only "$mixed" \
    || fail "a span carrying an unrelated blocker was accepted as evidence-only"
  ! status_events_all_evidence_only '' \
    || fail "an empty events field was accepted as evidence-only"
  pass "a span qualifies only when every actionable event has the shape"
}

# One away-mode home with a single task whose status log holds <lines>.
signal_home() {  # <name> <status-lines>
  local name=$1 lines=$2 state
  state="$TMP_ROOT/$name/state"
  mkdir -p "$state"
  printf '%s\n' "$lines" > "$state/task.status"
  printf '%s' "$state"
}

test_daemon_self_handles_an_evidence_only_signal() {
  local state decision
  state=$(signal_home self-handled "$EVIDENCE_LINE")
  decision=$(classify_signal "$state/task.status" "$state")
  [ "${decision%%|*}" = note ] \
    || fail "an evidence-only signal was routed as '${decision%%|*}', want 'note': $decision"
  pass "an evidence-only finding is routed away from the captain-facing digest"
}

test_daemon_escalates_a_mixed_or_ordinary_signal() {
  local state decision
  state=$(signal_home mixed "$(printf '%s\nblocked [key=auth]: the deploy token expired\n' "$EVIDENCE_LINE")")
  decision=$(classify_signal "$state/task.status" "$state")
  [ "${decision%%|*}" = escalate ] \
    || fail "a span carrying a blocker was routed as '${decision%%|*}', want 'escalate': $decision"

  state=$(signal_home ordinary 'needs-decision [key=api]: pick REST or RPC for the sync endpoint')
  decision=$(classify_signal "$state/task.status" "$state")
  [ "${decision%%|*}" = escalate ] \
    || fail "an ordinary finding was routed as '${decision%%|*}', want 'escalate': $decision"
  pass "any other actionable event still reaches the captain-facing digest"
}

test_note_is_durable_and_advances_the_marker() {
  local state offset
  state=$(signal_home durable "$EVIDENCE_LINE")
  LOG="$state/.supervise-daemon.log"

  handle_wake "signal: $state/task.status" "$state" \
    || fail "handle_wake reported a classification failure for an evidence-only signal"

  [ -s "$state/.subsuper-self-handled" ] \
    || fail "no durable self-handled note was written"
  grep -q 'screenshot evidence missing' "$state/.subsuper-self-handled" \
    || fail "the durable note does not name the finding: $(cat "$state/.subsuper-self-handled")"
  [ ! -e "$state/.subsuper-escalations" ] \
    || fail "an evidence-only finding was buffered for the captain digest"

  # Marker contract: a self-handled wake still advances the classified position,
  # so the same finding is not re-routed on every later signal.
  offset=$(status_seen_offset "$state" task)
  [ "$offset" -gt 0 ] \
    || fail "the classified status position was not advanced: '$offset'"

  handle_wake "signal: $state/task.status" "$state" \
    || fail "handle_wake reported a classification failure on the repeat signal"
  [ "$(wc -l < "$state/.subsuper-self-handled")" -eq 1 ] \
    || fail "the same finding was noted twice: $(cat "$state/.subsuper-self-handled")"
  pass "the self-handled note is durable, uninjected, and written once per finding"
}

test_shape_gates
test_span_requires_every_event_to_have_the_shape
test_daemon_self_handles_an_evidence_only_signal
test_daemon_escalates_a_mixed_or_ordinary_signal
test_note_is_durable_and_advances_the_marker
