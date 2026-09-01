#!/usr/bin/env bash
# Behavior tests for the shipped bearings board renderer
# (.agents/skills/bearings/assets/board-template.html), exercised through a real
# `fm-bearings-board.sh build` and then executed under the minimal DOM shim in
# tests/assets/board-render-harness.mjs. The assertions are on what the page
# renders - row badges, the stat strip, the empty state - never on the
# template's source text.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BOARD="$ROOT/bin/fm-bearings-board.sh"
HARNESS="$ROOT/tests/assets/board-render-harness.mjs"
TMP_ROOT=$(fm_test_tmproot fm-bearings-board-render)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v node >/dev/null 2>&1 || { echo "skip: node not found"; exit 0; }

make_home() {  # <name>
  local home="$TMP_ROOT/$1" fakebin
  mkdir -p "$home/state" "$home/data"
  fakebin=$(fm_fakebin "$home")
  fm_fake_exit0 "$fakebin" lavish-axi
  printf '%s\n' "$home"
}

# Build the board from <charted-json> and return what the renderer produced.
render() {  # <home> <charted-json> [charted_more] [charted_warning_more]
  local home=$1 charted=$2 more=${3:-0} warning_more=${4:-0} data="$1/payload.json"
  jq -n --argjson charted "$charted" --argjson more "$more" --argjson warning_more "$warning_more" '{
    schema:"fm-bearings-board.v1", home:"render-home", generated:"2026-08-26T00:00Z",
    prs_live:false, captains_call:[], underway:[], landed:[],
    charted:$charted, charted_more:$more, charted_warning_more:$warning_more}' > "$data"
  PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    "$BOARD" build "$data" >/dev/null || fail "the board did not build"
  node "$HARNESS" "$home/.lavish/bearings-board.html" \
    || fail "the built board could not be rendered"
}

# Build a board carrying <pools-json> and return what the renderer produced.
render_pools() {  # <home> <pools-json|->
  local home=$1 pools=$2 data="$1/pools-payload.json"
  if [ "$pools" = "-" ]; then
    jq -n '{schema:"fm-bearings-board.v1", home:"render-home", generated:"2026-08-31T00:00Z",
      prs_live:false, captains_call:[], underway:[], landed:[], charted:[]}' > "$data"
  else
    jq -n --argjson pools "$pools" '{schema:"fm-bearings-board.v1", home:"render-home",
      generated:"2026-08-31T00:00Z", prs_live:false, captains_call:[], underway:[],
      landed:[], charted:[], pools:$pools}' > "$data"
  fi
  PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    "$BOARD" build "$data" >/dev/null || fail "the board did not build"
  node "$HARNESS" "$home/.lavish/bearings-board.html" \
    || fail "the built board could not be rendered"
}

charted_next_count() {  # <render-json>
  printf '%s' "$1" | jq -r '.stats[] | select(.label == "charted next") | .n'
}

test_a_warning_row_reads_as_a_repair_not_as_queued_work() {
  local home out
  home=$(make_home warning-badge)
  out=$(render "$home" '[
    {"id":"real-queued","repo":"sample","title":"Queued work","reason":"queued behind the cutover","dispatchable":true},
    {"id":"main-inventory","repo":"sample","title":"Main inventory integrity","reason":"main inventory","dispatchable":false,"kind":"warning"}
  ]')
  printf '%s' "$out" | jq -e '.error == ""' >/dev/null \
    || fail "the board rendered its fail-closed error instead of the fleet: $out"
  printf '%s' "$out" | jq -e '
    (.charted | length) == 2
      and (.charted[0] | .title == "Queued work"
        and [.badges[] | .text] == ["waiting"] and .pickable == true)
      and (.charted[1] | .title == "Main inventory integrity"
        and [.badges[] | .text] == ["needs repair"]
        and [.badges[] | .tone] == ["danger"]
        and .pickable == false)
  ' >/dev/null || fail "a warning row did not read differently from queued work: $out"
  pass "a warning row badges needs repair while queued work keeps waiting"
}

test_warnings_are_excluded_from_the_charted_next_count() {
  local home out
  home=$(make_home warning-count)
  out=$(render "$home" '[
    {"id":"queued-one","repo":"sample","title":"One","reason":"gated","dispatchable":true},
    {"id":"warn-one","repo":"sample","title":"Home unreadable","reason":"current home state unavailable","dispatchable":false,"kind":"warning"},
    {"id":"warn-two","repo":"sample","title":"Inventory mismatch","reason":"main inventory","dispatchable":false,"kind":"warning"}
  ]')
  [ "$(charted_next_count "$out")" = 1 ] \
    || fail "the charted next tally counted alarms as queued work: $out"
  printf '%s' "$out" | jq -e '(.charted | length) == 3' >/dev/null \
    || fail "excluding warnings from the count also dropped their rows: $out"
  pass "the charted next count counts queued work only, and still renders warnings"
}

test_a_board_of_only_warnings_still_reports_nothing_queued() {
  local home out
  home=$(make_home warning-only)
  out=$(render "$home" '[
    {"id":"warn-only","repo":"sample","title":"Home unreadable","reason":"current home state unavailable","dispatchable":false,"kind":"warning"}
  ]')
  [ "$(charted_next_count "$out")" = 0 ] \
    || fail "a warning-only board claimed queued work: $out"
  printf '%s' "$out" | jq -e '
    (.empty | length) == 1 and (.empty[0] | test("Nothing is queued"))
      and (.charted | length) == 1
  ' >/dev/null || fail "a warning-only board hid the warning or the empty state: $out"
  pass "a warning-only board reports nothing queued and still shows the warning"
}

test_omitted_warnings_never_count_as_more_queued() {
  local home out
  home=$(make_home warning-more)
  out=$(render "$home" '[
    {"id":"warn-visible","repo":"sample","title":"Home unreadable","reason":"current home state unavailable","dispatchable":false,"kind":"warning"}
  ]' 0 1)
  [ "$(charted_next_count "$out")" = 0 ] \
    || fail "an omitted warning was counted as queued work: $out"
  printf '%s' "$out" | jq -e '
    (.empty | length) == 1 and (.empty[0] | test("Nothing is queued"))
      and (.more == ["+1 more repair warning - ask firstmate for the full chart"])
      and ([.more[] | select(test("more queued"))] | length) == 0
  ' >/dev/null || fail "an omitted warning was labeled as more queued: $out"
  pass "omitted warnings remain separate from omitted queued work"
}

test_an_omitted_kind_keeps_the_existing_queued_rendering() {
  local home out
  home=$(make_home default-kind)
  out=$(render "$home" '[
    {"id":"with-reason","repo":"sample","title":"With reason","reason":"blocked on prep","dispatchable":true},
    {"id":"no-reason","repo":"sample","title":"No reason","reason":"","dispatchable":true}
  ]' 2)
  [ "$(charted_next_count "$out")" = 4 ] \
    || fail "an omitted kind changed the charted next tally: $out"
  printf '%s' "$out" | jq -e '
    ([.charted[0].badges[] | .text] == ["waiting"])
      and (.charted[1].badges == [])
  ' >/dev/null || fail "an omitted kind changed the existing queued badges: $out"
  pass "an omitted kind renders exactly as queued work always did"
}


test_a_readable_pool_shows_how_much_is_left_and_when_it_resets() {
  local home out
  home=$(make_home fuel-readable)
  out=$(render_pools "$home" '[
    {"provider":"claude","label":"Claude","percent_remaining":70,"window":"week",
     "resets_at":"2026-09-07T03:59:59Z","estimate":false,"note":null},
    {"provider":"openai-codex","label":"ChatGPT","percent_remaining":94,"window":"30 day",
     "resets_at":"2026-09-30T21:37:52Z","estimate":false,"note":null}
  ]')
  printf '%s' "$out" | jq -e '.error == ""' >/dev/null \
    || fail "the board rendered its fail-closed error instead of the fleet: $out"
  printf '%s' "$out" | jq -e '
    .fuel.hidden == false and (.fuel.cells | length) == 2
    and (.fuel.cells[0] | .name == "Claude" and .pct == "70% left" and .tone == "ok"
      and (.meta | test("week window")) and (.meta | test("resets 7 Sep")))
    and (.fuel.cells[1] | .name == "ChatGPT" and .pct == "94% left"
      and (.meta | test("30 day window")))
  ' >/dev/null || fail "the gauge did not show both pools: $out"
  pass "a readable pool shows how much is left, its window, and when it resets"
}

test_a_board_without_pools_shows_no_gauge_at_all() {
  local home out
  home=$(make_home fuel-absent)
  out=$(render_pools "$home" -)
  printf '%s' "$out" | jq -e '.error == "" and .fuel.hidden == true and (.fuel.cells | length) == 0' \
    >/dev/null || fail "a board with no pools still rendered a gauge: $out"
  pass "a board built without pools renders no gauge instead of an empty one"
}

test_an_unreadable_pool_says_so_instead_of_showing_a_bar() {
  local home out
  home=$(make_home fuel-unreadable)
  out=$(render_pools "$home" '[
    {"provider":"openai-codex","label":"ChatGPT","percent_remaining":null,"window":"",
     "resets_at":null,"estimate":false,"note":"no credential file at /nowhere"}
  ]')
  printf '%s' "$out" | jq -e '
    .error == "" and (.fuel.cells | length) == 1
    and (.fuel.cells[0] | .pct == "unreadable" and .tone == "unknown"
      and (.fill | test("width: 0%"))
      and (.meta | test("no credential file at /nowhere")))
  ' >/dev/null || fail "an unreadable pool did not say why: $out"
  pass "an unreadable pool reads as unreadable with its reason, not as an empty bar"
}

test_a_nearly_spent_pool_reads_differently_from_a_healthy_one() {
  local home out
  home=$(make_home fuel-tone)
  out=$(render_pools "$home" '[
    {"provider":"a","label":"Healthy","percent_remaining":80,"window":"week"},
    {"provider":"b","label":"Tight","percent_remaining":35,"window":"week"},
    {"provider":"c","label":"Nearly gone","percent_remaining":4,"window":"week"}
  ]')
  printf '%s' "$out" | jq -e '
    [.fuel.cells[] | .tone] == ["ok", "mid", "low"]
    and [.fuel.cells[] | .fill] == ["width: 80%", "width: 35%", "width: 4%"]
  ' >/dev/null || fail "the gauge did not separate a healthy pool from a spent one: $out"
  pass "a nearly spent pool reads differently from a healthy one"
}

test_an_estimated_reading_says_it_is_an_estimate() {
  local home out
  home=$(make_home fuel-estimate)
  out=$(render_pools "$home" '[
    {"provider":"openai-codex","label":"ChatGPT","percent_remaining":80,"window":"30 day",
     "resets_at":null,"estimate":true,"note":null}
  ]')
  printf '%s' "$out" | jq -e '.fuel.cells[0].meta | test("estimate")' >/dev/null \
    || fail "an estimated reading did not say so on the board: $out"
  pass "an estimated reading is labelled an estimate on the gauge"
}

# Build a board carrying <parked-ideas-json|-> and return what the renderer produced.
render_ideas() {  # <home> <parked-ideas-json|-> [idea-typed-into-the-box...]
  local home=$1 ideas=$2 data="$1/ideas-payload.json"
  shift 2
  if [ "$ideas" = "-" ]; then
    jq -n '{schema:"fm-bearings-board.v1", home:"render-home", generated:"2026-08-31T00:00Z",
      prs_live:false, captains_call:[], underway:[], landed:[], charted:[]}' > "$data"
  else
    jq -n --argjson ideas "$ideas" '{schema:"fm-bearings-board.v1", home:"render-home",
      generated:"2026-08-31T00:00Z", prs_live:false, captains_call:[], underway:[],
      landed:[], charted:[], parked_ideas:$ideas}' > "$data"
  fi
  PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    "$BOARD" build "$data" >/dev/null || fail "the board did not build"
  node "$HARNESS" "$home/.lavish/bearings-board.html" "$@" \
    || fail "the built board could not be rendered"
}

test_a_board_without_parked_ideas_shows_the_empty_state() {
  local home out
  home=$(make_home ideas-absent)
  out=$(render_ideas "$home" -)
  printf '%s' "$out" | jq -e '
    .error == "" and (.parkedIdeas | length) == 0
      and (.parkedIdeasEmpty | length) == 1
      and (.parkedIdeasEmpty[0] | test("No ideas parked yet"))
  ' >/dev/null || fail "a board with no parked ideas did not render the empty state: $out"
  pass "a board built without parked ideas shows the parked-ideas empty state"
}

test_parked_ideas_render_title_and_repo() {
  local home out
  home=$(make_home ideas-present)
  out=$(render_ideas "$home" '[
    {"id":"idea-a","title":"Try a dark theme","repo":"sample"},
    {"id":"idea-b","title":"General fleet idea","repo":null}
  ]')
  printf '%s' "$out" | jq -e '
    .error == "" and (.parkedIdeas | length) == 2
      and (.parkedIdeasEmpty | length) == 0
      and (.parkedIdeas[0].title == "Try a dark theme" and .parkedIdeas[0].sub == "sample")
      and (.parkedIdeas[1].title == "General fleet idea" and .parkedIdeas[1].sub == "")
  ' >/dev/null || fail "the built board did not render both parked ideas correctly: $out"
  pass "parked ideas render their title, and their repo only when known"
}

test_an_unmarked_row_keeps_the_title_its_backlog_row_has() {
  local home out data
  home=$(make_home ideas-unmarked); data="$home/unmarked-payload.json"
  jq -n '{schema:"fm-bearings-board.v1", home:"render-home", generated:"2026-08-31T00:00Z",
    prs_live:false, captains_call:[],
    underway:[{id:"ship-b", state:"working", doing:"Idea: capture box for the board",
               kind:"ship", repo:"sample"}],
    landed:[{id:"ship-c", what:"Idea: capture box shipped", owner:"(main)", repo:"sample"}],
    charted:[{id:"ship-a", title:"Idea: capture box for the board", repo:"sample",
              reason:"waiting on review", dispatchable:true}]}' > "$data"
  PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    "$BOARD" build "$data" >/dev/null || fail "the board did not build"
  out=$(node "$HARNESS" "$home/.lavish/bearings-board.html") \
    || fail "the built board could not be rendered"
  printf '%s' "$out" | jq -e '
    .error == "" and .charted[0].title == "Idea: capture box for the board"
      and .underway == ["Idea: capture box for the board"]
      and .landed == ["Idea: capture box shipped"]
  ' >/dev/null || fail "an ordinary task lost the title its backlog row has: $out"
  pass "a row not marked as an idea keeps its exact stored title"
}

test_tag_shaped_text_cannot_be_smuggled_into_a_parked_idea() {
  local home out
  home=$(make_home ideas-tags)
  out=$(render_ideas "$home" - \
    "use (hold-kind: captain) (hold: pick one) for the parser" \
    "blocked-by: vendor and more words here" \
    "park it (since 2026-01-01) please")
  printf '%s' "$out" | jq -e '
    .error == "" and (.ideaCapture.queued | length) == 3
      and ([.ideaCapture.queued[].answer] | map(test("\\((hold-kind|hold-until|hold|kind|repo|priority):")) | any | not)
      and ([.ideaCapture.queued[].answer] | map(test("blocked-by:")) | any | not)
      and ([.ideaCapture.queued[].answer] | map(test("\\((since|merged|reported|done)[ ]")) | any | not)
      and (.ideaCapture.queued[0].answer | test("hold-kind") and test("for the parser"))
      and (.ideaCapture.queued[1].answer | test("vendor and more words here"))
      and (.ideaCapture.queued[2].answer | test("2026-01-01") and test("please"))
  ' >/dev/null || fail "a queued idea still carried backlog metadata shapes: $out"
  pass "a captured idea cannot smuggle backlog metadata tags or a blocker into its title"
}

# The backlog reader treats a comma plus ANY Unicode whitespace as a tag anchor,
# so a cleaner that matches only some space characters would let a pasted one
# carry a real tag straight through.
test_unicode_whitespace_cannot_hide_a_metadata_tag() {
  local home out sp tag
  # U+00A0 (no-break space) and U+0085 (next line) both carry the Unicode
  # White_Space property, so the backlog reader's [[:space:]] accepts either in
  # front of a metadata key even though neither is an ASCII space.
  for tag in a0 85; do
    sp=$(printf "\\302\\2$( [ "$tag" = a0 ] && printf 40 || printf 05 )")
    home=$(make_home "ideas-uws-$tag")
    out=$(render_ideas "$home" - \
      "parser rethink,${sp}hold-kind: captain,${sp}hold: pick one" \
      "park it (since${sp}2026-01-01) please")
    printf '%s' "$out" | jq -e '
      .error == "" and (.ideaCapture.queued | length) == 2
        and ([.ideaCapture.queued[].answer] | map(test("(hold-kind|hold):")) | any | not)
        and (.ideaCapture.queued[1].answer | test("\\(since[[:space:]]") | not)
        and (.ideaCapture.queued[0].answer | test("pick one"))
        and (.ideaCapture.queued[1].answer | test("2026-01-01"))
    ' >/dev/null || fail "unicode whitespace U+00$tag carried a metadata tag through: $out"
  done
  pass "unicode whitespace before a key cannot hide a backlog metadata tag"
}

test_ordinary_idea_text_reaches_the_queue_untouched() {
  local home out
  home=$(make_home ideas-plain)
  out=$(render_ideas "$home" - "try lavish (https://ht-ml.app) for the review page")
  printf '%s' "$out" | jq -e '
    .error == "" and (.ideaCapture.queued | length) == 1
      and .ideaCapture.queued[0].answer == "try lavish (https://ht-ml.app) for the review page"
  ' >/dev/null || fail "ordinary idea text was rewritten: $out"
  pass "ordinary idea text, including a parenthesised URL, is queued verbatim"
}

test_a_board_with_no_live_connection_keeps_the_idea_and_says_so() {
  local home out
  home=$(make_home ideas-nobridge)
  out=$(FM_BOARD_NO_LAVISH=1 render_ideas "$home" - "Buy a bigger anchor")
  printf '%s' "$out" | jq -e '
    .error == "" and (.ideaCapture.queued | length) == 0
      and .ideaCapture.kept == "Buy a bigger anchor"
      and .ideaCapture.queuedTick == false
      and (.ideaCapture.limitText | test("no live connection"))
  ' >/dev/null || fail "an unqueueable idea was lost or falsely confirmed: $out"
  pass "with no live connection the idea stays in the box and the board says why"
}

test_the_stored_idea_prefix_never_reaches_the_captain() {
  local home out
  home=$(make_home ideas-prefix)
  out=$(render_ideas "$home" '[{"id":"idea-a","title":"Idea: batch the merges","repo":"sample"}]')
  printf '%s' "$out" | jq -e '
    .error == "" and .parkedIdeas[0].title == "batch the merges"
  ' >/dev/null || fail "the parked idea still showed its plumbing prefix: $out"
  pass "a parked idea renders without the stored Idea: prefix"
}

test_a_promoted_idea_row_drops_the_prefix_too() {
  local home out data
  home=$(make_home ideas-promoted); data="$home/promoted-payload.json"
  jq -n '{schema:"fm-bearings-board.v1", home:"render-home", generated:"2026-08-31T00:00Z",
    prs_live:false, captains_call:[],
    underway:[{id:"idea-b", state:"working", doing:"Idea: repaint the hull",
               kind:"ship", repo:"sample", idea:true}],
    landed:[{id:"idea-c", what:"Idea: scrub the deck", owner:"(main)", repo:"sample",
             idea:true}],
    charted:[{id:"idea-a", title:"Idea: batch the merges", repo:"sample",
              reason:"waiting on review", dispatchable:true, idea:true}]}' > "$data"
  PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    "$BOARD" build "$data" >/dev/null || fail "the board did not build"
  out=$(node "$HARNESS" "$home/.lavish/bearings-board.html") \
    || fail "the built board could not be rendered"
  printf '%s' "$out" | jq -e '
    .error == "" and .charted[0].title == "batch the merges" and .charted[0].pickable == true
      and .underway == ["repaint the hull"] and .landed == ["scrub the deck"]
  ' >/dev/null || fail "a promoted idea kept its plumbing prefix on the board: $out"
  pass "a promoted idea drops the stored Idea: prefix in charted, underway, and landed"
}

test_two_captured_ideas_queue_two_distinct_answers() {
  local home out
  home=$(make_home ideas-capture)
  out=$(render_ideas "$home" - "Buy a bigger anchor" "Repaint the hull")
  printf '%s' "$out" | jq -e '
    .error == "" and .ideaCapture.submitted == 2 and .ideaCapture.cleared == true
      and (.ideaCapture.queued | length) == 2
      and (.ideaCapture.queued | map(.key) | all(startswith("idea.")))
      and (.ideaCapture.queued | map(.key) | unique | length) == 2
      and .ideaCapture.queued[0].answer == "Buy a bigger anchor"
      and .ideaCapture.queued[1].answer == "Repaint the hull"
  ' >/dev/null || fail "two submitted ideas did not queue two distinct idea answers: $out"
  pass "two captured ideas queue two distinct idea.* answers"
}

test_an_over_long_idea_is_refused_instead_of_queued() {
  local home out long
  home=$(make_home ideas-toolong)
  long=$(printf 'x%.0s' $(seq 1 600))
  out=$(render_ideas "$home" - "$long")
  printf '%s' "$out" | jq -e '
    .error == "" and (.ideaCapture.queued | length) == 0
      and (.ideaCapture.limitText | test("too long"))
  ' >/dev/null || fail "an over-long idea was not refused: $out"
  pass "an idea over the answer-size limit is refused instead of queued"
}

test_a_warning_row_reads_as_a_repair_not_as_queued_work
test_warnings_are_excluded_from_the_charted_next_count
test_a_board_of_only_warnings_still_reports_nothing_queued
test_omitted_warnings_never_count_as_more_queued
test_an_omitted_kind_keeps_the_existing_queued_rendering
test_a_readable_pool_shows_how_much_is_left_and_when_it_resets
test_a_board_without_pools_shows_no_gauge_at_all
test_an_unreadable_pool_says_so_instead_of_showing_a_bar
test_a_nearly_spent_pool_reads_differently_from_a_healthy_one
test_an_estimated_reading_says_it_is_an_estimate
test_a_board_without_parked_ideas_shows_the_empty_state
test_parked_ideas_render_title_and_repo
test_two_captured_ideas_queue_two_distinct_answers
test_an_over_long_idea_is_refused_instead_of_queued
test_the_stored_idea_prefix_never_reaches_the_captain
test_a_promoted_idea_row_drops_the_prefix_too
test_an_unmarked_row_keeps_the_title_its_backlog_row_has
test_tag_shaped_text_cannot_be_smuggled_into_a_parked_idea
test_ordinary_idea_text_reaches_the_queue_untouched
test_unicode_whitespace_cannot_hide_a_metadata_tag
test_a_board_with_no_live_connection_keeps_the_idea_and_says_so
