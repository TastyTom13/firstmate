#!/usr/bin/env bash
# fm-bearings-board.sh - build and arm the /bearings lavish fleet board.
#
# The board is the captain-facing interactive surface of /bearings lavish: the
# shipped template (.agents/skills/bearings/assets/board-template.html) plus one
# injected fm-bearings-board.v1 JSON payload. This script owns the mechanics so
# the invoking agent's per-run work stays "compose the JSON, run build" - the
# agent never authors board UI at invocation time.
#
# Usage:
#   fm-bearings-board.sh build <data.json>
#   fm-bearings-board.sh path
#
# build      Validate the payload and inject it into a fresh copy of the shipped
#            template at the stable board path. Establish or resume the Lavish
#            session on that board BEFORE binding and arming its answer source,
#            so a registered poll can never race a session that does not exist.
#            Bind to the keyed-answer intake (bin/fm-captain-hold.sh) ALWAYS
#            precedes arm, so the board can never produce an answer that has
#            nowhere to go (captain-hold-lifecycle's ordering rule, enforced
#            here rather than left to agent memory). Output starts with
#            `board: <path>`, then includes lavish-axi's session output and
#            the remaining status:
#              served: <path>
#              bound: <source-id>
#              armed: <source-id>            (first registration)
#              already-armed: <source-id>    (registration already present)
# path       Print the stable board path for this home.
#
# Validation is fail-closed: the payload must be valid JSON with
# schema=fm-bearings-board.v1 and every renderer-consumed field must satisfy
# the fm-bearings-board.v1 types and item invariants below.
#
# `pools` is the optional always-visible usage gauge: one entry per provider
# subscription, each carrying `provider`, `label`, `percent_remaining` (a
# number 0-100, or null for a pool that could not be read), `window`,
# `resets_at`, `estimate`, and `note`. bin/fm-quota-pools.sh produces the array
# in exactly this shape. The field is additive, so a payload that omits it
# stays a valid fm-bearings-board.v1 payload and the board simply renders no
# gauge; that is what keeps the schema version unchanged. A pool whose
# `percent_remaining` is null renders as unreadable with its `note`, never as
# an empty or full gauge, and a pool with `estimate` true is labelled on the
# board as an estimate so a measured-spend number is never read as the
# provider's own remaining allowance.
#
# `parked_ideas` is the optional small list of captured-but-not-yet-scoped
# ideas: one entry per queued idea-kind backlog task, each carrying `id`,
# `title`, and `repo` (null when the idea names no project yet). Like `pools`,
# the field is additive - a payload that omits it stays a valid
# fm-bearings-board.v1 payload and the board simply renders no parked-ideas
# list, so the schema version stays unchanged. The board's own idea-capture box
# does not read this list; it only submits a new idea through the existing
# answer channel (`idea.<unique-suffix>` in the fm-bearings-board.v1 answer
# shape below).
#
# `usage` is the optional burn-history panel: the reduction
# bin/fm-usage-history.sh produces from this home's quota samples and the
# no-mistakes pipeline's own record of what each review call spent. It carries
# `generated`, `samples`, `since`, `curves` (per pool window: `pool`,
# `window`, `label`, `points` of `{ts, percent_remaining}`, and `resets`),
# `daily` (per pool window per day: `burn_points` and `resets`), `review`
# (`available`, `note`, `daily`, `runs`), and `notes`. Like `pools` and
# `parked_ideas` the field is additive, so a payload that omits it stays a
# valid fm-bearings-board.v1 payload and the board simply renders no history
# panel; that is what keeps the schema version unchanged. The board's standing
# explanation of the numbers - which reader each column comes from, what each
# curve decides, and the current review-cost mitigations - is shipped copy in
# the template, never composed per run, so a live board can never state a
# mitigation the fleet no longer applies.
#
# `idea` is the optional boolean marker an Underway, Recently Landed, or
# Charted Next item carries once a parked idea has been promoted to real work:
# it means "this row's stored title still carries the literal `Idea: `
# plumbing prefix", so the board strips that prefix when rendering the row.
# The composer sets it from the task's own history and never by inspecting the
# title text, which is what lets an ordinary task the captain deliberately
# titled "Idea: ..." keep the exact title its backlog row has. Like the fields
# above it is additive, and `parked_ideas` entries carry no marker because
# every entry there is an idea by definition.
#
# THE IDEA-ANSWER SHAPE. A captured idea rides the same `window.lavish.
# queuePrompt` "choice" mechanism as every other board answer
# (bin/fm-procevent-lavish.sh's `answers` command), so it needs no schema
# change to travel: its Context data is `{"question": "idea.<unique-suffix>",
# "answer": "<idea text, <=512 bytes>"}`. The key is `idea.` followed by a
# client-minted unique suffix (never a fixed key), because `answers` keeps only
# the LAST submission for a repeated key, and every distinct idea must survive
# even when several are queued in one board session. `bin/fm-bearings-board.sh`
# does not consume idea answers itself; the receiving side is the bearings
# skill's board-wake handling, which files each `idea.*` key as a queued
# backlog task tagged `--kind idea` through the ordinary tasks-axi path.
#
# Every fleet row and Captain's Call item explicitly carries `repo`; the
# composer fills it from the snapshot and task records wherever known, and uses
# null or an empty string only as the deliberate genuinely-no-repo marker. In that exceptional case
# the template may display the routing id. Anything else refuses before the
# existing board is touched.
#
# The board path is stable - $FM_HOME/.lavish/bearings-board.html - so a
# re-invocation rebuilds the same file in place, which keeps the same Lavish
# session URL and the same canonical process-event source id. Injection escapes
# every `<` in the compact JSON as the \u003c string escape, so a payload string
# containing "</script>" can never terminate the data block early.
#
# FM_BEARINGS_BOARD_TEMPLATE overrides the shipped template path (tests only).
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"

TEMPLATE="${FM_BEARINGS_BOARD_TEMPLATE:-$SCRIPT_DIR/../.agents/skills/bearings/assets/board-template.html}"
PLACEHOLDER='__FM_BEARINGS_BOARD_DATA__'
BOARD_SCHEMA=fm-bearings-board.v1

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'fm-bearings-board: %s\n' "$*" >&2
  exit 1
}

board_path() { printf '%s/.lavish/bearings-board.html\n' "$FM_HOME"; }

validate_payload() {  # <data.json>
  jq -e --arg schema "$BOARD_SCHEMA" '
    def nonempty_string: type == "string" and length > 0;
    def slug($max): type == "string" and test("^[A-Za-z0-9._-]{1," + ($max | tostring) + "}$");
    def repo_marker: has("repo") and (.repo == null or (.repo | type == "string"));
    def optional_string($name): (has($name) | not) or (.[$name] | type == "string");
    def optional_bool($name): (has($name) | not) or (.[$name] | type == "boolean");
    def optional_https_url($name):
      (has($name) | not)
      or (.[$name]
        | type == "string"
          and test("^https://[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?(?::[0-9]{1,5})?(?:[/?#][^[:space:]]*)?$"));
    def call_item:
      type == "object"
      and (.key | slug(128))
      and (.type == "decision" or .type == "merge" or .type == "credential")
      and repo_marker
      and (.title | nonempty_string)
      and (.options | type == "array")
      and ((.options | length) > 0 or .allow_freeform == true)
      and ([.options[]
        | type == "object"
          and (.value | slug(128))
          and (.label | nonempty_string)
          and optional_string("hint")] | all)
      and (optional_string("about"))
      and (optional_string("decide"))
      and (optional_string("detail"))
      and (optional_https_url("pr_url"))
      and (optional_string("freeform_hint"))
      and ((has("close") | not) or (.close == "done" or .close == "release"))
      and ((has("allow_freeform") | not) or (.allow_freeform | type == "boolean"))
      and ((has("recommend_value") | not)
        or ((.recommend_value | slug(128))
          and (.recommend_value as $recommend | [.options[].value] | index($recommend) != null)))
      and (if .type == "merge" then (.risk | nonempty_string) else true end);
    def underway_item:
      type == "object" and repo_marker and (.id | nonempty_string)
      and (.state | nonempty_string) and (.doing | nonempty_string) and (.kind | nonempty_string)
      and optional_bool("idea");
    def landed_item:
      type == "object" and repo_marker and (.id | nonempty_string)
      and (.what | nonempty_string) and (.owner | nonempty_string)
      and optional_https_url("pr_url")
      and optional_bool("idea");
    def pool_item:
      type == "object"
      and (.provider | slug(64))
      and (.label | nonempty_string)
      and has("percent_remaining")
      and (.percent_remaining == null
        or ((.percent_remaining | type) == "number"
          and .percent_remaining >= 0 and .percent_remaining <= 100))
      and optional_string("window")
      and ((has("resets_at") | not) or .resets_at == null or (.resets_at | type == "string"))
      and ((has("estimate") | not) or (.estimate | type) == "boolean")
      and ((has("note") | not) or .note == null or (.note | type == "string"));
    def usage_point:
      type == "object" and (.ts | nonempty_string)
      and (.percent_remaining | type) == "number";
    def usage_curve:
      type == "object" and (.pool | slug(64)) and (.window | type == "string")
      and (.label | nonempty_string)
      and (.points | type == "array") and ([.points[] | usage_point] | all)
      and ((has("resets") | not)
        or ((.resets | type) == "array" and ([.resets[] | nonempty_string] | all)));
    def usage_day:
      type == "object" and (.date | nonempty_string) and (.pool | slug(64))
      and (.label | nonempty_string)
      and (.burn_points | type) == "number"
      and (.resets | type) == "number";
    def usage_spend:
      type == "object" and (.model | nonempty_string) and (.pool | slug(64))
      and ([.fresh_input, .output, .cache_read] | map(type == "number") | all);
    def usage_panel:
      type == "object"
      and (.curves | type == "array") and ([.curves[] | usage_curve] | all)
      and (.daily | type == "array") and ([.daily[] | usage_day] | all)
      and (.review | type == "object")
      and ((.review.daily // []) | type == "array")
      and ([(.review.daily // [])[] | usage_spend] | all)
      and ([(.review.runs // [])[] | usage_spend] | all);
    def charted_item:
      type == "object" and repo_marker and (.id | slug(128))
      and (.title | nonempty_string) and (.reason | type == "string")
      and (.dispatchable | type == "boolean")
      and ((has("kind") | not) or (.kind == "queued" or .kind == "warning"))
      and (if .kind == "warning" then .dispatchable == false else true end)
      and optional_bool("idea");
    def idea_item:
      type == "object" and repo_marker and (.id | slug(128))
      and (.title | nonempty_string);
    type == "object"
    and (.schema == $schema)
    and (.home | nonempty_string)
    and (.generated | nonempty_string)
    and (.prs_live | type == "boolean")
    and (.captains_call | type == "array")
    and (.underway | type == "array")
    and (.landed | type == "array")
    and (.charted | type == "array")
    and ((has("charted_more") | not)
      or ((.charted_more | type == "number") and (.charted_more >= 0) and (.charted_more | floor == .)))
    and ((has("charted_warning_more") | not)
      or ((.charted_warning_more | type == "number") and (.charted_warning_more >= 0) and (.charted_warning_more | floor == .)))
    and ((has("pools") | not)
      or ((.pools | type) == "array" and ([.pools[] | pool_item] | all)))
    and ((has("parked_ideas") | not)
      or ((.parked_ideas | type) == "array" and ([.parked_ideas[] | idea_item] | all)))
    and ((has("usage") | not) or (.usage | usage_panel))
    and ([.captains_call[] | call_item] | all)
    and ([.underway[] | underway_item] | all)
    and ([.landed[] | landed_item] | all)
    and ([.charted[] | charted_item] | all)
  ' "$1" >/dev/null
}

command_build() {
  local data=${1-} board json tmp sid extracted
  [ "$#" -eq 1 ] || { usage >&2; exit 2; }
  command -v jq >/dev/null 2>&1 || fail "jq is required"
  [ -f "$data" ] || fail "board data does not exist: $data"
  jq empty "$data" 2>/dev/null || fail "board data is not valid JSON: $data"
  validate_payload "$data" || fail "board data does not satisfy $BOARD_SCHEMA: $data"
  [ -f "$TEMPLATE" ] && [ ! -L "$TEMPLATE" ] || fail "board template is missing: $TEMPLATE"
  [ "$(grep -cxF "$PLACEHOLDER" "$TEMPLATE")" -eq 1 ] \
    || fail "board template does not carry exactly one data slot: $TEMPLATE"

  json=$(jq -c . "$data") || fail "cannot compact the board data"
  # `<` never appears in JSON syntax outside strings, so escaping every
  # occurrence keeps the payload valid JSON while making </script> inert.
  json=${json//</\\u003c}

  board=$(board_path)
  (umask 077; mkdir -p "${board%/*}") || fail "cannot create ${board%/*}"
  tmp=$(umask 077; mktemp "${board%/*}/.board.XXXXXX") || fail "cannot stage the board"
  if ! BOARD_JSON="$json" perl -pe "s/^\\Q$PLACEHOLDER\\E\$/\$ENV{BOARD_JSON}/" "$TEMPLATE" > "$tmp"; then
    rm -f -- "$tmp"
    fail "cannot inject the board data"
  fi
  if grep -qxF "$PLACEHOLDER" "$tmp"; then
    rm -f -- "$tmp"
    fail "the board data slot survived injection"
  fi
  # Round-trip the injected payload back out of the built page, so a board that
  # would fail to parse in the browser fails here instead.
  extracted=$(sed -n '/<script id="bearings-data" type="application\/json">/,/<\/script>/p' "$tmp" \
    | sed '1d;$d')
  if ! printf '%s\n' "$extracted" | jq -e --arg schema "$BOARD_SCHEMA" '.schema == $schema' >/dev/null 2>&1; then
    rm -f -- "$tmp"
    fail "the built board does not carry a readable $BOARD_SCHEMA payload"
  fi
  if ! { chmod 0600 "$tmp" && mv -f -- "$tmp" "$board"; }; then
    rm -f -- "$tmp"
    fail "cannot publish the board"
  fi
  printf 'board: %s\n' "$board"

  command -v lavish-axi >/dev/null 2>&1 || fail "lavish-axi is not installed"
  lavish-axi "$board" || fail "cannot establish the board Lavish session"
  printf 'served: %s\n' "$board"

  sid=$("$SCRIPT_DIR/fm-procevent-lavish.sh" source-id "$board") \
    || fail "cannot derive the board source id"
  "$SCRIPT_DIR/fm-captain-hold.sh" bind "$sid" >/dev/null \
    || fail "cannot bind the board source to the keyed-answer intake"
  printf 'bound: %s\n' "$sid"

  if "$SCRIPT_DIR/fm-procevent.sh" list | awk 'NR > 1 { print $1 }' | grep -Fxq "$sid"; then
    printf 'already-armed: %s\n' "$sid"
  else
    "$SCRIPT_DIR/fm-procevent-lavish.sh" arm "$board" >/dev/null \
      || fail "cannot arm the board as a process-event source"
    printf 'armed: %s\n' "$sid"
  fi
}

case "${1-}" in
  build) shift; command_build "$@" ;;
  path) board_path ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
