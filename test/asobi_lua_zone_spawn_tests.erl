-module(asobi_lua_zone_spawn_tests).
-include_lib("eunit/include/eunit.hrl").

%% Per-zone Lua now runs regardless of how the zone was created: each zone
%% process builds its own Luerl VM from the script via init_zone_state/2, bound
%% to the zone pid, so game.zone.spawn reaches the live zone. These tests cover
%% the lazy/fresh path (init_zone_state from an empty zone_state), the snapshot
%% round-trip (dump_zone_state -> jsonb-safe map -> init_zone_state restore),
%% and the full lifecycle through a real asobi_zone.

-spec fixture(string()) -> file:filename_all().
fixture(Name) ->
    case code:lib_dir(asobi) of
        {error, _} -> error(asobi_not_loaded);
        Dir -> filename:absname(filename:join([Dir, "test", "fixtures", "lua", Name]))
    end.

setup() ->
    %% asobi_zone is a plain gen_server; it only needs the nova_scope pg group
    %% for pg:join. Starting the full asobi application would boot Nova, which
    %% isn't configured in this unit-test context.
    case whereis(nova_scope) of
        undefined -> pg:start_link(nova_scope);
        _ -> ok
    end,
    ok.

cleanup(_) ->
    ok.

zone_spawn_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        {"init_zone_state builds a VM from an empty (lazy) zone_state",
            fun init_zone_state_builds_vm/0},
        {"game_state round-trips through dump_zone_state/init_zone_state",
            fun game_state_round_trips/0},
        {"a never-seeded zone round-trips as nil, not an empty table",
            fun unseeded_game_state_round_trips_as_nil/0},
        {"dump_zone_state without a VM stays jsonb-safe", fun dump_without_vm_is_jsonb_safe/0},
        {"game.zone.spawn from Lua reaches a live zone built via handle_continue",
            fun lua_spawn_reaches_zone/0},
        {"game.zone.spawn returns false for a typo'd template_id, true for a known one",
            fun typo_template_id_returns_false/0},
        {"a template added by a script hot-reload is spawnable, not just registered",
            fun hot_reloaded_template_is_spawnable/0}
    ]}.

zone_config() ->
    #{
        world_id => ~"spawn_world",
        coords => {0, 0},
        game_module => asobi_lua_world,
        game_config => #{lua_script => fixture("spawn_world.lua")},
        world_server_pid => self()
    }.

typo_zone_config() ->
    #{
        world_id => ~"spawn_world_typo",
        coords => {0, 0},
        game_module => asobi_lua_world,
        game_config => #{lua_script => fixture("spawn_world_typo.lua")},
        world_server_pid => self()
    }.

init_zone_state_builds_vm() ->
    %% Lazy zones start with no zone_state; init_zone_state must still produce a
    %% usable VM bound to the zone pid.
    ZoneState = asobi_lua_world:init_zone_state(zone_config(), #{}),
    ?assert(maps:is_key(lua_state, ZoneState)),
    ?assertEqual(nil, maps:get(game_state, ZoneState)).

game_state_round_trips() ->
    erlang:erase({asobi_lua_world, zone_state}),
    ZoneState0 = asobi_lua_world:init_zone_state(zone_config(), #{}),
    %% One tick lets the script stamp gameplay state (seeded = true). The spawn
    %% casts it emits go to self() here and are harmless.
    {_Ents, ZoneState1} = asobi_lua_world:zone_tick(#{}, ZoneState0),
    flush_casts(),

    Dumped = asobi_lua_world:dump_zone_state(ZoneState1),
    ?assertEqual(#{~"game_state" => #{~"seeded" => true}}, Dumped),
    ?assertNot(maps:is_key(lua_state, Dumped)),
    %% jsonb-safe: must encode without raising.
    _ = json:encode(Dumped),

    %% Restoring re-encodes the gameplay state into a fresh VM.
    Restored = asobi_lua_world:init_zone_state(zone_config(), Dumped),
    ?assertEqual(
        #{~"game_state" => #{~"seeded" => true}}, asobi_lua_world:dump_zone_state(Restored)
    ),
    erlang:erase({asobi_lua_world, zone_state}).

lua_spawn_reaches_zone() ->
    %% Templates come from the script, exactly as asobi_world_server wires them.
    {ok, WorldState} = asobi_lua_world:init(#{lua_script => fixture("spawn_world.lua")}),
    Templates = asobi_lua_world:spawn_templates(WorldState),
    ?assertMatch(#{~"goblin" := _, ~"chest" := _}, Templates),

    %% Note: NO pre-injected lua_state. The zone builds its own VM in
    %% handle_continue, mirroring a lazy zone.
    {ok, ZonePid} = asobi_zone:start_link(#{
        world_id => ~"spawn_world",
        coords => {0, 0},
        ticker_pid => self(),
        game_module => asobi_lua_world,
        game_config => #{lua_script => fixture("spawn_world.lua")},
        world_server_pid => self(),
        spawn_templates => Templates
    }),

    erlang:erase({asobi_lua_world, zone_state}),
    gen_server:cast(ZonePid, {tick, 1}),
    %% First call flushes the tick (which enqueues the spawn casts); the second
    %% flushes those spawn casts so the entities are present.
    _ = asobi_zone:get_entities(ZonePid),
    Entities = asobi_zone:get_entities(ZonePid),

    Goblins = by_type(~"npc", Entities),
    Chests = by_type(~"object", Entities),
    ?assertEqual(1, length(Goblins)),
    %% One 4-arg spawn with populated overrides ({loot="rare"}), one with an
    %% empty overrides table ({}) - asobi#246 rejected the latter outright.
    ?assertEqual(2, length(Chests)),

    [Goblin] = Goblins,
    %% asobi_lua#118: base_state and override fields must land atom-keyed at
    %% spawn time, not only after some later zone_tick round-trip re-atomizes
    %% the entity. These reads happen before any tick has returned entities.
    ?assert(maps:get(health, Goblin) == 100),
    ?assertEqual(~"patrol", maps:get(ai, Goblin)),

    ChestLoot = lists:sort([maps:get(loot, C) || C <- Chests]),
    ?assertEqual([~"common", ~"rare"], ChestLoot),

    gen_server:stop(ZonePid),
    erlang:erase({asobi_lua_world, zone_state}).

%% asobi_lua#110: game.zone.spawn checks the zone's declared template set
%% (read live from the per-zone ETS table init_zone_state/2 creates - see
%% asobi_lua_world's ?TEMPLATES_KEY) synchronously, before ever casting to
%% the zone process - a typo'd template_id must return false, not the true
%% a caller would wrongly get just because the fire-and-forget cast was
%% sent.
typo_template_id_returns_false() ->
    erlang:erase({asobi_lua_world, zone_state}),
    ZoneState0 = asobi_lua_world:init_zone_state(typo_zone_config(), #{}),
    {_Ents, ZoneState1} = asobi_lua_world:zone_tick(#{}, ZoneState0),
    flush_casts(),

    Dumped = asobi_lua_world:dump_zone_state(ZoneState1),
    ?assertEqual(
        #{
            ~"game_state" => #{
                ~"seeded" => true,
                ~"known_result" => true,
                ~"typo_result" => false
            }
        },
        Dumped
    ),
    erlang:erase({asobi_lua_world, zone_state}).

%% asobi#253 + asobi_lua#110: a template added by a script hot-reload must
%% become spawnable from Lua, not just registered with the zone's spawner.
%% Regression for the Ctx-cached `known_templates` snapshot going stale
%% forever after the first hot reload - asobi_lua_reload re-executes the
%% edited script into the EXISTING Luerl state without ever re-running
%% asobi_lua_api:install/2, so a Ctx-captured closure never saw the update.
hot_reloaded_template_is_spawnable() ->
    OldEnv = application:get_env(asobi_lua, reload_mode),
    application:set_env(asobi_lua, reload_mode, auto),
    try
        Dir = temp_dir(),
        Path = filename:join(Dir, "world.lua"),
        ok = file:write_file(Path, fixture_body("reload_world_v1.lua")),
        Cfg = #{
            world_id => ~"reload_probe",
            coords => {0, 0},
            game_module => asobi_lua_world,
            game_config => #{lua_script => list_to_binary(Path)},
            world_server_pid => self()
        },
        erlang:erase({asobi_lua_world, zone_state}),
        ZS0 = asobi_lua_world:init_zone_state(Cfg, #{}),

        %% v2 declares an extra `dragon` template and spawns it from
        %% zone_tick, on the very tick the reload lands.
        ok = file:write_file(Path, fixture_body("reload_world_v2.lua")),
        ZS0b = ZS0#{script_mtime => {{1970, 1, 1}, {0, 0, 0}}},
        {_Ents, ZS1} = asobi_lua_world:zone_tick(#{}, ZS0b),
        flush_casts(),

        ?assertMatch({changed, _}, asobi_lua_world:spawn_templates_hint(ZS1)),
        {changed, Templates} = asobi_lua_world:spawn_templates_hint(ZS1),
        ?assert(maps:is_key(~"dragon", Templates)),

        #{~"game_state" := GS} = asobi_lua_world:dump_zone_state(ZS1),
        ?assertEqual(true, maps:get(~"dragon_result", GS)),
        erlang:erase({asobi_lua_world, zone_state})
    after
        restore(reload_mode, OldEnv)
    end.

restore(Key, {ok, V}) -> application:set_env(asobi_lua, Key, V);
restore(Key, undefined) -> application:unset_env(asobi_lua, Key).

temp_dir() ->
    Base = filename:join([
        "/tmp",
        "asobi_lua_reload_zone_test",
        integer_to_list(erlang:unique_integer([positive]))
    ]),
    ok = filelib:ensure_dir(filename:join(Base, "x")),
    Base.

fixture_body(Name) ->
    {ok, Bin} = file:read_file(fixture(Name)),
    Bin.

unseeded_game_state_round_trips_as_nil() ->
    %% A zone snapshotted before its first seeding tick has game_state = nil.
    %% It must come back nil (null over jsonb), not an empty table, so the
    %% script's `game_state == nil` init guard still fires after recovery.
    ZoneState0 = asobi_lua_world:init_zone_state(zone_config(), #{}),
    ?assertEqual(nil, maps:get(game_state, ZoneState0)),
    Dumped = asobi_lua_world:dump_zone_state(ZoneState0),
    ?assertEqual(#{~"game_state" => null}, Dumped),
    _ = json:encode(Dumped),
    Restored = asobi_lua_world:init_zone_state(zone_config(), Dumped),
    ?assertEqual(nil, maps:get(game_state, Restored)).

dump_without_vm_is_jsonb_safe() ->
    %% When init_zone_state fails to build a VM it returns the bare zone_state
    %% (no lua_state); dumping that degraded zone must still be jsonb-safe.
    Raw = #{~"game_state" => #{~"hp" => 10}, ~"misc" => 1},
    Dumped = asobi_lua_world:dump_zone_state(Raw),
    ?assertNot(maps:is_key(lua_state, Dumped)),
    _ = json:encode(Dumped),
    ?assertEqual(Raw, Dumped).

by_type(Type, Entities) ->
    [E || {_Id, E} <- maps:to_list(Entities), maps:get(type, E, undefined) =:= Type].

flush_casts() ->
    receive
        _ -> flush_casts()
    after 0 -> ok
    end.
