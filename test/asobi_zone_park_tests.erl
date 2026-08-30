-module(asobi_zone_park_tests).
-include_lib("eunit/include/eunit.hrl").

%% widgrensit/asobi#573: a zone could only be stopped when it held nothing, so
%% the snapshot that exists to preserve a populated zone never had anything to
%% preserve. `park/1` is the game module's own decision to stop a zone that is
%% still holding entities; `park_on_idle` lets the idle reaper make it too.

setup() ->
    case whereis(nova_scope) of
        undefined -> pg:start_link(nova_scope);
        _ -> ok
    end,
    ok.

cleanup(_) ->
    ok.

start_zone(Overrides) ->
    Config = maps:merge(
        #{
            world_id => ~"park_world",
            coords => {2, 3},
            ticker_pid => self(),
            game_module => asobi_test_world_game,
            zone_state => #{}
        },
        Overrides
    ),
    {ok, Pid} = asobi_zone:start_link(Config),
    Pid.

await_down(Pid, Timeout) ->
    MonRef = monitor(process, Pid),
    receive
        {'DOWN', MonRef, process, Pid, _} -> ok
    after Timeout ->
        demonitor(MonRef, [flush]),
        timeout
    end.

zone_park_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        {"a populated zone declines reap but accepts park", fun populated_zone_parks/0},
        {"park is declined while a player is subscribed", fun park_declined_with_subscriber/0},
        {"park_on_idle lets the reaper take a populated zone", fun park_on_idle_reaps_populated/0},
        {"park_on_idle still declines a zone with subscribers",
            fun park_on_idle_declines_subscribed/0},
        {"park_on_idle still declines a busy zone", fun park_on_idle_declines_busy/0},
        {"an empty zone is reaped as before", fun empty_zone_still_reaps/0},
        {"a parked persistent zone snapshots the entities it held", fun park_snapshots_entities/0},
        {"a parked persistent zone restores what it held", fun park_restores_entities/0},
        {"a parked non-persistent zone leaves its zone_state with the manager",
            fun park_stashes_zone_state/0},
        {"a persistent zone does not stash - the snapshot owns it",
            fun persistent_park_does_not_stash/0}
    ]}.

%% The half that was missing: the reap path already snapshotted everything a
%% zone held, it just could never run for a zone that held anything.
park_snapshots_entities() ->
    meck:new(asobi_zone_snapshotter, [passthrough]),
    Self = self(),
    meck:expect(asobi_zone_snapshotter, load_snapshot, fun(_, _) -> {error, not_found} end),
    meck:expect(asobi_zone_snapshotter, snapshot_sync, fun(Data) ->
        Self ! {snapshot, Data},
        ok
    end),
    try
        Pid = start_zone(#{persistence => true}),
        asobi_zone:add_entity(Pid, ~"rock1", #{x => 1.0, y => 1.0, type => ~"rock"}),
        ok = asobi_zone:sync(Pid),
        asobi_zone:park(Pid),
        receive
            {snapshot, Data} ->
                ?assert(maps:is_key(~"rock1", maps:get(entities, Data)))
        after 1000 ->
            ?assert(false)
        end,
        ?assertEqual(ok, await_down(Pid, 1000))
    after
        meck:unload(asobi_zone_snapshotter)
    end.

park_restores_entities() ->
    meck:new(asobi_zone_snapshotter, [passthrough]),
    Self = self(),
    meck:expect(asobi_zone_snapshotter, snapshot_sync, fun(Data) ->
        Self ! {snapshot, Data},
        ok
    end),
    meck:expect(asobi_zone_snapshotter, load_snapshot, fun(_, _) -> {error, not_found} end),
    try
        Pid = start_zone(#{persistence => true, game_module => asobi_zone_ctx_test_game}),
        asobi_zone:add_entity(Pid, ~"rock1", #{x => 1.0, y => 1.0, type => ~"rock"}),
        ok = asobi_zone:sync(Pid),
        asobi_zone:park(Pid),
        Snapshot =
            receive
                {snapshot, Data} -> Data
            after 1000 -> #{}
            end,
        ?assertEqual(ok, await_down(Pid, 1000)),
        meck:expect(asobi_zone_snapshotter, load_snapshot, fun(_, _) -> {ok, Snapshot} end),
        Pid2 = start_zone(#{persistence => true, game_module => asobi_zone_ctx_test_game}),
        ok = asobi_zone:sync(Pid2),
        ?assert(maps:is_key(~"rock1", asobi_zone:get_entities(Pid2))),
        gen_server:stop(Pid2)
    after
        meck:unload(asobi_zone_snapshotter)
    end.

%% Non-persistent worlds get the smaller half: no entities, but somewhere to
%% leave "what was true here" that outlives the VM.
park_stashes_zone_state() ->
    Self = self(),
    meck:new(asobi_zone_manager, [passthrough]),
    meck:expect(asobi_zone_manager, park_state, fun(_Ref, Coords, ZoneState) ->
        Self ! {parked, Coords, ZoneState},
        ok
    end),
    try
        Pid = start_zone(#{
            game_module => asobi_zone_ctx_test_game, zone_manager_pid => self()
        }),
        asobi_zone:add_entity(Pid, ~"rock1", #{x => 1.0, y => 1.0, type => ~"rock"}),
        ok = asobi_zone:sync(Pid),
        asobi_zone:park(Pid),
        receive
            {parked, Coords, ZoneState} ->
                ?assertEqual({2, 3}, Coords),
                ?assertEqual(init_zone_state, maps:get(built_by, ZoneState))
        after 1000 ->
            ?assert(false)
        end
    after
        meck:unload(asobi_zone_manager)
    end.

persistent_park_does_not_stash() ->
    Self = self(),
    meck:new(asobi_zone_manager, [passthrough]),
    meck:expect(asobi_zone_manager, park_state, fun(_Ref, Coords, ZoneState) ->
        Self ! {parked, Coords, ZoneState},
        ok
    end),
    meck:new(asobi_zone_snapshotter, [passthrough]),
    meck:expect(asobi_zone_snapshotter, load_snapshot, fun(_, _) -> {error, not_found} end),
    meck:expect(asobi_zone_snapshotter, snapshot_sync, fun(_) -> ok end),
    try
        Pid = start_zone(#{
            persistence => true,
            game_module => asobi_zone_ctx_test_game,
            zone_manager_pid => self()
        }),
        ok = asobi_zone:sync(Pid),
        asobi_zone:park(Pid),
        ?assertEqual(ok, await_down(Pid, 1000)),
        receive
            {parked, _, _} -> ?assert(false)
        after 100 -> ok
        end
    after
        meck:unload(asobi_zone_snapshotter),
        meck:unload(asobi_zone_manager)
    end.

populated_zone_parks() ->
    Pid = start_zone(#{}),
    asobi_zone:add_entity(Pid, ~"npc1", #{x => 1.0, y => 1.0, type => ~"rock"}),
    ok = asobi_zone:sync(Pid),
    %% The manager's own reap is still declined: its idle stamp can lag real
    %% occupancy, so it does not get to tear a populated zone down.
    asobi_zone:reap(Pid),
    ok = asobi_zone:sync(Pid),
    ?assert(is_process_alive(Pid)),
    asobi_zone:park(Pid),
    ?assertEqual(ok, await_down(Pid, 1000)).

park_declined_with_subscriber() ->
    Pid = start_zone(#{}),
    asobi_zone:add_entity(Pid, ~"npc1", #{x => 1.0, y => 1.0, type => ~"rock"}),
    asobi_zone:subscribe(Pid, {~"p1", self()}),
    ok = asobi_zone:sync(Pid),
    asobi_zone:park(Pid),
    ok = asobi_zone:sync(Pid),
    ?assert(is_process_alive(Pid)),
    gen_server:stop(Pid).

park_on_idle_reaps_populated() ->
    Pid = start_zone(#{park_on_idle => true}),
    asobi_zone:add_entity(Pid, ~"npc1", #{x => 1.0, y => 1.0, type => ~"rock"}),
    ok = asobi_zone:sync(Pid),
    asobi_zone:reap(Pid),
    ?assertEqual(ok, await_down(Pid, 1000)).

park_on_idle_declines_subscribed() ->
    Pid = start_zone(#{park_on_idle => true}),
    asobi_zone:add_entity(Pid, ~"npc1", #{x => 1.0, y => 1.0, type => ~"rock"}),
    asobi_zone:subscribe(Pid, {~"p1", self()}),
    ok = asobi_zone:sync(Pid),
    asobi_zone:reap(Pid),
    ok = asobi_zone:sync(Pid),
    ?assert(is_process_alive(Pid)),
    gen_server:stop(Pid).

park_on_idle_declines_busy() ->
    Pid = start_zone(#{
        park_on_idle => true,
        game_module => asobi_zone_busy_game,
        zone_state => #{busy => true}
    }),
    asobi_zone:add_entity(Pid, ~"npc1", #{x => 1.0, y => 1.0, type => ~"rock"}),
    asobi_zone:tick(Pid, 1),
    ok = asobi_zone:sync(Pid),
    asobi_zone:reap(Pid),
    ok = asobi_zone:sync(Pid),
    ?assert(is_process_alive(Pid)),
    gen_server:stop(Pid).

empty_zone_still_reaps() ->
    Pid = start_zone(#{}),
    ok = asobi_zone:sync(Pid),
    asobi_zone:reap(Pid),
    ?assertEqual(ok, await_down(Pid, 1000)).
