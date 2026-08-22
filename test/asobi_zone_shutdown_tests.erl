-module(asobi_zone_shutdown_tests).
-include_lib("eunit/include/eunit.hrl").

%% widgrensit/asobi#543 review: asobi_zone's terminate/2 is where the final
%% snapshot, the ETS crash-backup clear, the limiter-key forget and the border
%% row drop all live - and none of it ran on a supervisor shutdown, because a
%% gen_server that does not trap exits is killed outright by the shutdown
%% signal. That is the one moment a final snapshot exists for.

-export([zone_tick/2, handle_input/3, dump_zone_state/1]).

zone_tick(E, ZS) -> {E, ZS}.
handle_input(_P, _I, E) -> {ok, E}.
dump_zone_state(ZS) -> ZS.

setup() ->
    case ets:info(asobi_world_state) of
        undefined -> ets:new(asobi_world_state, [named_table, public, set]);
        _ -> ok
    end,
    case pg:start(nova_scope) of
        {ok, _} -> ok;
        {error, {already_started, _}} -> ok
    end,
    meck:new(asobi_zone_snapshotter, [no_link, non_strict]),
    meck:expect(asobi_zone_snapshotter, snapshot, fun(_) -> ok end),
    meck:expect(asobi_zone_snapshotter, snapshot_sync, fun(Snap) ->
        ets:insert(?MODULE, {snapshot, Snap}),
        ok
    end),
    meck:expect(asobi_zone_snapshotter, load_snapshot, fun(_, _) -> {error, not_found} end),
    case ets:whereis(?MODULE) of
        undefined -> ets:new(?MODULE, [named_table, public, set]);
        _ -> ets:delete_all_objects(?MODULE)
    end,
    ok.

cleanup(_) ->
    meck:unload(asobi_zone_snapshotter).

zone_config(Sup) ->
    #{
        world_id => ~"shutdown-world",
        coords => {1, 1},
        ticker_pid => self(),
        zone_size => 100,
        grid_size => 5,
        border_band => 0.1,
        border_tab => persistent_term:get({?MODULE, tab}),
        persistence => true,
        snapshot_interval => 600,
        zone_sup => Sup,
        game_module => ?MODULE
    }.

shutdown_test_() ->
    {foreach, fun setup/0, fun cleanup/1, [
        {"a zone snapshots when its supervisor shuts it down", fun snapshots_on_shutdown/0},
        {"a zone drops its border row when its supervisor shuts it down",
            fun clears_border_on_shutdown/0}
    ]}.

start_supervised_zone() ->
    persistent_term:put({?MODULE, tab}, asobi_zone_border:new()),
    {ok, Sup} = asobi_zone_sup:start_link(),
    unlink(Sup),
    {ok, Zone} = asobi_zone_sup:start_zone(Sup, zone_config(Sup)),
    {Sup, Zone}.

stop_sup(Sup, Zone) ->
    Ref = monitor(process, Zone),
    exit(Sup, shutdown),
    receive
        {'DOWN', Ref, process, Zone, _} -> ok
    after 5000 -> error(zone_never_stopped)
    end.

snapshots_on_shutdown() ->
    {Sup, Zone} = start_supervised_zone(),
    asobi_zone:add_entity(Zone, ~"keep", #{
        type => ~"npc", x => 150.0, y => 150.0, persistent => true
    }),
    asobi_zone:tick(Zone, 1),
    _ = sys:get_state(Zone),
    ?assertEqual([], ets:lookup(?MODULE, snapshot)),
    stop_sup(Sup, Zone),
    [{snapshot, Snap}] = ets:lookup(?MODULE, snapshot),
    ?assertMatch(#{coords := {1, 1}, entities := #{~"keep" := _}}, Snap).

clears_border_on_shutdown() ->
    {Sup, Zone} = start_supervised_zone(),
    Tab = persistent_term:get({?MODULE, tab}),
    asobi_zone:add_entity(Zone, ~"edge", #{type => ~"npc", x => 105.0, y => 150.0}),
    asobi_zone:tick(Zone, 1),
    _ = sys:get_state(Zone),
    ?assertMatch([_], asobi_zone_border:query_radius(Tab, {0, 1}, 5, {105.0, 150.0}, 50.0)),
    stop_sup(Sup, Zone),
    ?assertEqual([], asobi_zone_border:query_radius(Tab, {0, 1}, 5, {105.0, 150.0}, 50.0)).
