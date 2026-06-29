-module(asobi_zone_snapshot_recovery_tests).
-include_lib("eunit/include/eunit.hrl").

%% Idle-reaped zones must snapshot their full state on the way out (graceful
%% stop -> terminate/2), and cold-(re)started persistent zones must restore it.
%% These drive the real zone process; the snapshotter is mecked so no DB is
%% needed.

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
            world_id => ~"recovery_world",
            coords => {1, 1},
            ticker_pid => self(),
            game_module => asobi_zone_ctx_test_game,
            zone_state => #{}
        },
        Overrides
    ),
    {ok, Pid} = asobi_zone:start_link(Config),
    Pid.

recovery_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        {"reap snapshots full state and stops the zone", fun reap_snapshots_full_state/0},
        {"cold start restores game_state, spawner and tick", fun cold_start_restores/0},
        {"cold start with a load error does not clobber the snapshot",
            fun cold_start_load_error_suppresses_persistence/0},
        {"non-persistent zone does not snapshot on reap", fun non_persistent_no_snapshot/0}
    ]}.

reap_snapshots_full_state() ->
    meck:new(asobi_zone_snapshotter, [passthrough]),
    Self = self(),
    meck:expect(asobi_zone_snapshotter, load_snapshot, fun(_, _) -> {error, not_found} end),
    meck:expect(asobi_zone_snapshotter, snapshot_sync, fun(Data) ->
        Self ! {snapshot, Data},
        ok
    end),
    try
        Pid = start_zone(#{persistence => true}),
        Ref = monitor(process, Pid),
        asobi_zone:reap(Pid),
        receive
            {snapshot, Data} ->
                %% The old reap path hardcoded zone_state => #{}; now the game
                %% module's dump_zone_state runs, so built_by survives.
                ZoneState = maps:get(zone_state, Data),
                ?assertEqual(init_zone_state, maps:get(built_by, ZoneState)),
                ?assert(maps:is_key(spawner_state, Data)),
                ?assert(maps:is_key(tick, Data))
        after 1000 ->
            ?assert(false)
        end,
        receive
            {'DOWN', Ref, process, Pid, normal} -> ok
        after 1000 ->
            ?assert(false)
        end
    after
        meck:unload(asobi_zone_snapshotter)
    end.

cold_start_restores() ->
    Templates = goblin_templates(),
    %% Round-trip through json so deserialise sees jsonb-shaped data (binary
    %% keys, float-coerced numbers), as a real DB row would deliver.
    SpawnerState = json:decode(
        iolist_to_binary(json:encode(pending_respawn_spawner_state(Templates)))
    ),
    Snapshot = #{
        zone_state => #{~"saved" => true},
        spawner_state => SpawnerState,
        entity_timers => timer_state(),
        tick => 42
    },
    meck:new(asobi_zone_snapshotter, [passthrough]),
    meck:expect(asobi_zone_snapshotter, load_snapshot, fun(_, _) -> {ok, Snapshot} end),
    try
        Pid = start_zone(#{persistence => true, spawn_templates => Templates}),
        State = sys:get_state(Pid),
        ZoneState = maps:get(zone_state, State),
        %% Restored from the snapshot...
        ?assertEqual(true, maps:get(~"saved", ZoneState)),
        %% ...and init_zone_state still ran on top of the restored state.
        ?assertEqual(init_zone_state, maps:get(built_by, ZoneState)),
        ?assertEqual(42, maps:get(tick, State)),
        Spawner = maps:get(spawner, State),
        ?assertEqual(1, maps:get(pending_respawns, asobi_zone_spawner:info(Spawner))),
        ?assertEqual(1, asobi_entity_timer:active_count(maps:get(entity_timers, State))),
        gen_server:stop(Pid)
    after
        meck:unload(asobi_zone_snapshotter)
    end.

cold_start_load_error_suppresses_persistence() ->
    meck:new(asobi_zone_snapshotter, [passthrough]),
    Self = self(),
    meck:expect(asobi_zone_snapshotter, load_snapshot, fun(_, _) -> {error, db_down} end),
    meck:expect(asobi_zone_snapshotter, snapshot_sync, fun(Data) ->
        Self ! {snapshot, Data},
        ok
    end),
    try
        Pid = start_zone(#{persistence => true}),
        %% Load failed: the zone starts (no crash) but with persistence
        %% suppressed, so it never overwrites the unreadable-but-present row.
        ?assertEqual(false, maps:get(persistence, sys:get_state(Pid))),
        Ref = monitor(process, Pid),
        asobi_zone:reap(Pid),
        receive
            {'DOWN', Ref, process, Pid, normal} -> ok
        after 1000 ->
            ?assert(false)
        end,
        receive
            {snapshot, _} -> ?assert(false)
        after 100 ->
            ok
        end
    after
        meck:unload(asobi_zone_snapshotter)
    end.

non_persistent_no_snapshot() ->
    meck:new(asobi_zone_snapshotter, [passthrough]),
    Self = self(),
    meck:expect(asobi_zone_snapshotter, snapshot_sync, fun(Data) ->
        Self ! {snapshot, Data},
        ok
    end),
    try
        Pid = start_zone(#{persistence => false}),
        Ref = monitor(process, Pid),
        asobi_zone:reap(Pid),
        receive
            {'DOWN', Ref, process, Pid, normal} -> ok
        after 1000 ->
            ?assert(false)
        end,
        receive
            {snapshot, _} -> ?assert(false)
        after 100 ->
            ok
        end
    after
        meck:unload(asobi_zone_snapshotter)
    end.

goblin_templates() ->
    #{
        ~"goblin" => #{
            template_id => ~"goblin",
            type => ~"npc",
            base_state => #{},
            respawn => #{strategy => timer, delay => 1000, max_respawns => infinity, jitter => 0}
        }
    }.

timer_state() ->
    %% A tuple on_complete + a non-general category exercise json_safe/1 and the
    %% binary_to_existing_atom category round-trip through the real restore path.
    S = asobi_entity_timer:start_timer(
        #{
            entity_id => ~"furnace_1",
            timer_id => ~"smelt",
            duration => 60000,
            on_complete => {craft_complete, ~"iron_ingot"},
            category => crafting
        },
        asobi_entity_timer:new()
    ),
    json:decode(iolist_to_binary(json:encode(asobi_entity_timer:serialise(S)))).

pending_respawn_spawner_state(Templates) ->
    S0 = asobi_zone_spawner:new(Templates),
    {ok, {Id, _}, S1} = asobi_zone_spawner:spawn_entity(~"goblin", {1.0, 2.0}, S0),
    Now = erlang:system_time(millisecond),
    S2 = asobi_zone_spawner:entity_removed(Id, Now, S1),
    asobi_zone_spawner:serialise(S2).
