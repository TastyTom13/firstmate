#!/usr/bin/env bash
# tests/fm-supervision-host-2.test.sh - part 2 of 3 of the supervision-host suite.
# Every case and helper is defined once in tests/fm-supervision-host-helpers.sh; the parts
# only split its run list by CI duration, so no portable serial shard carries
# the whole suite (docs/fm-test-portable-shards.md).
set -u

# shellcheck source=tests/fm-supervision-host-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-supervision-host-helpers.sh"

test_away_wake_is_handled_on_the_engine_and_never_reaches_main
test_away_turn_without_a_report_hands_the_wake_to_main
test_return_during_an_engine_turn_hands_its_outcomes_to_main
test_silent_outcomes_are_not_relayed_when_the_captain_returns
test_large_turn_relays_an_early_visible_outcome
test_outcome_lookup_failure_is_not_treated_as_silence
test_outcome_after_the_return_survives_a_host_killed_at_the_turn_end
test_next_host_clears_a_turn_its_killed_predecessor_left
test_report_without_acknowledgement_hands_the_wake_to_main
test_return_during_a_failed_turn_still_hands_its_outcomes_to_main
test_incomplete_engine_result_hands_the_wake_to_main
test_latch_trips_after_two_engine_errors_then_probes_and_recovers
test_latch_keeps_attended_closes_on_main_and_skips_unopted_homes
