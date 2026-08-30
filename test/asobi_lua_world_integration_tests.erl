-module(asobi_lua_world_integration_tests).
-include_lib("eunit/include/eunit.hrl").

%% asobi#246: spawn_templates/1, terrain_provider/1, and phases/1 all silently
%% no-op'd in production because asobi_world_server calls them with the raw
%% world config (no lua_state threaded through) - a shape none of the
%% existing unit tests exercised, since they all built their state via
%% asobi_lua_world:init/1 first. This boots a REAL asobi_world_instance (the
%% actual production entry point, from the asobi dependency this app already
%% has) with a Lua game module, so a regression here fails through the real
%% call path instead of a hand-built one.

-spec fixture(string()) -> file:filename_all().
fixture(Name) ->
    case code:lib_dir(asobi) of
        {error, _} -> error(asobi_not_loaded);
        Dir -> filename:absname(filename:join([Dir, "test", "fixtures", "lua", Name]))
    end.

ensure_pg_scope() ->
    case whereis(nova_scope) of
        undefined -> pg:start_link(nova_scope);
        _ -> ok
    end,
    ok.

world_config() ->
    world_config(fixture("world_server_integration.lua")).

world_config(ScriptPath) ->
    N = integer_to_binary(erlang:unique_integer([positive])),
    #{
        world_id => <<"lua_world_integration_", N/binary>>,
        game_module => asobi_lua_world,
        game_config => #{lua_script => ScriptPath},
        grid_size => 1,
        zone_size => 1200,
        tick_rate => 20,
        max_players => 8,
        view_radius => 0
    }.

start_world() ->
    start_world(world_config()).

start_world(Config) ->
    ok = ensure_pg_scope(),
    {ok, InstancePid} = asobi_world_instance:start_link(Config),
    unlink(InstancePid),
    %% loading -> running transition, same wait asobi_world_server_tests uses.
    timer:sleep(50),
    InstancePid.

spawn_templates_reach_a_real_zone_test_() ->
    {timeout, 10, fun() ->
        InstancePid = start_world(),
        try
            ZoneManagerPid = asobi_world_instance:get_child(InstancePid, asobi_zone_manager),
            {ok, ZonePid} = asobi_zone_manager:get_zone(ZoneManagerPid, {0, 0}),
            %% zone_tick spawns on tick 1, the spawn cast lands on a
            %% following tick - poll rather than a fixed sleep.
            %% The probe is inserted directly by game.zone.spawn, so its
            %% base_state keys are atom-shaped at insertion (asobi_lua#118) -
            %% this poll can never observe a half-converted entity, whichever
            %% tick it lands on.
            Probes = poll_until(
                fun() ->
                    Entities = asobi_zone:get_entities(ZonePid),
                    [
                        E
                     || {_Id, E} <- maps:to_list(Entities),
                        maps:get(type, E, undefined) =:= ~"object"
                    ]
                end,
                fun(Found) -> Found =/= [] end,
                2000
            ),
            ?assertEqual(1, length(Probes)),
            [Probe] = Probes,
            ?assertEqual(true, maps:get(solid, Probe))
        after
            catch exit(InstancePid, shutdown)
        end
    end}.

%% widgrensit/asobi#270 end-to-end regression: proves a Lua-world player
%% actually re-homes across a zone boundary through a REAL asobi_zone
%% process, not just that the returned entity map has the corrected key
%% shape. Before the fix, asobi_zone:find_zone_crossings/5's atom-keyed
%% clauses never matched a Lua world's binary-keyed entities, so the player
%% below would stay stuck in zone (0,0) forever regardless of position.
zone_crossing_rehomes_lua_player_test_() ->
    {timeout, 10, fun() ->
        Config = (world_config(fixture("world_zone_crossing_e2e.lua")))#{
            grid_size => 4,
            zone_size => 100
        },
        InstancePid = start_world(Config),
        try
            WorldPid = asobi_world_instance:get_child(InstancePid, asobi_world_server),
            true = is_pid(WorldPid),
            ZoneManagerPid = asobi_world_instance:get_child(InstancePid, asobi_zone_manager),

            %% move_player/4 (the actual removal-from-old-zone mechanism)
            %% goes through the world server's player_zones tracking, not
            %% the zone alone - a player injected via player_input/3 without
            %% ever joining never gets that entry, so it can never be
            %% rehomed. join/2 is what a real client connection does before
            %% sending any input.
            ok = asobi_world_server:join(WorldPid, ~"p1"),
            timer:sleep(20),
            {ok, ZoneAPid} = asobi_zone_manager:get_zone(ZoneManagerPid, {0, 0}),

            %% Place the player well inside zone (0,0) (boundary at x=100).
            ok = asobi_zone:player_input(ZoneAPid, ~"p1", #{
                ~"kind" => ~"move", ~"x" => 50, ~"y" => 50
            }),
            InZoneA = poll_until(
                fun() -> maps:get(~"p1", asobi_zone:get_entities(ZoneAPid), undefined) end,
                fun(E) -> is_map(E) end,
                2000
            ),
            ?assertMatch(#{type := ~"player", x := 50, y := 50}, InZoneA),

            %% Move 20 units past the boundary - past the default 15-unit
            %% (zone_size * 0.15) hysteresis margin, so this must register as
            %% a real crossing, not jitter.
            ok = asobi_zone:player_input(ZoneAPid, ~"p1", #{
                ~"kind" => ~"move", ~"x" => 120, ~"y" => 50
            }),

            %% Direct proof of re-homing: the player must disappear from
            %% zone (0,0)'s own entity set once it crosses out, driven by the
            %% world's own tick loop (tick_rate => 20 in world_config/1) -
            %% no manually forced tick.
            LeftZoneA = poll_until(
                fun() -> maps:is_key(~"p1", asobi_zone:get_entities(ZoneAPid)) end,
                fun(StillThere) -> StillThere =:= false end,
                3000
            ),
            ?assertEqual(false, LeftZoneA),

            %% And it must land in the zone it actually crossed into, with
            %% its live (moved) position - not a stale copy.
            {ok, ZoneBPid} = asobi_zone_manager:get_zone(ZoneManagerPid, {1, 0}),
            InZoneB = poll_until(
                fun() -> maps:get(~"p1", asobi_zone:get_entities(ZoneBPid), undefined) end,
                fun(E) -> is_map(E) end,
                2000
            ),
            ?assertMatch(#{type := ~"player", x := 120, y := 50}, InZoneB)
        after
            catch exit(InstancePid, shutdown)
        end
    end}.

phases_reach_the_world_server_test_() ->
    {timeout, 10, fun() ->
        InstancePid = start_world(),
        try
            WorldPid = asobi_world_instance:get_child(InstancePid, asobi_world_server),
            true = is_pid(WorldPid),
            Info = asobi_world_server:get_info(WorldPid),
            %% asobi_world_server:init/1 only calls asobi_phase:init/1 (which
            %% populates phase_state, and in turn get_info/1's `phase` key)
            %% when GameMod:phases/1 returns a non-empty list. If phases/1
            %% silently no-ops back to [] (asobi#246), this key is absent.
            ?assertMatch(#{phase := #{phase := ~"lobby"}}, Info)
        after
            catch exit(InstancePid, shutdown)
        end
    end}.

%% asobi#246 follow-up: fixing the silent no-op must not overcorrect into
%% false alarms. spawn_templates/1, terrain_provider/1, and phases/1 are all
%% documented OPTIONAL (see asobi_lua_world's moduledoc); a script that never
%% defines terrain_provider is not an error and must not reach the dev-error
%% telemetry channel.
absent_optional_callback_emits_no_game_error_test_() ->
    {timeout, 10, fun() ->
        {ok, _} = application:ensure_all_started(telemetry),
        Self = self(),
        Ref = make_ref(),
        telemetry:attach(
            Ref, [asobi, error], fun(_E, _M, Meta, _) -> Self ! {ev, Meta} end, []
        ),
        %% world_server_integration.lua defines no terrain_provider.
        InstancePid = start_world(),
        try
            receive
                {ev, Meta} -> erlang:error({unexpected_game_error, Meta})
            after 500 -> ok
            end
        after
            telemetry:detach(Ref),
            catch exit(InstancePid, shutdown)
        end
    end}.

%% Companion positive case: a callback that IS defined and raises must still
%% reach the dev-error channel - the is_defined/2 guard must not swallow real
%% failures along with absent-optional-callback silence.
defined_callback_error_emits_game_error_test_() ->
    {timeout, 10, fun() ->
        {ok, _} = application:ensure_all_started(telemetry),
        Self = self(),
        Ref = make_ref(),
        telemetry:attach(
            Ref, [asobi, error], fun(_E, _M, Meta, _) -> Self ! {ev, Meta} end, []
        ),
        Config = world_config(fixture("world_server_integration_broken_terrain.lua")),
        InstancePid = start_world(Config),
        try
            receive
                {ev, #{kind := lua_error, details := D}} ->
                    ?assertEqual(terrain_provider, maps:get(callback, D))
            after 2000 -> ?assert(false)
            end
        after
            telemetry:detach(Ref),
            catch exit(InstancePid, shutdown)
        end
    end}.

%% widgrensit/asobi#574: the whole chain, through the real world instance - a
%% lazily-created zone asks the world server, the world VM runs
%% `on_zone_loaded`, and what it returns is the `zone_state` the ZONE script
%% is handed on its first tick. Asserting on the zone's Lua-visible state
%% rather than on the bridge function is the point: the bridge was always
%% callable, it was just never reached.
lua_on_zone_loaded_seeds_a_lazy_zone_test_() ->
    {timeout, 10, fun() ->
        Config = (world_config(fixture("zone_seed_world.lua")))#{
            grid_size => 3,
            zone_size => 100,
            lazy_zones => true
        },
        InstancePid = start_world(Config),
        try
            WorldPid = asobi_world_instance:get_child(InstancePid, asobi_world_server),
            ZoneManagerPid = asobi_world_instance:get_child(InstancePid, asobi_zone_manager),
            ok = asobi_world_server:join(WorldPid, ~"p1"),
            {ok, ZonePid} = poll_until(
                fun() -> asobi_zone_manager:get_zone(ZoneManagerPid, {1, 1}) end,
                fun(R) -> R =/= not_loaded end,
                2000
            ),
            Marker = poll_until(
                fun() -> maps:get(~"marker", asobi_zone:get_entities(ZonePid), undefined) end,
                fun(E) -> is_map(E) end,
                2000
            ),
            ?assertMatch(#{biome := ~"plains"}, Marker),
            ?assertEqual(1, maps:get(cx, Marker)),
            ?assertEqual(1, maps:get(cy, Marker))
        after
            exit(InstancePid, shutdown)
        end
    end}.

-spec poll_until(fun(() -> T), fun((T) -> boolean()), non_neg_integer()) -> T.
poll_until(Get, _Done, TimeoutMs) when TimeoutMs =< 0 ->
    Get();
poll_until(Get, Done, TimeoutMs) ->
    Value = Get(),
    case Done(Value) of
        true ->
            Value;
        false ->
            timer:sleep(20),
            poll_until(Get, Done, TimeoutMs - 20)
    end.
