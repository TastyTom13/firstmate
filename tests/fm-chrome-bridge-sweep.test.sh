#!/usr/bin/env bash
# Behavior tests for browser bridge ownership, age selection, and family reap.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-chrome-bridge-sweep)
SWEEP="$ROOT/bin/fm-chrome-bridge-sweep.sh"
PS_FILE="$TMP_ROOT/ps.tsv"
CWD_FILE="$TMP_ROOT/cwd.tsv"
KILL_LOG="$TMP_ROOT/kills"
TASK="$TMP_ROOT/task"
OTHER="$TMP_ROOT/other"
OWNER_DIR="$TMP_ROOT/state"
mkdir -p "$TASK/subdir" "$OTHER" "$OWNER_DIR"

write_fixtures() {
  cat > "$PS_FILE" <<EOF
100	1	00:11:00	/bin/agent-owner
101	100	00:10:00	node /opt/chrome-devtools-axi-bridge.js
102	101	00:09:59	node /opt/chrome-devtools-mcp.js
103	102	00:09:58	/Applications/Google Chrome --headless
200	1	08:01:00	/bin/agent-owner
201	200	08:00:00	node /opt/chrome-devtools-axi-bridge.js
202	201	07:59:59	node /opt/chrome-devtools-mcp.js
301	1	00:05:00	node /opt/chrome-devtools-axi-bridge.js
302	1	07:00:00	node /opt/chrome-devtools-axi-bridge.js
601	600	00:05:00	/bin/agent-descendant
602	600	00:05:00	node /opt/chrome-devtools-axi-bridge.js
401	1	00:05:00	node /opt/chrome-devtools-axi-bridge.js
501	1	1-02:03:04	node /opt/unrelated.js
EOF
  cat > "$CWD_FILE" <<EOF
101	$TASK/subdir
102	$TASK/subdir
103	$TASK/subdir
201	$OTHER
301	$TMP_ROOT/gone
302	$OTHER
602	$TMP_ROOT/gone-descendant
EOF
}
write_fixtures
FM_BRIDGE_OWNER_DIR="$OWNER_DIR" "$SWEEP" --record-owner task-missing "$TMP_ROOT/gone" 301 999 >/dev/null || fail "missing-owner record is written"
FM_BRIDGE_OWNER_DIR="$OWNER_DIR" "$SWEEP" --record-owner live-owner "$OTHER" 201 200 >/dev/null || fail "live-owner record is written"
FM_BRIDGE_OWNER_DIR="$OWNER_DIR" "$SWEEP" --record-owner existing-owner "$OTHER" 302 998 >/dev/null || fail "existing-owner record is written"
FM_BRIDGE_OWNER_DIR="$OWNER_DIR" "$SWEEP" --record-owner live-descendant "$TMP_ROOT/gone-descendant" 602 600 >/dev/null || fail "descendant-owner record is written"

out=$(FM_BRIDGE_PS_FILE="$PS_FILE" FM_BRIDGE_CWD_FILE="$CWD_FILE" \
  "$SWEEP" --worktree "$TASK") || fail "task inventory runs"
printf '%s\n' "$out" | grep -F $'101\t00:10:00' | grep -F $'would-stop\ttask-worktree' >/dev/null \
  || fail "task-owned bridge is selected"
if printf '%s\n' "$out" | grep -F $'201\t08:00:00' >/dev/null; then
  fail "task inventory included another worktree bridge"
fi
printf '%s\n' "$out" | grep -F $'401\t00:05:00\tunknown\tunknown\towner-unresolved' >/dev/null \
  || fail "unknown ownership is reported"
pass "task mode selects only the bridge owned by that worktree"

: > "$KILL_LOG"
FM_BRIDGE_PS_FILE="$PS_FILE" FM_BRIDGE_CWD_FILE="$CWD_FILE" \
  FM_BRIDGE_KILL_LOG="$KILL_LOG" FM_BRIDGE_TERM_GRACE_SECS=0 \
  "$SWEEP" --apply --worktree "$TASK" >/dev/null || fail "task apply runs"
for expected in "TERM 101" "TERM 102" "TERM 103" "KILL 101" "KILL 102" "KILL 103"; do
  grep -Fx "$expected" "$KILL_LOG" >/dev/null || fail "missing family signal $expected"
done
if grep -Eq ' (201|202|301|401)$' "$KILL_LOG"; then
  fail "task apply signaled an unowned bridge family"
fi
pass "task apply retires the owned bridge, MCP, and Chrome descendants"

out=$(FM_BRIDGE_PS_FILE="$PS_FILE" FM_BRIDGE_CWD_FILE="$CWD_FILE" \
  FM_BRIDGE_OWNER_DIR="$OWNER_DIR" FM_BRIDGE_MAX_AGE_HOURS=6 "$SWEEP") || fail "global inventory runs"
printf '%s\n' "$out" | grep -F $'201\t08:00:00' | grep -F $'keep\towner-live' >/dev/null \
  || fail "old bridge with a live owner is protected"
printf '%s\n' "$out" | grep -F $'301\t00:05:00' | grep -F $'would-stop\towner-missing' >/dev/null \
  || fail "missing owner is selected"
printf '%s\n' "$out" | grep -F $'101\t00:10:00' | grep -F $'unknown\towner-unrecorded' >/dev/null \
  || fail "unrecorded bridge remains protected"
printf '%s\n' "$out" | grep -F $'302\t07:00:00' | grep -F $'keep\tlong-running' >/dev/null \
  || fail "existing worktree bridge remains protected"
printf '%s\n' "$out" | grep -F $'401\t00:05:00' | grep -F $'unknown\towner-unrecorded' >/dev/null \
  || fail "unrecorded bridge is listed but not selected"
printf '%s\n' "$out" | grep -F $'602\t00:05:00' | grep -F $'keep\towner-live' >/dev/null \
  || fail "live owner descendant remains protected"
pass "global mode requires records and protects live owners"

summary=$(FM_BRIDGE_PS_FILE="$PS_FILE" FM_BRIDGE_CWD_FILE="$CWD_FILE" \
  FM_BRIDGE_OWNER_DIR="$OWNER_DIR" "$SWEEP" --summary) || fail "summary runs"
printf '%s\n' "$summary" | grep -F 'BROWSER_BRIDGES: 1 orphan bridge(s), 2 unknown, 1 long-running and protected' >/dev/null \
  || fail "summary reports candidate, unknown, and protected counts"
printf '%s\n' "$summary" | grep -F "inspect: $SWEEP; apply: $SWEEP --apply" >/dev/null \
  || fail "summary gives exact commands"
pass "startup summary is concise and actionable"
