# Fleet activity ledger

The fleet activity ledger is an opt-in, append-only file that outside tools can read to follow what a firstmate home is doing: which tasks were dispatched, what their workers reported, when a PR became ready for review, when their work merged, landed, and went live, when they were cleaned up, what the captain said and was asked, and what reviews and checks found.
It is the stable, documented hook for firstmate status; this page is its contract.

## Turning it on and off

Create the presence flag `config/fleet-ledger` in a firstmate home to turn the ledger on, and delete it to turn the ledger off.
From the home's root, `touch config/fleet-ledger` turns it on and `rm config/fleet-ledger` turns it off; neither needs a restart, because every producer tests the flag on each write.
The flag is local, gitignored, per home, and not inherited by second mate homes, so each home that should publish a ledger needs its own flag.
While the flag is absent, each producer performs one file-existence test and nothing else: no process starts and nothing is written.

## The file

The ledger is `state/fleet-ledger.jsonl` in that home, in JSON Lines format: one JSON object per line, each ending in a newline.
Records are only ever appended, in the order they are written.

Every record is also appended to `data/fleet-ledger.jsonl`, the durable copy.
`state/` holds runtime records and may be cleared, while `data/` holds the home's durable records, so the durable copy keeps the whole history across a cleared `state/` or a truncated live file.
The live file stays where outside tools already follow it; read the durable copy for history from before the live file was last cleared.

Every record carries these members:

| Member  | Meaning                                                   |
| ------- | --------------------------------------------------------- |
| `v`     | Record format version, currently `1`                      |
| `ts`    | Unix time in seconds when the record was written          |
| `event` | One of the event names below                              |
| `task`  | The firstmate task id the record is about, which is also its work item id; `null` for `captain.said` |

Readers must ignore members and events they do not recognize, so later versions can add them without breaking existing readers.

## Events

| Event              | Extra members                                  | Written when |
| ------------------ | ---------------------------------------------- | ------------ |
| `task.dispatched`  | `kind`, `project`, `harness`, `model`          | A new worker or second mate is launched. A relaunch of an existing task is not recorded. |
| `task.status`      | `state`, `key`, `text`                         | A complete, nonblank line in the task's status log is captured. |
| `task.pr_ready`    | `pr`                                           | Firstmate records the task's PR as ready for review. |
| `task.merged`      | `via` (`"pr"` or `"local"`), plus `pr` when `via` is `"pr"` | The task's PR merge is recorded, or its local-only branch landed. |
| `task.cleaned_up`  | none                                           | The task's worker and local copy were removed. |
| `captain.said`     | `id`, `source`, `text`                         | The captain's words are captured. |
| `item.linked`      | `link`, `ref`                                  | A work item is linked to the captain's words or to the outcome it serves. |
| `hold.opened`      | `reason`, `until`                              | A work item is held for the captain. |
| `hold.answered`    | `mode`, `decision`                             | The captain's answer to a held item is recorded. |
| `item.landed`      | `via` (`"pr"` or `"local"`), plus `pr` when `via` is `"pr"` | The item's work reached its base branch. |
| `item.live`        | `evidence`                                     | Firstmate confirmed the item's work is running where users get it, after a rebuild or deploy. |
| `check.passed`, `check.failed` | `check`, `evidence`                | A reviewer ran one finish check for the item's project. |
| `review.verdict`   | `subject`, `verdict`, `evidence`               | A reviewer gave a verdict on an outcome, a PR, or another reviewed subject. |

`task.dispatched` members: `kind` is `ship`, `scout`, or `secondmate`; `project` is the project directory name, or `null` for a remote second mate; `harness` names the agent tool; `model` is the requested model, or `null` for the tool's default.

`task.pr_ready` members: `pr` is the PR's full URL.
It is written each time firstmate records a PR for the task, so registering a replacement PR, or the same PR again, writes another record; recording the PR again as part of merging it writes none.

`captain.said` members: `id` is the word id `w-<YYYYMMDD>-<HHMM>-<n>`, from the UTC minute it was captured and a counter that starts at 1 in each minute, and links later records to these words; `source` names where the words came from, such as `chat`, or is `null`; `text` is the captain's words verbatim without trailing newlines, capped at 20000 characters.
Its `task` is `null`, because captain words come before any work item.

`item.linked` members: `link` is `words` or `outcome`; `ref` is the `captain.said` word id, or the outcome's id as its charter names it.

`hold.opened` members: `reason` is the hold reason; `until` is the captain's `YYYY-MM-DD` deferral date, or `null`.
It is written each time a hold is recorded, so holding an item again writes another record.

`hold.answered` members: `mode` is `answered` (the call is closed), `released` (held work resumes), or `repaired` (an answer recorded on an item closed elsewhere); `decision` is the captain's recorded words verbatim without trailing newlines.
An exact replay of an answer already closed writes nothing.

`item.landed` is written beside `task.merged` for the same merge, so a reader that follows items rather than workers needs only the `item.*` events.

`item.live` members: `evidence` is what proves the work is live, such as a deploy URL or a build id, capped at 2000 characters.

`check.passed` and `check.failed` members: `check` is the id of the finish check that ran; `evidence` is what the reviewer saw, capped at 2000 characters.

`review.verdict` members: `subject` names what was reviewed; `verdict` is the reviewer's verdict, such as `met`, `met with open items`, or `not met` for an outcome; `evidence` is capped at 2000 characters.

`task.status` members: `state` is the status line's leading word, such as `working`, `needs-decision`, `blocked`, `paused`, `done`, `failed`, or `resolved`, or `null` when the line has none.
`key` is the line's `[key=...]` decision key, or `null`.
`text` is the status line after its first colon, verbatim, capped at 2000 characters; if the line has no colon, it is the whole line.

Example:

```json
{"v":1,"ts":1790132857,"event":"task.dispatched","task":"fix-login","kind":"ship","project":"webapp","harness":"claude","model":null}
{"v":1,"ts":1790132870,"event":"task.status","task":"fix-login","state":"working","key":null,"text":" bug reproduced"}
{"v":1,"ts":1790133400,"event":"task.status","task":"fix-login","state":"done","key":null,"text":" PR https://github.com/acme/webapp/pull/7 checks green"}
{"v":1,"ts":1790133410,"event":"task.pr_ready","task":"fix-login","pr":"https://github.com/acme/webapp/pull/7"}
{"v":1,"ts":1790133900,"event":"task.merged","task":"fix-login","via":"pr","pr":"https://github.com/acme/webapp/pull/7"}
{"v":1,"ts":1790133900,"event":"item.landed","task":"fix-login","via":"pr","pr":"https://github.com/acme/webapp/pull/7"}
{"v":1,"ts":1790133960,"event":"task.cleaned_up","task":"fix-login"}
{"v":1,"ts":1790134500,"event":"item.live","task":"fix-login","evidence":"deployed webapp build 412"}
```

## Limits

- A worker using the current status command in its instructions records its line immediately after appending it, while the ledger is enabled.
  The supervision monitor's regular poll is the backstop: it records any line the immediate write missed, and does not record again a line that write already recorded.
  These lines still trail the status log by up to one poll interval, or until the monitor next runs when none is running:
  - lines firstmate itself writes to a task's status log, such as a recorded answer, a failed launch, a relayed pending reply, or a second mate's report line;
  - lines from workers whose instructions predate this, or that append without running the instruction's full command;
  - lines a remote second mate reports, which reach this home through firstmate's relay;
  - lines written while the immediate record fails, for example when the ledger file cannot be written.
  Recording any event about a task first records that task's pending status lines.
- Captured status lines are delivered at least once unless a write fails or a crash loses unflushed records: an interrupted capture can repeat records, so a reader that must not double-count should tolerate duplicates.
- A status record can appear just before its task's `task.dispatched` record when the worker writes a status line in the moment between its launch and that record.
- When a home turns the ledger on, status lines already in a live task's log are recorded on that task's next capture (which may be a worker status command, PR registration, merge, cleanup, or monitor poll); tasks dispatched or cleaned up while the flag was absent have no record of that.
- There is no sequence number and no gap detection.
- Writes are plain appends with no forced flush to disk, so a machine crash can lose the newest records.
- An answer interrupted after it closed its item and before its record was written is not recorded, because its replay writes nothing.
- `captain.said`, `item.linked`, `check.passed`, `check.failed`, and `review.verdict` have writers but no producer yet, so a home records them only when something calls their writer.
- Neither file is rotated.
  To truncate the live file, stop reading, then empty it with `: > state/fleet-ledger.jsonl`; later records append to the empty file.
  The durable copy is never truncated, so it keeps every record.
- The ledger copies status text, captain words, and recorded answers verbatim and adds no scrubbing, so give its readers exactly the trust you give the home's `state/` and `data/`.

## Not included

These are possible follow-ups, deliberately left out of this version:

- session start, away-mode, and quiet-mode events;
- relaunch events;
- whether a worker is currently working or idle, and when a turn ends; subscribe to the Herdr runtime's own `pane.agent_status_changed` events for that ([Push events and polling fallback](herdr-backend.md#push-events-and-polling-fallback));
- sequence numbers and gap detection;
- rotation and continuity across rotated files;
- backfill or replay of events from before the ledger was turned on;
- secret scrubbing beyond what status lines and captain words already contain, and privacy guarantees stronger than those of `state/` and `data/`.

`bin/fm-fleet-ledger.sh`'s header owns the writer mechanics and lists every producer.
