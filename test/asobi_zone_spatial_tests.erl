-module(asobi_zone_spatial_tests).

-include_lib("eunit/include/eunit.hrl").

%% -------------------------------------------------------------------
%% Helpers
%% -------------------------------------------------------------------

base_config() ->
    %% Ensure ETS table and pg scope exist
    ensure_ets(),
    ensure_pg(),
    #{
        world_id => ~"test-world",
        coords => {0, 0},
        ticker_pid => self(),
        game_module => asobi_zone_spatial_test_game
    }.

config_with_grid() ->
    (base_config())#{spatial_grid_cell_size => 16}.

ensure_ets() ->
    case ets:info(asobi_world_state) of
        undefined -> ets:new(asobi_world_state, [named_table, public, set]);
        _ -> ok
    end.

ensure_pg() ->
    case pg:start(nova_scope) of
        {ok, _} -> ok;
        {error, {already_started, _}} -> ok
    end.

start_zone(Config) ->
    {ok, Pid} = asobi_zone:start_link(Config),
    Pid.

stop_zone(Pid) ->
    gen_server:stop(Pid).

%% -------------------------------------------------------------------
%% Test game module (minimal mock)
%% -------------------------------------------------------------------

%% -------------------------------------------------------------------
%% Tests
%% -------------------------------------------------------------------

grid_created_when_configured_test() ->
    Pid = start_zone(config_with_grid()),
    %% The zone should start without error; query_radius should work
    Result = asobi_zone:query_radius(Pid, {0.0, 0.0}, 100.0),
    ?assertEqual([], Result),
    stop_zone(Pid).

no_grid_without_config_test() ->
    Pid = start_zone(base_config()),
    %% query_radius should still work via fallback
    Result = asobi_zone:query_radius(Pid, {0.0, 0.0}, 100.0),
    ?assertEqual([], Result),
    stop_zone(Pid).

add_entity_reflected_in_grid_test() ->
    Pid = start_zone(config_with_grid()),
    asobi_zone:add_entity(Pid, ~"e1", #{x => 10.0, y => 10.0}),
    timer:sleep(50),
    Result = asobi_zone:query_radius(Pid, {10.0, 10.0}, 5.0),
    ?assertEqual([{~"e1", {10.0, 10.0}}], Result),
    stop_zone(Pid).

remove_entity_reflected_in_grid_test() ->
    Pid = start_zone(config_with_grid()),
    asobi_zone:add_entity(Pid, ~"e1", #{x => 10.0, y => 10.0}),
    timer:sleep(50),
    asobi_zone:remove_entity(Pid, ~"e1"),
    timer:sleep(50),
    Result = asobi_zone:query_radius(Pid, {10.0, 10.0}, 5.0),
    ?assertEqual([], Result),
    stop_zone(Pid).

query_radius_returns_nearby_only_test() ->
    Pid = start_zone(config_with_grid()),
    asobi_zone:add_entity(Pid, ~"near", #{x => 5.0, y => 5.0}),
    asobi_zone:add_entity(Pid, ~"far", #{x => 500.0, y => 500.0}),
    timer:sleep(50),
    Result = asobi_zone:query_radius(Pid, {5.0, 5.0}, 10.0),
    Ids = [Id || {Id, _} <- Result],
    ?assertEqual([~"near"], Ids),
    stop_zone(Pid).

fallback_without_grid_test() ->
    Pid = start_zone(base_config()),
    asobi_zone:add_entity(Pid, ~"e1", #{x => 10.0, y => 10.0}),
    timer:sleep(50),
    Result = asobi_zone:query_radius(Pid, {10.0, 10.0}, 5.0),
    ?assertEqual([{~"e1", {10.0, 10.0}}], Result),
    stop_zone(Pid).

entity_without_position_ignored_by_grid_test() ->
    Pid = start_zone(config_with_grid()),
    asobi_zone:add_entity(Pid, ~"nopos", #{type => ~"marker"}),
    timer:sleep(50),
    Result = asobi_zone:query_radius(Pid, {0.0, 0.0}, 1000.0),
    ?assertEqual([], Result),
    stop_zone(Pid).

%% widgrensit/asobi#558: sync_spatial_grid derived its removals with `--`, and
%% the O(N^2) that replaced covers exactly this path - an entity that the tick
%% dropped, rather than one a `remove_entity` cast took out of the grid
%% directly.
tick_removal_reflected_in_grid_test() ->
    Pid = start_zone(config_with_grid()),
    asobi_zone:add_entity(Pid, ~"stays", #{x => 10.0, y => 10.0}),
    asobi_zone:add_entity(Pid, ~"goes", #{x => 11.0, y => 11.0, despawn => true}),
    asobi_zone:tick(Pid, 1),
    _ = sys:get_state(Pid),
    Result = asobi_zone:query_radius(Pid, {10.0, 10.0}, 5.0),
    ?assertEqual([{~"stays", {10.0, 10.0}}], Result),
    stop_zone(Pid).

%% The other half of tick_removal_reflected_in_grid_test: an entity the tick
%% MOVED. That is the branch of sync_spatial_grid/3 on the hot path, and it had
%% no coverage in eunit or CT before widgrensit/asobi#557's review.
tick_movement_reflected_in_grid_test() ->
    Pid = start_zone(config_with_grid()),
    asobi_zone:add_entity(Pid, ~"mover", #{x => 10.0, y => 10.0, drift => 40.0}),
    asobi_zone:add_entity(Pid, ~"still", #{x => 11.0, y => 11.0}),
    asobi_zone:tick(Pid, 1),
    _ = sys:get_state(Pid),
    ?assertEqual(
        [{~"still", {11.0, 11.0}}],
        asobi_zone:query_radius(Pid, {10.0, 10.0}, 5.0)
    ),
    ?assertEqual(
        [{~"mover", {50.0, 10.0}}],
        asobi_zone:query_radius(Pid, {50.0, 10.0}, 5.0)
    ),
    stop_zone(Pid).
