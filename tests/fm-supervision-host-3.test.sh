#!/usr/bin/env bash
# tests/fm-supervision-host-3.test.sh - part 3 of 3 of the supervision-host suite.
# Every case and helper is defined once in tests/fm-supervision-host-helpers.sh; the parts
# only split its run list by CI duration, so no portable serial shard carries
# the whole suite (docs/fm-test-portable-shards.md).
set -u

# shellcheck source=tests/fm-supervision-host-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-supervision-host-helpers.sh"

test_attended_latch_keeps_closes_on_main_and_records_recovery_off_main
test_engine_turn_is_bounded_and_its_descendants_reaped
test_restarted_host_stops_what_a_killed_predecessor_left
test_park_boundary_ends_the_park_before_the_hook_timeout
test_park_boundary_holds_under_back_to_back_closes
test_park_boundary_rechecked_just_before_the_engine_turn
test_park_test_clock_requires_the_marker
test_park_seconds_at_or_beyond_the_hook_registration_fall_back_to_the_default
test_park_limit_lets_a_turn_outlive_the_boundary
test_first_cycle_status_streams_and_owner_options_reach_it
test_unchanged_held_outcome_reaches_the_captain_once_until_a_new_event
test_unverified_engine_hands_every_away_wake_to_main
test_host_outside_the_lock_owner_stands_down
test_superseded_host_leaves_the_owner_untouched
