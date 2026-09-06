#!/usr/bin/env bash
# tests/fm-control-herdr-smoke.test.sh - real-herdr smoke test for the agent
# lifecycle control plane (bin/fm-control.sh).
#
# tmux is the control plane's reference backend and is covered hermetically in
# tests/fm-control.test.sh. herdr is the OTHER backend whose recovery-grade
# agent-state classifier the control plane is allowed to trust, so its
# behavior is pinned here against the REAL binary rather than a stub: whether
# an agent is running, and therefore whether a lifecycle verb may act at all,
# comes from herdr's own agent registry.
#
# No real agent is launched. herdr's `pane report-agent` is the same registry
# the adapter reads, so registering and not registering an agent exercises
# exactly the classification the control plane gates on. The registry alone is
# not enough, though: since the 2026-09-06 Pi defect the classifier also reads
# the pane's own foreground process group, because a herdr agent record can
# outlive its agent process. The registered-agent cases therefore run over a
# real foreground process, and the last case returns that pane to its bare
# shell with the record still registered - the exact shape a Pi or Claude
# worker leaves when its session ends - and proves the control plane now reads
# it as agent-gone instead of typing an exit command into a shell.
#
# Always runs on a private, named, throwaway lab session, never the default
# one (tests/herdr-test-safety.sh; the 2026-07-02 incident). Skips cleanly
# when herdr or jq is missing.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

SESSION="fm-lab-control-smoke-$$"
export HERDR_SESSION="$SESSION"
SCRATCH=
cleanup_all() {
  [ -n "$SCRATCH" ] && rm -rf "$SCRATCH"
  herdr_safe_stop_and_delete "$SESSION"
}
trap cleanup_all EXIT
fm_herdr_lab_prepare "$SESSION" || fail "could not prepare isolated Herdr lab session"

SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-control-herdr.XXXXXX")
SCRATCH=$(cd "$SCRATCH" && pwd)
HOME_DIR="$SCRATCH/home"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data/hsmoke"
printf '# brief\n' > "$HOME_DIR/data/hsmoke/brief.md"

# A real git worktree so the control plane's checkpoint has a real local copy.
PROJ="$SCRATCH/proj"
WT="$SCRATCH/wt"
mkdir -p "$PROJ"
git -C "$PROJ" init -q
printf '# proj\n' > "$PROJ/README.md"
git -C "$PROJ" add README.md
git -C "$PROJ" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
git -C "$PROJ" worktree add --quiet -b hsmoke "$WT"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr || fail "fm_backend_source herdr failed"

CONTAINER_RAW=$(fm_backend_herdr_container_ensure "$WT") || fail "container_ensure failed"
CONTAINER=${CONTAINER_RAW%%$'\t'*}
SEEDED_TAB_ID=${CONTAINER_RAW#*$'\t'}
WORKSPACE_ID=${CONTAINER#*:}
TASK_IDS=$(fm_backend_herdr_create_task "$CONTAINER" "fm-hsmoke" "$WT" "$SEEDED_TAB_ID") \
  || fail "create_task failed"
read -r TAB_ID PANE_ID <<EOF
$TASK_IDS
EOF
[ -n "$TAB_ID" ] && [ -n "$PANE_ID" ] || fail "create_task did not return tab/pane ids"

{
  echo "window=$SESSION:$PANE_ID"
  echo "endpoint_task_id=hsmoke"
  echo "worktree=$WT"
  echo "project=$PROJ"
  echo "harness=claude"
  echo "kind=ship"
  echo "mode=no-mistakes"
  echo "yolo=off"
  echo "model=default"
  echo "effort=default"
  echo "backend=herdr"
  echo "herdr_session=$SESSION"
  echo "herdr_workspace_id=$WORKSPACE_ID"
  echo "herdr_tab_id=$TAB_ID"
  echo "herdr_pane_id=$PANE_ID"
} > "$HOME_DIR/state/hsmoke.meta"

run_control() {
  env FM_HOME="$HOME_DIR" HERDR_SESSION="$SESSION" \
    FM_CONTROL_POLL=0.2 FM_CONTROL_EXIT_WAIT=2 \
    "$ROOT/bin/fm-control.sh" "$@" 2>&1
}

# --- no registered agent: the endpoint exists but hosts no agent ------------

OUT=$(run_control hsmoke exit) || fail "exit against an agent-free herdr pane should be idempotent success: $OUT"
case "$OUT" in
  "already-stopped hsmoke"*) : ;;
  *) fail "an agent-free herdr pane should report already-stopped, got: $OUT" ;;
esac
pass "real herdr: exit on a pane with no registered agent is idempotent success"

if OUT=$(run_control hsmoke interrupt 2>&1); then
  fail "interrupt should refuse when herdr reports no agent on the pane: $OUT"
fi
case "$OUT" in
  *"nothing to interrupt"*) : ;;
  *) fail "the interrupt refusal should say there is no agent, got: $OUT" ;;
esac
pass "real herdr: interrupt refuses when herdr's own agent registry reports no agent"

# --- a registered agent over a running process: classification flips --------
# The foreground process stands in for the agent's own process. It is what
# makes the registry record believable: a record over a bare shell prompt is a
# record whose agent has already exited.

pane_runs_sleep() {
  fm_backend_herdr_cli "$SESSION" pane process-info --pane "$PANE_ID" 2>/dev/null \
    | jq -e '[.result.process_info.foreground_processes[]?.name] | any(. == "sleep")' >/dev/null 2>&1
}

fm_backend_herdr_send_text_line "$SESSION:$PANE_ID" 'sleep 600' \
  || fail "could not start a foreground process in the task pane"
i=0
while [ "$i" -lt 100 ]; do
  pane_runs_sleep && break
  sleep 0.2
  i=$((i + 1))
done
pane_runs_sleep \
  || fail "the task pane never started its foreground process, so the registered-agent cases would prove nothing"
if fm_backend_herdr_pane_foreground_shell_pid "$SESSION" "$PANE_ID" >/dev/null 2>&1; then
  fail "a pane running a foreground process must not read as shell-only, or this case proves nothing"
fi

herdr pane report-agent "$PANE_ID" --source fm-control-smoke --agent fm-control-smoke-agent \
  --state idle --session "$SESSION" >/dev/null 2>&1 \
  || fail "could not register a live agent on the task pane"

STATE=$(fm_backend_agent_state herdr "$SESSION:$PANE_ID")
[ "$STATE" = alive ] || fail "herdr should classify a registered agent over a running process as alive, got '$STATE'"

OUT=$(run_control hsmoke interrupt) || fail "interrupt against a registered agent should succeed: $OUT"
case "$OUT" in
  *"interrupt-delivered hsmoke harness=claude backend=herdr verified=agent-alive cancel=unconfirmed"*) : ;;
  *) fail "interrupt should report the agent-alive proof on herdr, got: $OUT" ;;
esac
pass "real herdr: interrupt delivers the harness's key and proves the agent survived it"

herdr pane get "$PANE_ID" --session "$SESSION" >/dev/null 2>&1 \
  || fail "the control plane must never remove the endpoint it was operating on"
[ -d "$WT" ] || fail "the control plane must never remove the task's local copy"
pass "real herdr: no control verb removed the endpoint or the task's local copy"

# Deliberately types a harness command into a pane that is running an ordinary
# process: the registered agent cannot actually be stopped that way, and the
# control plane must say so rather than report a stop it did not achieve.
if OUT=$(run_control hsmoke exit 2>&1); then
  fail "exit should fail closed when the agent does not stop: $OUT"
fi
case "$OUT" in
  *"did not stop"*) : ;;
  *) fail "the exit failure should say the agent did not stop, got: $OUT" ;;
esac
pass "real herdr: an agent that does not stop fails closed instead of being reported as stopped"

# --- the registry record outlives its process ------------------------------
# The pane returns to its own bare shell while the agent record stays
# registered - what a Pi or Claude worker leaves behind when its session ends.
# Before the 2026-09-06 fix this still read alive, so exit typed its command
# into the shell and relaunch refused the endpoint; now it is agent-gone and
# exit is idempotent success, which is what lets relaunch adopt the pane.

fm_backend_herdr_send_key "$SESSION:$PANE_ID" C-c \
  || fail "could not stop the pane's foreground process"
i=0
while [ "$i" -lt 100 ]; do
  fm_backend_herdr_pane_foreground_shell_pid "$SESSION" "$PANE_ID" >/dev/null 2>&1 && break
  sleep 0.2
  i=$((i + 1))
done
fm_backend_herdr_pane_foreground_shell_pid "$SESSION" "$PANE_ID" >/dev/null 2>&1 \
  || fail "the pane never returned to its bare shell, so this case would prove nothing"
IDENTITY=$(fm_backend_herdr_agent_identity_raw "$SESSION" "$PANE_ID") \
  || fail "the agent record could not be read back, so this case would prove nothing"
case "$IDENTITY" in
  *idle*|*working*|*blocked*|*done*) : ;;
  *) fail "the agent record disappeared on its own ('$IDENTITY'), so this case would prove nothing" ;;
esac

STATE=$(fm_backend_agent_state herdr "$SESSION:$PANE_ID")
[ "$STATE" = dead ] \
  || fail "a registered agent record over a bare shell must classify agent-free, got '$STATE'"
pass "real herdr: an agent record left over a bare shell classifies agent-free, not alive"

OUT=$(run_control hsmoke exit) \
  || fail "exit over a shell-only pane should be idempotent success: $OUT"
case "$OUT" in
  "already-stopped hsmoke"*) : ;;
  *) fail "exit over a shell-only pane should report already-stopped, got: $OUT" ;;
esac
pass "real herdr: exit over a pane whose agent has exited to a shell is idempotent success"

fm_backend_herdr_kill "$SESSION:$PANE_ID" 2>/dev/null || true
