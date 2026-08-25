-module(asobi_lua_world_tests).
-include_lib("eunit/include/eunit.hrl").
-include_lib("kernel/include/file.hrl").

%% logger handler callback for script_log_limiter_test_/0 below.
-export([log/2]).

-spec fixture(string()) -> file:filename_all().
fixture(Name) ->
    {ok, LibDir} = safe_lib_dir(),
    filename:absname(
        filename:join([LibDir, "test", "fixtures", "lua", Name])
    ).

-spec safe_lib_dir() -> {ok, string()}.
safe_lib_dir() ->
    case code:lib_dir(asobi) of
        {error, bad_name} -> error(asobi_not_loaded);
        Dir -> {ok, Dir}
    end.

generate_world_from_raw_config_test() ->
    %% asobi_world_server invokes generate_world/2 with the raw world config
    %% (no lua_state threaded through). The bridge must handle that by creating
    %% its own Lua state from game_config.lua_script.
    Config = #{
        mode => ~"test",
        game_config => #{lua_script => fixture("config_game_type_world.lua")}
    },
    {ok, ZoneStates} = asobi_lua_world:generate_world(0, Config),
    ?assert(is_map(ZoneStates)),
    %% The fixture declares one zone at "0,0"; the bridge parses it into a tuple.
    ?assert(maps:is_key({0, 0}, ZoneStates)),
    %% generate_world returns plain zone states; the per-zone VM is built later,
    %% in the zone process, via init_zone_state/2.
    Zone = maps:get({0, 0}, ZoneStates),
    ?assert(is_map(Zone)),
    ?assertNot(maps:is_key(lua_state, Zone)),
    Built = asobi_lua_world:init_zone_state(Config, Zone),
    ?assert(maps:is_key(lua_state, Built)).

generate_world_missing_script_returns_empty_test() ->
    Config = #{game_config => #{}},
    ?assertEqual({ok, #{}}, asobi_lua_world:generate_world(0, Config)).

generate_world_bad_script_returns_empty_test() ->
    Config = #{game_config => #{lua_script => "/nonexistent/path.lua"}},
    ?assertEqual({ok, #{}}, asobi_lua_world:generate_world(0, Config)).

handle_input_uses_zone_state_from_proc_dict_test() ->
    %% asobi_zone passes just the entities map to handle_input/3 (no lua_state).
    %% The bridge must recover lua_state from the zone's proc dict, which
    %% zone_tick populates. Verify the full flow end-to-end.
    Script = fixture("config_move_world.lua"),
    Config = #{game_config => #{lua_script => Script}},
    {ok, ZoneStates} = asobi_lua_world:generate_world(0, Config),
    ?assert(maps:is_key({0, 0}, ZoneStates)),
    %% The zone process builds the per-zone VM via init_zone_state before ticking.
    ZoneState = asobi_lua_world:init_zone_state(Config, maps:get({0, 0}, ZoneStates)),

    %% First zone_tick primes the proc dict.
    erlang:erase({asobi_lua_world, zone_state}),
    {_Ents, ZoneState1} = asobi_lua_world:zone_tick(#{}, ZoneState),
    ?assertMatch(#{lua_state := _}, erlang:get({asobi_lua_world, zone_state})),

    %% A move input should invoke Lua's handle_input and return updated entities.
    %% Entity keys come back atomized (x, y, type - not ~"x", ~"y", ~"type"):
    %% asobi_zone's shared tick path (find_zone_crossings, snapshot_entities,
    %% spatial grid maintenance, ...) pattern-matches
    %% #{type := ..., x := ..., y := ...} on every entity, and used to no-op
    %% or crash for every Lua world since decode_to_map/2 builds straight off
    %% Luerl's binary-keyed output. See widgrensit/asobi#270.
    Input = #{~"kind" => ~"move", ~"x" => 42, ~"y" => 7},
    {ok, Entities1} = asobi_lua_world:handle_input(~"p1", Input, #{}),
    ?assertMatch(#{~"p1" := #{type := ~"player", x := 42, y := 7}}, Entities1),

    %% Follow-up tick sees the handle_input lua_state changes (no crash).
    {_, _ZoneState2} = asobi_lua_world:zone_tick(Entities1, ZoneState1),
    erlang:erase({asobi_lua_world, zone_state}).

%% asobi#532: a script that batches several simulation steps into one frame
%% reports the seq it actually consumed as a second return value, and that
%% becomes the world.ack instead of the seq stamped on the frame.
handle_input_reports_consumed_seq_test() ->
    _ = prime_ack_zone(),
    ?assertEqual(
        {ok, #{~"p1" => #{type => ~"player", x => 1, y => 2}}, 42},
        asobi_lua_world:handle_input(
            ~"p1", #{~"x" => 1, ~"y" => 2, ~"consumed" => 42}, #{}
        )
    ),
    %% A fractional seq truncates rather than reaching the zone as a float:
    %% Lua has one number type and every integer arrives here as one.
    ?assertMatch(
        {ok, _, 7},
        asobi_lua_world:handle_input(~"p1", #{~"consumed" => 7.9}, #{})
    ),
    erlang:erase({asobi_lua_world, zone_state}).

%% No second return value is the ordinary case and must stay a 2-tuple, so
%% every script written before this existed keeps acking the frame stamp.
handle_input_without_consumed_seq_is_unchanged_test() ->
    _ = prime_ack_zone(),
    ?assertMatch(
        {ok, #{~"p1" := #{x := 3}}},
        asobi_lua_world:handle_input(~"p1", #{~"x" => 3}, #{})
    ),
    erlang:erase({asobi_lua_world, zone_state}).

%% A script returning something that is not a seq must not ack it: falling back
%% to the frame stamp is recoverable, acking garbage is not.
handle_input_invalid_consumed_seq_falls_back_test() ->
    _ = prime_ack_zone(),
    ?assertMatch(
        {ok, #{~"p1" := #{x := 4}}},
        asobi_lua_world:handle_input(~"p1", #{~"x" => 4, ~"consumed" => ~"nope"}, #{})
    ),
    ?assertMatch(
        {ok, #{~"p1" := #{x := 5}}},
        asobi_lua_world:handle_input(~"p1", #{~"x" => 5, ~"consumed" => -1}, #{})
    ),
    erlang:erase({asobi_lua_world, zone_state}).

%% A script whose handle_input falls off its end returns no values at all.
%% asobi_lua_loader:call/3 hands back {ok, [], St} for that, which used to be a
%% case_clause in the bridge - and the bridge runs inside the zone process, so
%% one author's missing return killed the simulation for every player in that
%% zone. Mirrors the same guard on the match side's `join`.
handle_input_returning_nothing_leaves_entities_alone_test() ->
    Config = #{game_config => #{lua_script => fixture("config_silent_input_world.lua")}},
    {ok, ZoneStates} = asobi_lua_world:generate_world(0, Config),
    ZoneState = asobi_lua_world:init_zone_state(Config, maps:get({0, 0}, ZoneStates)),
    erlang:erase({asobi_lua_world, zone_state}),
    {_, _} = asobi_lua_world:zone_tick(#{}, ZoneState),
    ?assertEqual(
        {ok, #{~"p1" => #{x => 1}}},
        asobi_lua_world:handle_input(~"p1", #{~"x" => 1}, #{~"p1" => #{x => 1}})
    ),
    erlang:erase({asobi_lua_world, zone_state}).

%% The second return value reaches the bridge AFTER asobi_lua_loader:call/3 has
%% returned, so nothing is guarding it and the zone process is what dies. Three
%% shapes a script can hand back, none of which may take the zone with them.
handle_input_hostile_returns_do_not_kill_the_zone_test() ->
    _ = prime_zone("config_hostile_input_world.lua"),
    %% luerl:decode/2 raises recursive_table on this; shape-guarding never
    %% decodes it at all.
    ?assertMatch(
        {ok, _},
        asobi_lua_world:handle_input(~"p1", #{~"kind" => ~"cyclic"}, #{~"p1" => #{x => 1}})
    ),
    %% trunc(1.0e308) is a 309-digit integer. The ack space is 53 bits, and the
    %% session keeps the highest seq it has sent, so acking one would silence
    %% that connection's ack stream for good.
    ?assertMatch(
        {ok, _},
        asobi_lua_world:handle_input(~"p1", #{~"kind" => ~"huge"}, #{~"p1" => #{x => 1}})
    ),
    %% A scalar first return reaches decode_to_map/2, which case_clauses on it.
    ?assertEqual(
        {ok, #{~"p1" => #{x => 1}}},
        asobi_lua_world:handle_input(~"p1", #{~"kind" => ~"scalar"}, #{~"p1" => #{x => 1}})
    ),
    erlang:erase({asobi_lua_world, zone_state}).

prime_zone(Fixture) ->
    Config = #{game_config => #{lua_script => fixture(Fixture)}},
    {ok, ZoneStates} = asobi_lua_world:generate_world(0, Config),
    ZoneState = asobi_lua_world:init_zone_state(Config, maps:get({0, 0}, ZoneStates)),
    erlang:erase({asobi_lua_world, zone_state}),
    {_, ZoneState1} = asobi_lua_world:zone_tick(#{}, ZoneState),
    ZoneState1.

prime_ack_zone() ->
    prime_zone("config_ack_world.lua").

handle_input_without_stash_is_noop_test() ->
    erlang:erase({asobi_lua_world, zone_state}),
    ?assertEqual(
        {ok, #{a => 1}},
        asobi_lua_world:handle_input(~"p1", #{~"kind" => ~"move"}, #{a => 1})
    ).

generate_world_empty_zone_table_still_gets_lua_state_test() ->
    Script = fixture("config_empty_zone_world.lua"),
    Config = #{game_config => #{lua_script => Script}},
    {ok, ZoneStates} = asobi_lua_world:generate_world(0, Config),
    ?assert(maps:is_key({0, 0}, ZoneStates)),
    Zone = asobi_lua_world:init_zone_state(Config, maps:get({0, 0}, ZoneStates)),
    ?assert(is_map(Zone)),
    ?assert(maps:is_key(lua_state, Zone)),

    erlang:erase({asobi_lua_world, zone_state}),
    {_, _} = asobi_lua_world:zone_tick(#{}, Zone),
    Input = #{~"kind" => ~"move", ~"x" => 11, ~"y" => 22},
    {ok, Entities1} = asobi_lua_world:handle_input(~"p1", Input, #{}),
    ?assertMatch(#{~"p1" := #{x := 11, y := 22}}, Entities1),
    erlang:erase({asobi_lua_world, zone_state}).

%% --- Direct unit tests for individual world callbacks ---

init_invokes_init_callback_test() ->
    %% asobi_lua_world:init/1 must call the Lua init() and stash both
    %% lua_state and game_state. A regression that drops game_state
    %% would surface as join/leave hitting nil.
    {ok, State} = asobi_lua_world:init(#{lua_script => fixture("config_move_world.lua")}),
    ?assertMatch(#{lua_state := _, game_state := _}, State).

join_callback_threads_state_test() ->
    {ok, S0} = asobi_lua_world:init(#{lua_script => fixture("config_move_world.lua")}),
    {ok, S1} = asobi_lua_world:join(~"p1", S0),
    ?assert(is_map(S1)).

leave_callback_returns_ok_test() ->
    {ok, S0} = asobi_lua_world:init(#{lua_script => fixture("config_move_world.lua")}),
    ?assertMatch({ok, _}, asobi_lua_world:leave(~"p1", S0)).

spawn_position_decodes_xy_test() ->
    {ok, S0} = asobi_lua_world:init(#{lua_script => fixture("config_move_world.lua")}),
    {ok, {X, Y}} = asobi_lua_world:spawn_position(~"p1", S0),
    ?assert(is_number(X)),
    ?assert(is_number(Y)).

post_tick_returns_ok_test() ->
    {ok, S0} = asobi_lua_world:init(#{lua_script => fixture("config_move_world.lua")}),
    ?assertMatch({ok, _}, asobi_lua_world:post_tick(1, S0)).

get_state_returns_view_test() ->
    {ok, S0} = asobi_lua_world:init(#{lua_script => fixture("config_move_world.lua")}),
    View = asobi_lua_world:get_state(~"p1", S0),
    ?assert(is_map(View)).

phases_returns_empty_when_undefined_test() ->
    %% A script without a phases() function must return [], not crash.
    {ok, S0} = asobi_lua_world:init(#{lua_script => fixture("config_move_world.lua")}),
    ?assertEqual([], asobi_lua_world:phases(S0)).

spawn_templates_returns_empty_when_undefined_test() ->
    {ok, S0} = asobi_lua_world:init(#{lua_script => fixture("config_move_world.lua")}),
    ?assertEqual(#{}, asobi_lua_world:spawn_templates(S0)).

terrain_provider_returns_none_when_undefined_test() ->
    {ok, S0} = asobi_lua_world:init(#{lua_script => fixture("config_move_world.lua")}),
    ?assertEqual(none, asobi_lua_world:terrain_provider(S0)).

terrain_provider_decodes_module_test() ->
    Path = world_temp_script(
        ~"""
        match_size = 1
        max_players = 1
        game_type = "world"
        function init(_) return {} end
        function spawn_position(_, _) return { x = 0, y = 0 } end
        function generate_world(_, _) return { ['0,0'] = {} } end
        function zone_tick(e, z) return e, z end
        function handle_input(_, _, e) return e end
        function post_tick(_, s) return s end
        function terrain_provider(_)
            return { module = 'erlang', args = { foo = 'bar' } }
        end
        """
    ),
    %% H-2: terrain provider modules must be on the allowlist. Add
    %% `erlang` for this round-trip test only.
    Old = application:get_env(asobi_lua, terrain_providers),
    application:set_env(asobi_lua, terrain_providers, [erlang]),
    try
        {ok, S0} = asobi_lua_world:init(#{lua_script => Path}),
        ?assertMatch({erlang, #{}}, asobi_lua_world:terrain_provider(S0))
    after
        case Old of
            {ok, V} -> application:set_env(asobi_lua, terrain_providers, V);
            undefined -> application:unset_env(asobi_lua, terrain_providers)
        end,
        file:delete(Path)
    end.

terrain_provider_unknown_module_returns_none_test() ->
    %% A bogus module name must NOT create a new atom, and the bridge
    %% returns `none` rather than crashing.
    Path = world_temp_script(
        ~"""
        match_size = 1
        max_players = 1
        game_type = "world"
        function init(_) return {} end
        function spawn_position(_, _) return { x = 0, y = 0 } end
        function generate_world(_, _) return { ['0,0'] = {} } end
        function zone_tick(e, z) return e, z end
        function handle_input(_, _, e) return e end
        function post_tick(_, s) return s end
        function terrain_provider(_)
            return { module = 'definitely_not_a_real_module_xyz', args = {} }
        end
        """
    ),
    try
        {ok, S0} = asobi_lua_world:init(#{lua_script => Path}),
        ?assertEqual(none, asobi_lua_world:terrain_provider(S0))
    after
        file:delete(Path)
    end.

phases_returns_decoded_phases_test() ->
    Path = world_temp_script(
        ~"""
        match_size = 1
        max_players = 1
        game_type = "world"
        function init(_) return {} end
        function spawn_position(_, _) return { x = 0, y = 0 } end
        function generate_world(_, _) return { ['0,0'] = {} } end
        function zone_tick(e, z) return e, z end
        function handle_input(_, _, e) return e end
        function post_tick(_, s) return s end
        function phases(_)
            return {
                { name = 'lobby', duration = 5000 },
                { name = 'play',  duration = 30000, start = 'prev_ended' }
            }
        end
        """
    ),
    try
        {ok, S0} = asobi_lua_world:init(#{lua_script => Path}),
        Phases = asobi_lua_world:phases(S0),
        ?assertEqual(2, length(Phases)),
        [Lobby, Play] = Phases,
        ?assertEqual(~"lobby", maps:get(name, Lobby)),
        ?assertEqual(prev_ended, maps:get(start, Play))
    after
        file:delete(Path)
    end.

phases_non_list_returns_empty_test() ->
    %% When phases() returns garbage, the bridge logs and returns [].
    Path = world_temp_script(
        ~"""
        match_size = 1
        max_players = 1
        game_type = "world"
        function init(_) return {} end
        function spawn_position(_, _) return { x = 0, y = 0 } end
        function generate_world(_, _) return { ['0,0'] = {} } end
        function zone_tick(e, z) return e, z end
        function handle_input(_, _, e) return e end
        function post_tick(_, s) return s end
        function phases(_) return 42 end
        """
    ),
    try
        {ok, S0} = asobi_lua_world:init(#{lua_script => Path}),
        ?assertEqual([], asobi_lua_world:phases(S0))
    after
        file:delete(Path)
    end.

spawn_templates_decodes_test() ->
    Path = world_temp_script(
        ~"""
        match_size = 1
        max_players = 1
        game_type = "world"
        function init(_) return {} end
        function spawn_position(_, _) return { x = 0, y = 0 } end
        function generate_world(_, _) return { ['0,0'] = {} } end
        function zone_tick(e, z) return e, z end
        function handle_input(_, _, e) return e end
        function post_tick(_, s) return s end
        function spawn_templates(_)
            return {
                goblin = { type = 'npc', persistent = true, base_state = { hp = 10 } }
            }
        end
        """
    ),
    try
        {ok, S0} = asobi_lua_world:init(#{lua_script => Path}),
        Templates = asobi_lua_world:spawn_templates(S0),
        ?assertMatch(#{~"goblin" := _}, Templates),
        Goblin = maps:get(~"goblin", Templates),
        ?assertEqual(~"npc", maps:get(type, Goblin)),
        ?assertEqual(true, maps:get(persistent, Goblin)),
        %% asobi_lua#118: base_state is merged straight into the spawned
        %% entity by asobi_zone_spawner, so its keys must already be in the
        %% atom shape asobi_zone reads - not binary until a later zone_tick
        %% round-trip fixes them up.
        ?assertEqual(#{hp => 10}, maps:get(base_state, Goblin))
    after
        file:delete(Path)
    end.

%% --- Raw-config regression tests (asobi#246) ---
%%
%% asobi_world_server calls spawn_templates/1 and terrain_provider/1 with the
%% RAW world config it holds (game_config nested inside, no lua_state - it
%% hasn't called GameMod:init/1 for this purpose), and calls phases/1 with the
%% game_config map directly, for the same reason. Every test above builds its
%% state via asobi_lua_world:init/1 first, which means every one of them
%% passed a #{lua_state := _} map - the ONE shape that was already correct.
%% None of them would have caught a callback silently no-op'ing on the real
%% shape asobi_world_server actually sends. These call the callbacks the way
%% asobi_world_server really does.

spawn_templates_from_raw_config_test() ->
    Path = world_temp_script(
        ~"""
        match_size = 1
        max_players = 1
        game_type = "world"
        function init(_) return {} end
        function spawn_position(_, _) return { x = 0, y = 0 } end
        function generate_world(_, _) return { ['0,0'] = {} } end
        function zone_tick(e, z) return e, z end
        function handle_input(_, _, e) return e end
        function post_tick(_, s) return s end
        function spawn_templates(_)
            return { goblin = { type = 'npc', persistent = true, base_state = { hp = 10 } } }
        end
        """
    ),
    try
        %% Mirrors asobi_world_server's own State#{config => Config} - the
        %% exact map get_spawn_templates/2 passes to GameMod:spawn_templates/1.
        RawConfig = #{
            world_id => ~"raw_probe",
            game_module => asobi_lua_world,
            game_config => #{lua_script => Path}
        },
        Templates = asobi_lua_world:spawn_templates(RawConfig),
        ?assertMatch(#{~"goblin" := _}, Templates),
        Goblin = maps:get(~"goblin", Templates),
        ?assertEqual(~"npc", maps:get(type, Goblin))
    after
        file:delete(Path)
    end.

spawn_templates_from_raw_config_missing_script_returns_empty_test() ->
    ?assertEqual(#{}, asobi_lua_world:spawn_templates(#{world_id => ~"raw_probe"})).

terrain_provider_from_raw_config_test() ->
    Path = world_temp_script(
        ~"""
        match_size = 1
        max_players = 1
        game_type = "world"
        function init(_) return {} end
        function spawn_position(_, _) return { x = 0, y = 0 } end
        function generate_world(_, _) return { ['0,0'] = {} } end
        function zone_tick(e, z) return e, z end
        function handle_input(_, _, e) return e end
        function post_tick(_, s) return s end
        function terrain_provider(_)
            return { module = 'erlang', args = { foo = 'bar' } }
        end
        """
    ),
    Old = application:get_env(asobi_lua, terrain_providers),
    application:set_env(asobi_lua, terrain_providers, [erlang]),
    try
        %% Mirrors asobi_world_server:start_terrain_store/2's GameMod:terrain_provider(Config).
        RawConfig = #{
            world_id => ~"raw_probe",
            game_module => asobi_lua_world,
            game_config => #{lua_script => Path}
        },
        ?assertMatch({erlang, #{}}, asobi_lua_world:terrain_provider(RawConfig))
    after
        case Old of
            {ok, V} -> application:set_env(asobi_lua, terrain_providers, V);
            undefined -> application:unset_env(asobi_lua, terrain_providers)
        end,
        file:delete(Path)
    end.

phases_from_raw_config_test() ->
    Path = world_temp_script(
        ~"""
        match_size = 1
        max_players = 1
        game_type = "world"
        function init(_) return {} end
        function spawn_position(_, _) return { x = 0, y = 0 } end
        function generate_world(_, _) return { ['0,0'] = {} } end
        function zone_tick(e, z) return e, z end
        function handle_input(_, _, e) return e end
        function post_tick(_, s) return s end
        function phases(_)
            return { { name = 'lobby', duration = 5000 } }
        end
        """
    ),
    try
        %% Mirrors asobi_world_server:init/1's GameMod:phases(GameConfig) -
        %% GameConfig has lua_script at its top level, no nested game_config.
        GameConfig = #{lua_script => Path, match_id => ~"raw_probe"},
        Phases = asobi_lua_world:phases(GameConfig),
        ?assertEqual(1, length(Phases)),
        [Lobby] = Phases,
        ?assertEqual(~"lobby", maps:get(name, Lobby))
    after
        file:delete(Path)
    end.

%% Security review on widgrensit/asobi_lua#109/#117: every raw-config clause
%% above (spawn_templates/1, terrain_provider/1, phases/1, generate_world/2)
%% boots a throwaway Lua VM via boot_throwaway_lua_state/2, which means the
%% script's whole top-level body runs again. Before the `probe => true` /
%% install_pure fix, a top-level `game.economy.grant` call fired once per
%% throwaway boot - so asking phases/1 twice would grant twice, with no
%% idempotency key on that primitive. This pins that a probe boot never
%% reaches asobi_economy at all, no matter how many times it is asked.
probe_vm_suppresses_top_level_side_effects_test() ->
    meck:new(asobi_economy, [no_link]),
    meck:expect(asobi_economy, grant, fun(_, _, _, _) -> {ok, #{}} end),
    Path = world_temp_script(
        ~"""
        match_size = 1
        max_players = 1
        game_type = "world"
        game.economy.grant('p1', 'gold', 100, 'signup')
        function init(_) return {} end
        function spawn_position(_, _) return { x = 0, y = 0 } end
        function generate_world(_, _) return { ['0,0'] = {} } end
        function zone_tick(e, z) return e, z end
        function handle_input(_, _, e) return e end
        function post_tick(_, s) return s end
        function phases(_)
            return { { name = 'lobby', duration = 5000 } }
        end
        """
    ),
    try
        GameConfig = #{lua_script => Path, match_id => ~"world_probe_dedupe"},
        Phases1 = asobi_lua_world:phases(GameConfig),
        Phases2 = asobi_lua_world:phases(GameConfig),
        ?assertEqual(1, length(Phases1)),
        ?assertEqual(1, length(Phases2)),
        ?assertEqual(0, meck:num_calls(asobi_economy, grant, '_'))
    after
        file:delete(Path),
        meck:unload(asobi_economy)
    end.

on_phase_started_threads_state_test() ->
    Path = world_temp_script(
        ~"""
        match_size = 1
        max_players = 1
        game_type = "world"
        function init(_) return { phase = nil } end
        function spawn_position(_, _) return { x = 0, y = 0 } end
        function generate_world(_, _) return { ['0,0'] = {} } end
        function zone_tick(e, z) return e, z end
        function handle_input(_, _, e) return e end
        function post_tick(_, s) return s end
        function on_phase_started(name, s) s.phase = name; return s end
        """
    ),
    try
        {ok, S0} = asobi_lua_world:init(#{lua_script => Path}),
        ?assertMatch({ok, _}, asobi_lua_world:on_phase_started(~"play", S0))
    after
        file:delete(Path)
    end.

on_phase_ended_threads_state_test() ->
    Path = world_temp_script(
        ~"""
        match_size = 1
        max_players = 1
        game_type = "world"
        function init(_) return {} end
        function spawn_position(_, _) return { x = 0, y = 0 } end
        function generate_world(_, _) return { ['0,0'] = {} } end
        function zone_tick(e, z) return e, z end
        function handle_input(_, _, e) return e end
        function post_tick(_, s) return s end
        function on_phase_ended(_, s) return s end
        """
    ),
    try
        {ok, S0} = asobi_lua_world:init(#{lua_script => Path}),
        ?assertMatch({ok, _}, asobi_lua_world:on_phase_ended(~"play", S0))
    after
        file:delete(Path)
    end.

on_zone_loaded_returns_zone_state_test() ->
    Path = world_temp_script(
        ~"""
        match_size = 1
        max_players = 1
        game_type = "world"
        function init(_) return {} end
        function spawn_position(_, _) return { x = 0, y = 0 } end
        function generate_world(_, _) return { ['0,0'] = {} } end
        function zone_tick(e, z) return e, z end
        function handle_input(_, _, e) return e end
        function post_tick(_, s) return s end
        function on_zone_loaded(cx, cy, s) return { cx = cx, cy = cy }, s end
        """
    ),
    try
        {ok, S0} = asobi_lua_world:init(#{lua_script => Path}),
        {ok, ZoneState, _S1} = asobi_lua_world:on_zone_loaded({3, 4}, S0),
        ?assertEqual(3, maps:get(~"cx", ZoneState)),
        ?assertEqual(4, maps:get(~"cy", ZoneState))
    after
        file:delete(Path)
    end.

on_zone_unloaded_returns_ok_test() ->
    Path = world_temp_script(
        ~"""
        match_size = 1
        max_players = 1
        game_type = "world"
        function init(_) return {} end
        function spawn_position(_, _) return { x = 0, y = 0 } end
        function generate_world(_, _) return { ['0,0'] = {} } end
        function zone_tick(e, z) return e, z end
        function handle_input(_, _, e) return e end
        function post_tick(_, s) return s end
        function on_zone_unloaded(_, _, s) return s end
        """
    ),
    try
        {ok, S0} = asobi_lua_world:init(#{lua_script => Path}),
        ?assertMatch({ok, _}, asobi_lua_world:on_zone_unloaded({1, 1}, S0))
    after
        file:delete(Path)
    end.

on_world_recovered_threads_state_test() ->
    Path = world_temp_script(
        ~"""
        match_size = 1
        max_players = 1
        game_type = "world"
        function init(_) return { recovered = false } end
        function spawn_position(_, _) return { x = 0, y = 0 } end
        function generate_world(_, _) return { ['0,0'] = {} } end
        function zone_tick(e, z) return e, z end
        function handle_input(_, _, e) return e end
        function post_tick(_, s) return s end
        function on_world_recovered(_, s) s.recovered = true; return s end
        """
    ),
    try
        {ok, S0} = asobi_lua_world:init(#{lua_script => Path}),
        ?assertMatch({ok, _}, asobi_lua_world:on_world_recovered(#{~"snap" => ~"data"}, S0))
    after
        file:delete(Path)
    end.

%% --- Hot reload tests ---

hot_reload_post_tick_picks_up_global_change_test() ->
    %% Edit a top-level global, tick post_tick, observe the new value via
    %% get_state. World-level state holds the script + mtime; the reload runs
    %% at the start of post_tick.
    Path = world_temp_script(
        ~"""
        match_size = 1
        max_players = 1
        game_type = "world"
        tag = "before"
        function init(_) return {} end
        function spawn_position(_, _) return { x = 0, y = 0 } end
        function generate_world(_, _) return { ['0,0'] = {} } end
        function zone_tick(e, z) return e, z end
        function handle_input(_, _, e) return e end
        function post_tick(_, s) return s end
        function get_state(_, _) return { tag = tag } end
        """
    ),
    try
        {ok, S0} = asobi_lua_world:init(#{lua_script => Path}),
        #{~"tag" := BeforeTag} = asobi_lua_world:get_state(~"p1", S0),
        ?assertEqual(~"before", BeforeTag),

        ok = file:write_file(
            Path,
            ~"""
            match_size = 1
            max_players = 1
            game_type = "world"
            tag = "after"
            function init(_) return {} end
            function spawn_position(_, _) return { x = 0, y = 0 } end
            function generate_world(_, _) return { ['0,0'] = {} } end
            function zone_tick(e, z) return e, z end
            function handle_input(_, _, e) return e end
            function post_tick(_, s) return s end
            function get_state(_, _) return { tag = tag } end
            """
        ),
        bump_mtime(Path),

        {ok, S1} = asobi_lua_world:post_tick(1, S0),
        #{~"tag" := AfterTag} = asobi_lua_world:get_state(~"p1", S1),
        ?assertEqual(~"after", AfterTag)
    after
        file:delete(Path)
    end.

hot_reload_post_tick_survives_syntax_error_test() ->
    %% A broken reload must not crash post_tick or wipe state. The world
    %% keeps running on the previous (good) script, and the new mtime is
    %% remembered so we don't re-attempt the same broken file.
    Path = world_temp_script(
        ~"""
        match_size = 1
        max_players = 1
        game_type = "world"
        tag = "good"
        function init(_) return {} end
        function spawn_position(_, _) return { x = 0, y = 0 } end
        function generate_world(_, _) return { ['0,0'] = {} } end
        function zone_tick(e, z) return e, z end
        function handle_input(_, _, e) return e end
        function post_tick(_, s) return s end
        function get_state(_, _) return { tag = tag } end
        """
    ),
    try
        {ok, S0} = asobi_lua_world:init(#{lua_script => Path}),

        ok = file:write_file(Path, ~"tag = \"broken\"  !!this is not lua"),
        bump_mtime(Path),

        {ok, S1} = asobi_lua_world:post_tick(1, S0),
        #{~"tag" := Tag} = asobi_lua_world:get_state(~"p1", S1),
        ?assertEqual(~"good", Tag)
    after
        file:delete(Path)
    end.

hot_reload_zone_tick_picks_up_global_change_test() ->
    %% asobi#543 throttles the mtime stat to once per
    %% `reload_poll_interval_ms`, and this test writes v2 and ticks again
    %% inside that window. 0 is the documented "poll every call" setting; the
    %% throttle itself is covered in asobi_lua_reload_tests.
    with_every_tick_polling(fun hot_reload_zone_tick_picks_up_global_change_test_body/0).

hot_reload_zone_tick_picks_up_global_change_test_body() ->
    %% Per-zone reload: each zone holds its own lua_state + script + mtime,
    %% and zone_tick checks the file at the start of every tick. We observe
    %% the reload by having zone_tick stamp a global value into the entities
    %% map (which the bridge decodes on return).
    Path = world_temp_script(
        ~"""
        zone_tag = "before"
        function init(_) return {} end
        function spawn_position(_, _) return { x = 0, y = 0 } end
        function generate_world(_, _) return { ['0,0'] = {} } end
        function zone_tick(e, z)
            e["marker"] = { tag = zone_tag }
            return e, z
        end
        function handle_input(_, _, e) return e end
        function post_tick(_, s) return s end
        """
    ),
    try
        Config = #{game_config => #{lua_script => Path}, mode => ~"test"},
        {ok, ZoneStates} = asobi_lua_world:generate_world(0, Config),
        Zone0 = asobi_lua_world:init_zone_state(Config, maps:get({0, 0}, ZoneStates)),
        erlang:erase({asobi_lua_world, zone_state}),
        {Ents0, Zone1} = asobi_lua_world:zone_tick(#{}, Zone0),
        ?assertMatch(#{~"marker" := #{tag := ~"before"}}, Ents0),

        ok = file:write_file(
            Path,
            ~"""
            zone_tag = "after"
            function init(_) return {} end
            function spawn_position(_, _) return { x = 0, y = 0 } end
            function generate_world(_, _) return { ['0,0'] = {} } end
            function zone_tick(e, z)
                e["marker"] = { tag = zone_tag }
                return e, z
            end
            function handle_input(_, _, e) return e end
            function post_tick(_, s) return s end
            """
        ),
        bump_mtime(Path),

        {Ents1, _Zone2} = asobi_lua_world:zone_tick(#{}, Zone1),
        ?assertMatch(#{~"marker" := #{tag := ~"after"}}, Ents1)
    after
        erlang:erase({asobi_lua_world, zone_state}),
        file:delete(Path)
    end.

hot_reload_zone_tick_survives_syntax_error_test() ->
    Path = world_temp_script(
        ~"""
        zone_tag = "good"
        function init(_) return {} end
        function spawn_position(_, _) return { x = 0, y = 0 } end
        function generate_world(_, _) return { ['0,0'] = {} } end
        function zone_tick(e, z)
            e["marker"] = { tag = zone_tag }
            return e, z
        end
        function handle_input(_, _, e) return e end
        function post_tick(_, s) return s end
        """
    ),
    try
        Config = #{game_config => #{lua_script => Path}, mode => ~"test"},
        {ok, ZoneStates} = asobi_lua_world:generate_world(0, Config),
        Zone0 = asobi_lua_world:init_zone_state(Config, maps:get({0, 0}, ZoneStates)),
        erlang:erase({asobi_lua_world, zone_state}),
        {_E0, Zone1} = asobi_lua_world:zone_tick(#{}, Zone0),

        ok = file:write_file(Path, ~"zone_tag = \"broken\"  !!this is not lua"),
        bump_mtime(Path),

        {Ents1, _Zone2} = asobi_lua_world:zone_tick(#{}, Zone1),
        %% The old code still runs, so the marker still says "good".
        ?assertMatch(#{~"marker" := #{tag := ~"good"}}, Ents1)
    after
        erlang:erase({asobi_lua_world, zone_state}),
        file:delete(Path)
    end.

hot_reload_zone_tick_signals_spawn_templates_hint_test() ->
    %% asobi#543 throttles the mtime stat to once per
    %% `reload_poll_interval_ms`, and this test writes v2 and ticks again
    %% inside that window. 0 is the documented "poll every call" setting; the
    %% throttle itself is covered in asobi_lua_reload_tests.
    with_every_tick_polling(fun hot_reload_zone_tick_signals_spawn_templates_hint_test_body/0).

hot_reload_zone_tick_signals_spawn_templates_hint_test_body() ->
    %% asobi#253: a script edited on disk can add spawn templates that
    %% weren't present when the zone was created. spawn_templates_hint/1
    %% is how asobi_zone finds out, without polling every tick itself.
    Path = world_temp_script(
        ~"""
        function init(_) return {} end
        function spawn_position(_, _) return { x = 0, y = 0 } end
        function generate_world(_, _) return { ['0,0'] = {} } end
        function zone_tick(e, z) return e, z end
        function handle_input(_, _, e) return e end
        function post_tick(_, s) return s end
        function spawn_templates(_) return { goblin = { max_count = 3 } } end
        """
    ),
    try
        Config = #{game_config => #{lua_script => Path}, mode => ~"test"},
        {ok, ZoneStates} = asobi_lua_world:generate_world(0, Config),
        Zone0 = asobi_lua_world:init_zone_state(Config, maps:get({0, 0}, ZoneStates)),
        erlang:erase({asobi_lua_world, zone_state}),
        {_Ents0, Zone1} = asobi_lua_world:zone_tick(#{}, Zone0),
        ?assertEqual(unchanged, asobi_lua_world:spawn_templates_hint(Zone1)),

        ok = file:write_file(
            Path,
            ~"""
            function init(_) return {} end
            function spawn_position(_, _) return { x = 0, y = 0 } end
            function generate_world(_, _) return { ['0,0'] = {} } end
            function zone_tick(e, z) return e, z end
            function handle_input(_, _, e) return e end
            function post_tick(_, s) return s end
            function spawn_templates(_)
                return { goblin = { max_count = 3 }, dragon = { max_count = 1 } }
            end
            """
        ),
        bump_mtime(Path),

        {_Ents1, Zone2} = asobi_lua_world:zone_tick(#{}, Zone1),
        ?assertMatch(
            {changed, #{~"goblin" := _, ~"dragon" := _}},
            asobi_lua_world:spawn_templates_hint(Zone2)
        ),

        %% The signal is one-tick only - it must not leak into the next tick.
        {_Ents2, Zone3} = asobi_lua_world:zone_tick(#{}, Zone2),
        ?assertEqual(unchanged, asobi_lua_world:spawn_templates_hint(Zone3))
    after
        erlang:erase({asobi_lua_world, zone_state}),
        file:delete(Path)
    end.

hot_reload_broken_spawn_templates_does_not_wipe_hint_test() ->
    %% asobi#253 F1: a hot-edit that breaks spawn_templates must not report
    %% {changed, #{}} - that would tell asobi_zone to replace the zone's
    %% whole live template set with nothing, wiping every spawnable
    %% template out of an already-running zone over one bad edit.
    Path = world_temp_script(
        ~"""
        function init(_) return {} end
        function spawn_position(_, _) return { x = 0, y = 0 } end
        function generate_world(_, _) return { ['0,0'] = {} } end
        function zone_tick(e, z) return e, z end
        function handle_input(_, _, e) return e end
        function post_tick(_, s) return s end
        function spawn_templates(_) return { goblin = { max_count = 3 } } end
        """
    ),
    try
        Config = #{game_config => #{lua_script => Path}, mode => ~"test"},
        {ok, ZoneStates} = asobi_lua_world:generate_world(0, Config),
        Zone0 = asobi_lua_world:init_zone_state(Config, maps:get({0, 0}, ZoneStates)),
        erlang:erase({asobi_lua_world, zone_state}),
        {_Ents0, Zone1} = asobi_lua_world:zone_tick(#{}, Zone0),

        ok = file:write_file(
            Path,
            ~"""
            function init(_) return {} end
            function spawn_position(_, _) return { x = 0, y = 0 } end
            function generate_world(_, _) return { ['0,0'] = {} } end
            function zone_tick(e, z) return e, z end
            function handle_input(_, _, e) return e end
            function post_tick(_, s) return s end
            function spawn_templates(_) error("boom") end
            """
        ),
        bump_mtime(Path),

        {_Ents1, Zone2} = asobi_lua_world:zone_tick(#{}, Zone1),
        ?assertEqual(unchanged, asobi_lua_world:spawn_templates_hint(Zone2))
    after
        erlang:erase({asobi_lua_world, zone_state}),
        file:delete(Path)
    end.

%% --- Script-error log rate limiting (asobi#252) ---
%%
%% log_lua_error/3 gates its ?LOG_WARNING behind asobi_script_log_limiter,
%% keyed on {Script, Callback} - a script that fails on every tick must not
%% flood the logs. The limiter's own rate math is covered on the asobi side
%% (asobi_script_log_limiter_tests); these pin the wiring here: the right key
%% is queried, a deny actually suppresses the log line (not just the count),
%% and an allow lets it through.

script_log_limiter_test_() ->
    {foreach, fun log_limiter_setup/0, fun log_limiter_cleanup/1, [
        {"a denied key is suppressed, not logged per call", fun script_log_suppressed_on_deny/0},
        {"an allowed call is logged with the {script, callback} key intact",
            fun script_log_allowed_key_shape/0}
    ]}.

log_limiter_setup() ->
    OldPrimary = logger:get_primary_config(),
    ok = logger:set_primary_config(level, all),
    ok = logger:add_handler(?MODULE, ?MODULE, #{config => undefined, level => all}),
    meck:new(seki, [no_link, passthrough]),
    OldPrimary.

log_limiter_cleanup(OldPrimary) ->
    _ = logger:remove_handler(?MODULE),
    ok = logger:set_primary_config(OldPrimary),
    meck:unload(seki).

%% eunit runs each foreach test in its own process, so the receiving pid
%% must be attached per-test, not captured in setup.
attach_log() ->
    ok = logger:set_handler_config(?MODULE, config, self()).

log(#{level := Level, msg := {report, Report}}, #{config := Pid}) ->
    Pid ! {lua_world_log, Level, Report};
log(_, _) ->
    ok.

script_log_suppressed_on_deny() ->
    attach_log(),
    meck:expect(seki, check, fun(asobi_script_log_limiter, _Key) -> {deny, 0} end),
    Config = #{game_config => #{lua_script => "/nonexistent/path.lua"}},
    ?assertEqual({ok, #{}}, asobi_lua_world:generate_world(0, Config)),
    ?assertEqual({ok, #{}}, asobi_lua_world:generate_world(0, Config)),
    ?assertEqual({ok, #{}}, asobi_lua_world:generate_world(0, Config)),
    receive
        {lua_world_log, warning, _} -> error(unexpected_log_line_while_denied)
    after 50 -> ok
    end,
    ?assertEqual(3, meck:num_calls(seki, check, [asobi_script_log_limiter, '_'])).

script_log_allowed_key_shape() ->
    attach_log(),
    meck:expect(seki, check, fun
        (asobi_script_log_limiter, {"/nonexistent/path.lua", generate_world}) -> {allow, 1};
        (asobi_script_log_limiter, Other) -> error({unexpected_key, Other})
    end),
    Config = #{game_config => #{lua_script => "/nonexistent/path.lua"}},
    ?assertEqual({ok, #{}}, asobi_lua_world:generate_world(0, Config)),
    receive
        {lua_world_log, warning, Report} ->
            ?assertEqual(generate_world, maps:get(callback, Report))
    after 1000 -> error(no_log_received)
    end.

%% --- Helpers ---

%% --- Regression: `game.*` API must be reachable from every callback ---
%%
%% Lua closures capture `_ENV` at compile time. If `asobi_lua_api:install/2`
%% runs AFTER the script chunk is evaluated, functions the script defined
%% see a `_G` that doesn't include the `game` namespace. The asymmetry
%% bites `handle_input` hardest because it uses `call/3` (no bounded_eval
%% round-trip) — see ADR 0002. These tests fail loudly if any callback
%% ever loses access to `game.*` again.

%% game_state is held as a luerl tref; decode it for assertions.
decoded_game_state(#{lua_state := LuaSt, game_state := GS}) ->
    asobi_lua_api:decode_to_map(GS, LuaSt).

game_namespace_visible_in_init_test() ->
    {ok, State} = asobi_lua_world:init(#{lua_script => fixture("game_api_world.lua")}),
    GS = decoded_game_state(State),
    ?assertEqual(true, maps:get(~"init_saw_game", GS, false)).

game_namespace_visible_in_join_leave_test() ->
    {ok, S0} = asobi_lua_world:init(#{lua_script => fixture("game_api_world.lua")}),
    {ok, S1} = asobi_lua_world:join(~"p1", S0),
    ?assertEqual(true, maps:get(~"join_saw_game", decoded_game_state(S1), false)),
    {ok, S2} = asobi_lua_world:leave(~"p1", S1),
    ?assertEqual(true, maps:get(~"leave_saw_game", decoded_game_state(S2), false)).

game_namespace_visible_in_post_tick_test() ->
    {ok, S0} = asobi_lua_world:init(#{lua_script => fixture("game_api_world.lua")}),
    {ok, S1} = asobi_lua_world:post_tick(1, S0),
    ?assertEqual(true, maps:get(~"post_tick_saw_game", decoded_game_state(S1), false)).

game_namespace_visible_in_zone_tick_and_handle_input_test() ->
    %% This is the regression case: install must happen BEFORE the script
    %% chunk is evaluated so handle_input's closure can see game.*. zone_tick
    %% comes along for the ride because it shares the same per-zone state.
    Script = fixture("game_api_world.lua"),
    Config = #{game_config => #{lua_script => Script}},
    {ok, ZoneStates} = asobi_lua_world:generate_world(0, Config),
    ZoneState = asobi_lua_world:init_zone_state(Config, maps:get({0, 0}, ZoneStates)),

    erlang:erase({asobi_lua_world, zone_state}),
    {_Ents, ZoneState1} = asobi_lua_world:zone_tick(#{}, ZoneState),
    %% ZoneState1.game_state holds the script's zone_state luerl tref;
    %% decode it to inspect the flag.
    ZoneTickGS = asobi_lua_api:decode_to_map(
        maps:get(game_state, ZoneState1), maps:get(lua_state, ZoneState1)
    ),
    ?assertEqual(true, maps:get(~"zone_tick_saw_game", ZoneTickGS, false)),

    {ok, Entities1} = asobi_lua_world:handle_input(
        ~"p1", #{~"kind" => ~"probe"}, #{}
    ),
    PE = maps:get(~"p1", Entities1),
    ?assertEqual(true, maps:get(~"handle_input_saw_game", PE, false)),
    ?assertEqual(true, maps:get(~"game_id_callable", PE, false)),
    erlang:erase({asobi_lua_world, zone_state}).

-spec world_temp_script(binary()) -> file:filename_all().
world_temp_script(Code) ->
    Name = "world_" ++ integer_to_list(erlang:unique_integer([positive])) ++ ".lua",
    Path = filename:join([filename:basedir(user_cache, "asobi_lua_tests"), Name]),
    ok = filelib:ensure_dir(Path),
    ok = file:write_file(Path, Code),
    Path.

-spec bump_mtime(file:filename_all()) -> ok.
bump_mtime(Path) ->
    %% filelib:last_modified/1 has 1-second resolution on POSIX, and
    %% file:write_file updates mtime to the current second which can equal
    %% the init-time mtime. Nudge mtime forward by 2 seconds so the reload
    %% check fires deterministically.
    {ok, FI} = file:read_file_info(Path, [{time, local}]),
    {{Y, M, D}, {H, Mi, S}} = FI#file_info.mtime,
    NewMtime = calendar:gregorian_seconds_to_datetime(
        calendar:datetime_to_gregorian_seconds({{Y, M, D}, {H, Mi, S}}) + 2
    ),
    ok = file:write_file_info(Path, FI#file_info{mtime = NewMtime}).

%% asobi#536: `[asobi, lua, state]` is one series per bridge process, so
%% without an identity every zone in a world reports under the same label set.
%% The world and the zone read differently-shaped config maps - which is how
%% the world one shipped reading a key that is never present - so assert the
%% stamping at each call site against the map its real caller passes.
bridge_identity_test_() ->
    [
        {"a world bridge stamps its world id", fun world_bridge_identity/0},
        {"a zone bridge stamps its world id and coords", fun zone_bridge_identity/0}
    ].

%% Exactly what asobi_world_server:init/1 hands GameMod:init/1: the game
%% config with match_id injected, and no nested game_config key.
world_bridge_identity() ->
    Config = #{lua_script => fixture("gc_zone.lua"), match_id => ~"world-42"},
    {ok, State} = asobi_lua_world:init(Config),
    ?assertEqual(#{kind => world, world_id => ~"world-42"}, maps:get(lua_bridge, State)).

%% The zone one does nest game_config - see asobi_zone's init_zone_state
%% continue clause.
zone_bridge_identity() ->
    ZoneConfig = #{
        world_id => ~"w1",
        coords => {2, 3},
        game_module => asobi_lua_world,
        game_config => #{lua_script => fixture("gc_zone.lua")}
    },
    ZoneState = asobi_lua_world:init_zone_state(ZoneConfig, #{}),
    ?assertEqual(
        #{kind => zone, world_id => ~"w1", coords => {2, 3}},
        maps:get(lua_bridge, ZoneState)
    ).

%% widgrensit/asobi#544: cross-zone effects reach the script batched, and the
%% map it returns is what the zone keeps.
handle_effects_applies_events_test() ->
    Script = fixture("effects_world.lua"),
    Config = #{game_config => #{lua_script => Script}},
    ZoneState = asobi_lua_world:init_zone_state(Config, #{}),
    erlang:erase({asobi_lua_world, zone_state}),
    Entities = #{~"npc" => #{type => ~"npc", x => 1.0, y => 1.0, hp => 100}},
    {_, _} = asobi_lua_world:zone_tick(Entities, ZoneState),
    {ok, Out} = asobi_lua_world:handle_effects(
        [{~"npc", #{~"hp_delta" => -30}}, {~"npc", #{~"hp_delta" => -5}}], Entities
    ),
    ?assertMatch(#{~"npc" := #{hp := 65}}, Out),
    erlang:erase({asobi_lua_world, zone_state}).

%% A script with no handle_effects must not be reported as a crashing one, and
%% must leave the entities exactly as they were.
handle_effects_without_a_handler_is_a_noop_test() ->
    Script = fixture("config_move_world.lua"),
    Config = #{game_config => #{lua_script => Script}},
    {ok, ZoneStates} = asobi_lua_world:generate_world(0, Config),
    ZoneState = asobi_lua_world:init_zone_state(Config, maps:get({0, 0}, ZoneStates)),
    erlang:erase({asobi_lua_world, zone_state}),
    {_, _} = asobi_lua_world:zone_tick(#{}, ZoneState),
    Entities = #{~"npc" => #{type => ~"npc", x => 1.0, y => 1.0, hp => 100}},
    ?assertEqual({ok, Entities}, asobi_lua_world:handle_effects([{~"npc", #{}}], Entities)),
    erlang:erase({asobi_lua_world, zone_state}).

%% No zone_tick has run, so there is no stashed lua_state: the bridge must hand
%% the entities straight back rather than crash the zone.
handle_effects_without_a_bridge_state_test() ->
    erlang:erase({asobi_lua_world, zone_state}),
    Entities = #{~"npc" => #{type => ~"npc"}},
    ?assertEqual({ok, Entities}, asobi_lua_world:handle_effects([{~"npc", #{}}], Entities)).

with_every_tick_polling(Fun) ->
    Old = application:get_env(asobi_lua, reload_poll_interval_ms),
    application:set_env(asobi_lua, reload_poll_interval_ms, 0),
    try
        Fun()
    after
        case Old of
            {ok, V} -> application:set_env(asobi_lua, reload_poll_interval_ms, V);
            undefined -> application:unset_env(asobi_lua, reload_poll_interval_ms)
        end
    end.

%% widgrensit/asobi#543 follow-up: a script counting down between waves holds no
%% entities, so asobi's own bookkeeping calls the zone idle and demotes it to a
%% tenth of the tick rate. The third return value from `zone_tick` is how the
%% script says otherwise - a returned value rather than a field, because reading
%% a field is a Luerl read that can run an `__index` metamethod on the zone
%% process with no budget.
third_return_value_vetoes_demotion_test() ->
    Script = fixture("keep_hot_world.lua"),
    Config = #{game_config => #{lua_script => Script}},
    ZoneState = asobi_lua_world:init_zone_state(Config, #{}),
    erlang:erase({asobi_lua_world, zone_state}),
    %% next_wave: 3 -> 2 -> 1 -> 0, so the veto holds for two ticks and lifts.
    {_, ZS1, Busy1} = asobi_lua_world:zone_tick(#{}, ZoneState),
    ?assert(Busy1),
    {_, ZS2, Busy2} = asobi_lua_world:zone_tick(#{}, ZS1),
    ?assert(Busy2),
    ?assertMatch({_, _, false}, asobi_lua_world:zone_tick(#{}, ZS2)),
    erlang:erase({asobi_lua_world, zone_state}).

%% A script returning two values gets the two-tuple it always did.
two_return_values_stay_a_two_tuple_test() ->
    Script = fixture("config_move_world.lua"),
    Config = #{game_config => #{lua_script => Script}},
    {ok, ZoneStates} = asobi_lua_world:generate_world(0, Config),
    ZoneState = asobi_lua_world:init_zone_state(Config, maps:get({0, 0}, ZoneStates)),
    erlang:erase({asobi_lua_world, zone_state}),
    ?assertMatch({_, _}, asobi_lua_world:zone_tick(#{}, ZoneState)),
    erlang:erase({asobi_lua_world, zone_state}).

%% Lua truthiness, not Erlang's: a countdown returning a number is the natural
%% thing to write, and `_keep_hot = 1` reading as "not busy" was the silent
%% failure this replaced.
lua_truthiness_decides_busy_test() ->
    Script = fixture("truthy_busy_world.lua"),
    Config = #{game_config => #{lua_script => Script}},
    ZoneState = asobi_lua_world:init_zone_state(Config, #{}),
    erlang:erase({asobi_lua_world, zone_state}),
    ?assertMatch({_, _, true}, asobi_lua_world:zone_tick(#{}, ZoneState)),
    erlang:erase({asobi_lua_world, zone_state}).

%% The bug this design removes: a zone_state carrying an __index metamethod used
%% to run that metamethod inline on the zone process, unbudgeted, because the
%% veto was read as an absent table key. A returned value reads nothing.
hostile_metatable_cannot_run_on_the_zone_test() ->
    Script = fixture("metatable_zone_state.lua"),
    Config = #{game_config => #{lua_script => Script}},
    ZoneState = asobi_lua_world:init_zone_state(Config, #{}),
    erlang:erase({asobi_lua_world, zone_state}),
    {Us, Result} = timer:tc(fun() -> asobi_lua_world:zone_tick(#{}, ZoneState) end),
    %% Two-tuple: the script returned no third value, and asobi read no key off
    %% the zone state to find one out.
    ?assertMatch({_, _}, Result),
    %% The metamethod burns ~2e6 iterations if anything invokes it.
    ?assert(Us < 200_000),
    erlang:erase({asobi_lua_world, zone_state}).

%% widgrensit/asobi#557: a script that says what it changed lets the bridge
%% skip decoding the whole entities table, and asobi merges the declaration
%% onto the map it handed in - so untouched entities stay the same terms.
zone_tick_dirty_declaration_test() ->
    Script = fixture("dirty_world.lua"),
    Config = #{game_config => #{lua_script => Script}},
    {ok, ZoneStates} = asobi_lua_world:generate_world(0, Config),
    ZoneState = asobi_lua_world:init_zone_state(Config, maps:get({0, 0}, ZoneStates)),
    Entities = #{
        ~"a" => #{type => ~"npc", x => 1.0, y => 1.0},
        ~"b" => #{type => ~"npc", x => 2.0, y => 2.0},
        ~"c" => #{type => ~"npc", x => 3.0, y => 3.0}
    },
    {Base, _ZS, false, Dirty} = asobi_lua_world:zone_tick(Entities, ZoneState),
    %% The bridge passes the INPUT map straight back rather than a decode of
    %% what the script returned. That is what preserves sharing.
    ?assertEqual(Entities, Base),
    ?assertMatch(#{changed := #{~"a" := #{x := 11.0}}, removed := [~"c"]}, Dirty),
    #{changed := Changed} = Dirty,
    %% "b" was mutated by the script but not declared, so it is not changed.
    ?assertNot(maps:is_key(~"b", Changed)),
    ?assertEqual(1, map_size(Changed)).

%% A script that returns three values (or two) keeps the old contract: the
%% whole table is decoded and there is no fourth element.
%%
%% In its own process: zone_tick/2 stashes its zone state in the process
%% dictionary and reads `lua_state` back from it, so a test running after
%% another one in the same process would call the OTHER script's zone_tick.
zone_tick_without_dirty_declaration_test() ->
    Script = fixture("config_move_world.lua"),
    Self = self(),
    Pid = spawn(fun() ->
        Config = #{game_config => #{lua_script => Script}},
        {ok, ZoneStates} = asobi_lua_world:generate_world(0, Config),
        ZoneState = asobi_lua_world:init_zone_state(Config, maps:get({0, 0}, ZoneStates)),
        Self ! {result, asobi_lua_world:zone_tick(#{}, ZoneState)}
    end),
    MonRef = monitor(process, Pid),
    receive
        {result, Result} ->
            demonitor(MonRef, [flush]),
            ?assertEqual(2, tuple_size(Result))
    after 5_000 ->
        ?assert(false)
    end.
