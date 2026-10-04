#!/bin/bash
# Live drive of wait-no-turns scenarios against a real, isolated tmux server.
R=/Users/tomas/.no-mistakes/worktrees/a6ca20682364/01M4383SEZAT0XR7NJ610TS8WM
S=/Users/tomas/.no-mistakes/worktrees/a6ca20682364/01M4383SEZAT0XR7NJ610TS8WM/.live-tmp
L=$S/live; rm -rf "$L"; mkdir -p "$L/tmux"
unset TMUX FM_TASK_ID FM_TASK_INBOX NO_MISTAKES_GATE
export TMUX_TMPDIR=$L/tmux
trap "" EXIT
say() { printf '%s\n' "$*"; }
pane() { tmux capture-pane -p -t "$1" | grep -c 'Firstmate instruction waiting'; }
tmux new-session -d -s fmlive -n fm-t1 cat
tmux new-window -d -t fmlive -n fm-hibit cat
tmux new-window -d -t fmlive -n fm-t2 cat
say "tmux server: $(tmux -V); windows: $(tmux list-windows -t fmlive -F '#W' | tr '\n' ' ')"
lib() { local st=$1; shift; FM_STATE_OVERRIDE="$st" bash -c '. "$1"; fn=$2; shift 2; "$fn" "$@"' _ "$R/bin/fm-task-inbox-lib.sh" "$@"; }
check() { FM_HOME="$1" FM_STATE_OVERRIDE="$1/state" FM_CONFIG_OVERRIDE="$1/config" FM_TASK_INBOX_GRACE_SECS=1 \
  bash -c '. "$1" && inbox_steer_check "$2" "$3"' _ "$R/bin/fm-watch.sh" "$2" "$3" >/dev/null 2>&1; }

say "== A1 fire-and-forget retry ring, flag present, worker has open decision then resolves"
H=$L/a1; mkdir -p "$H/state" "$H/config"; : > "$H/config/wait-no-turns"
printf 'window=fmlive:fm-t1\nkind=ship\nharness=claude\n' > "$H/state/t1.meta"
fire=$(FM_CONFIG_OVERRIDE=$H/config lib "$H/state" fm_task_inbox_write "$H/state" t1 "one-shot steer" fire-and-forget)
touch -t 202001010000 "$fire"
FM_CONFIG_OVERRIDE=$H/config lib "$H/state" fm_task_inbox_mark_retry "$H/state" t1 "$fire"
touch -t 202001010000 "$H/state/t1.inbox/.retry-ring"
say "due action: $(FM_CONFIG_OVERRIDE=$H/config FM_TASK_INBOX_GRACE_SECS=1 lib "$H/state" fm_task_inbox_due_action "$H/state" t1)"
printf 'needs-decision [key=pick]: alpha or beta?\n' > "$H/state/t1.status"
check "$H" fmlive:fm-t1 t1; check "$H" fmlive:fm-t1 t1
say "open decision: doorbells in pane=$(pane fmlive:fm-t1) retry mark present=$([ -e "$H/state/t1.inbox/.retry-ring" ] && echo yes || echo no)"
printf 'resolved [key=pick]: alpha\n' >> "$H/state/t1.status"
check "$H" fmlive:fm-t1 t1; check "$H" fmlive:fm-t1 t1; check "$H" fmlive:fm-t1 t1
say "after resolve, 3 checks: doorbells in pane=$(pane fmlive:fm-t1) retry mark present=$([ -e "$H/state/t1.inbox/.retry-ring" ] && echo yes || echo no) record kept=$([ -f "$fire" ] && echo yes || echo no) wake queue=$([ -s "$H/state/.wake-queue" ] && echo non-empty || echo empty)"
say "pane text:"; tmux capture-pane -p -t fmlive:fm-t1 | grep -v '^$'

say "== A2 same retry mark, flag absent"
H=$L/a2; mkdir -p "$H/state" "$H/config"
printf 'window=fmlive:fm-t2\nkind=ship\nharness=claude\n' > "$H/state/t2.meta"
fire=$(FM_CONFIG_OVERRIDE=$H/config lib "$H/state" fm_task_inbox_write "$H/state" t2 "one-shot steer" fire-and-forget)
touch -t 202001010000 "$fire"
FM_CONFIG_OVERRIDE=$H/config lib "$H/state" fm_task_inbox_mark_retry "$H/state" t2 "$fire"
touch -t 202001010000 "$H/state/t2.inbox/.retry-ring"
say "due action: $(FM_CONFIG_OVERRIDE=$H/config FM_TASK_INBOX_GRACE_SECS=1 lib "$H/state" fm_task_inbox_due_action "$H/state" t2)"
check "$H" fmlive:fm-t2 t2; check "$H" fmlive:fm-t2 t2
say "flag absent, 2 checks: doorbells in pane=$(pane fmlive:fm-t2)"

say "== A3 real fm-send --fire-and-forget to a secondmate pane, flag present"
H=$L/a3; mkdir -p "$H/state" "$H/config" "$H/mate"; : > "$H/config/wait-no-turns"
printf 'window=fmlive:fm-hibit\nendpoint_task_id=domain\nworktree=%s\nproject=%s\nharness=claude\nkind=secondmate\nmode=secondmate\nyolo=off\nhome=%s\nprojects=alpha\n' "$H/mate" "$H/mate" "$H/mate" > "$H/state/domain.meta"
FM_HOME=$H "$R/bin/fm-send.sh" fm-domain --fire-and-forget 0123456789abcdef "reconcile your books" > "$L/a3.out" 2>&1; rc=$?
say "fm-send rc=$rc; retry mark=$(cat "$H/state/domain.inbox/.retry-ring" 2>/dev/null || echo none); doorbells in pane=$(pane fmlive:fm-hibit)"
say "fm-send stderr tail:"; grep -v '^$' "$L/a3.out" | tail -4
tmux send-keys -t fmlive:fm-hibit C-c; tmux kill-window -t fmlive:fm-hibit; tmux new-window -d -t fmlive -n fm-hibit cat

say "== B pending-reply recovery, flag present, mate has open decision then resolves (real fm-send, no hook)"
H=$L/b; mkdir -p "$H/state" "$H/config" "$H/mate"; : > "$H/config/wait-no-turns"
printf 'window=fmlive:fm-hibit\nendpoint_task_id=hibit\nworktree=%s\nproject=%s\nharness=claude\nkind=secondmate\nmode=secondmate\nyolo=off\nhome=%s\nprojects=alpha\n' "$H/mate" "$H/mate" "$H/mate" > "$H/state/hibit.meta"
FM_HOME=$H FM_CONFIG_OVERRIDE=$H/config FM_PENDING_REPLY_GRACE_SECS=0 FM_PENDING_REPLY_NOW=2500 bash -c '
  . "$1/bin/fm-classify-lib.sh"; . "$1/bin/fm-pending-reply-lib.sh"
  H=$2; st=$H/state
  corr=$(fm_pending_reply_create "$H" "$st" hibit "status of phase 8")
  fm_pending_reply_mark_delivered "$st" "$corr"
  fm_pending_reply_observe_busy "$st" "$corr" busy
  fm_pending_reply_observe_busy "$st" "$corr" idle
  printf "needs-decision [key=scope]: narrow or wide?\n" >> "$st/hibit.status"
  if fm_pending_reply_send_recovery "$st" "$corr" 2>/dev/null; then echo "open decision: recovery SENT"; else echo "open decision: recovery held (rc=1)"; fi
  echo "phase=$(fm_pending_reply_get "$(fm_pending_reply_path "$st" "$corr")" phase) inbox records=$(ls "$st/hibit.inbox" 2>/dev/null | grep -c msg)"
  printf "resolved [key=scope]: answered: narrow\n" >> "$st/hibit.status"
  if fm_pending_reply_send_recovery "$st" "$corr"; then echo "after resolve: recovery sent"; else echo "after resolve: recovery NOT sent"; fi
  echo "inbox records=$(ls "$st/hibit.inbox" 2>/dev/null | grep -c msg)"
' _ "$R" "$H" 2>&1 | grep -v "^●"
say "doorbells in mate pane=$(pane fmlive:fm-hibit)"
