# fm-remote-reply evidence and live wait-no-turns scenarios

Run: no-mistakes 01M40WPMJ8GTZ936VJ9ARTYF5Q, head 3143ba7a (branch fm/firstmate-upstream-wait-no-turns), base main 3e130339.

## test-1: tests/fm-remote-reply.test.sh run alone, 3x main and 3x head

Command per run: `env -u FM_TASK_ID -u FM_TASK_INBOX -u NO_MISTAKES_GATE bash tests/fm-remote-reply.test.sh`, sequential, nothing else of mine running (a leftover pipeline evidence loop was waited out first).
Main was a git-initialised copy of `git archive main`; head was this worktree.

- main run 1 exit=0 secs=231 result=ALL TESTS PASSED
- head run 1 exit=0 secs=291 result=ALL TESTS PASSED
- main run 2 exit=0 secs=246 result=ALL TESTS PASSED
- head run 2 exit=0 secs=206 result=ALL TESTS PASSED
- main run 3 exit=0 secs=174 result=ALL TESTS PASSED
- head run 3 exit=0 secs=181 result=ALL TESTS PASSED

Result: 6 of 6 pass. No regression and no flakiness when run alone.
Full logs: live-transcripts/rr-main-{1,2,3}.log and rr-head-{1,2,3}.log.

Earlier local failures were not alone: they ran with this worker's FM_TASK_ID and FM_TASK_INBOX set and, in the pipeline's case, beside another copy of the same test.
The pipeline's own leftover runs (in ~/.no-mistakes/evidence/01M40WPMJ8GTZ936VJ9ARTYF5Q/) agree: head 3 of 3 pass, base clone 3 of 3 pass; its "archive copy" base runs failed only because that copy was not a git repository.

## test-2 / test-3: live scenarios with a temporary flag file (never the real home)

Driver: live-transcripts/live.sh; output: live-transcripts/live.out.
Each scenario uses a throwaway FM_HOME under the session scratchpad with its own config/wait-no-turns, and calls the production scripts and libraries (bin/fm-send.sh, bin/fm-watch.sh inbox_steer_check, bin/fm-pending-reply-lib.sh) with no test stubs or send hooks.
This machine has no tmux, and the fleet's herdr backend is outside this task's lifecycle authority, so no real pane receives a doorbell; every doorbell therefore genuinely does not land, which is exactly the state these scenarios need.

1. Fire-and-forget steer whose doorbell did not land gets exactly one retry ring, only while the flag exists.
   - A3: real `fm-send.sh fm-domain --fire-and-forget ...` with the flag: rc=0, record durable, `.retry-ring` = 001.msg, notice "the watcher will ring it once more".
   - A1: with the flag and the mark aged, due action is `retry`; two watcher checks while `needs-decision [key=pick]` is open ring nothing and keep the mark; after `resolved [key=pick]`, three checks produce exactly one retry ring (watch triage log: "steer-inbox retry ring: t1 001.msg result=2"), the mark is spent, the record is kept, and no wake is queued.
   - A2: same mark without the flag: due action `quiet`, two checks, no ring attempted.
2. Pending-reply recovery waits while the mate has its own open decision (B): with the flag and an open `needs-decision [key=scope]`, fm_pending_reply_send_recovery returns 1, phase stays awaiting_report, and the mate inbox gets no record; after `resolved [key=scope]`, the recovery sends through the real fm-send and the mate inbox gets exactly one record.
3. Remote reply path still works after the sync: no remote host is available here, so the evidence is the six alone runs of tests/fm-remote-reply.test.sh above (all pass on head and main).
4. Turning the flag on in the real firstmate home is out of scope by design: config/ is gitignored and home-local, and firstmate creates config/wait-no-turns in the real home after this PR merges.
