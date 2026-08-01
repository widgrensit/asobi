-module(asobi_zone_grid_tests).
-include_lib("eunit/include/eunit.hrl").

ring_centred_within_bounds_test() ->
    ?assertEqual(
        [{0, 0}, {0, 1}, {0, 2}, {1, 0}, {1, 1}, {1, 2}, {2, 0}, {2, 1}, {2, 2}],
        asobi_zone_grid:ring({1, 1}, 1, 10)
    ).

ring_clamps_low_edge_test() ->
    ?assertEqual(
        [{0, 0}, {0, 1}, {1, 0}, {1, 1}],
        asobi_zone_grid:ring({0, 0}, 1, 10)
    ).

%% pos_to_zone/3 clamps its callers to 0 .. GridSize - 1, but a coordinate
%% right at that upper edge still needs a ring that doesn't run off the grid.
ring_clamps_high_edge_test() ->
    ?assertEqual(
        [{1, 1}, {1, 2}, {2, 1}, {2, 2}],
        asobi_zone_grid:ring({2, 2}, 1, 3)
    ).

%% Guards the degrade-to-empty path a caller can only hit by skipping
%% pos_to_zone/3's clamp and passing an already out-of-grid centre.
ring_out_of_grid_centre_is_empty_test() ->
    ?assertEqual([], asobi_zone_grid:ring({5, 5}, 1, 3)).

ring_radius_zero_is_just_the_centre_test() ->
    ?assertEqual([{4, 4}], asobi_zone_grid:ring({4, 4}, 0, 10)).

%% A non-integer centre is a caller contract violation (Coords should always
%% come from pos_to_zone/3), but both interest_zones/3 and proximity_zones/3
%% delegate here unconditionally, so this degrades rather than crashing
%% either caller differently.
ring_non_integer_centre_is_empty_test() ->
    ?assertEqual([], asobi_zone_grid:ring({1.0, 1}, 1, 10)),
    ?assertEqual([], asobi_zone_grid:ring({1, 1.0}, 1, 10)).

%% Radius wider than the grid clamps to the whole grid rather than
%% degrading - min/2 is the mutation-sensitive edge here.
ring_radius_exceeding_grid_clamps_to_whole_grid_test() ->
    ?assertEqual(
        [{X, Y} || X <- lists:seq(0, 2), Y <- lists:seq(0, 2)],
        asobi_zone_grid:ring({1, 1}, 50, 3)
    ).

ring_zero_grid_is_empty_test() ->
    ?assertEqual([], asobi_zone_grid:ring({0, 0}, 1, 0)).
