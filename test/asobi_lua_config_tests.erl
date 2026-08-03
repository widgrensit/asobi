-module(asobi_lua_config_tests).
-include_lib("eunit/include/eunit.hrl").
-include("asobi_lua_bots.hrl").

-spec fixture(string()) -> file:filename_all().
fixture(Name) ->
    {ok, LibDir} = safe_lib_dir(),
    filename:absname(
        filename:join([LibDir, "test", "fixtures", "lua", Name])
    ).

-spec fixture_dir() -> file:filename_all().
fixture_dir() ->
    {ok, LibDir} = safe_lib_dir(),
    filename:absname(
        filename:join([LibDir, "test", "fixtures", "lua"])
    ).

-spec safe_lib_dir() -> {ok, string()}.
safe_lib_dir() ->
    case code:lib_dir(asobi) of
        {error, bad_name} -> error(asobi_not_loaded);
        Dir -> {ok, Dir}
    end.

%% --- Tests ---

config_test_() ->
    {foreach, fun() -> application:set_env(asobi, game_modes, #{}) end,
        fun(_) -> application:set_env(asobi, game_modes, #{}) end, [
            {"single mode: loads match.lua globals", fun single_mode_loads_globals/0},
            {"single mode: registers 'default' key in game_modes (load-bearing, asobi#244)",
                fun single_mode_registers_default_key/0},
            {"single mode: minimal config (only match_size)", fun single_mode_minimal/0},
            {"single mode: missing match_size fails", fun single_mode_missing_size/0},
            {"multi mode: loads config.lua manifest", fun multi_mode_manifest/0},
            {"no config files: no-op", fun no_config_noop/0},
            {"bot names: reads from bot script", fun bot_names_from_script/0},
            {"bot names: falls back to defaults", fun bot_names_fallback/0},
            {"world config: reads zone settings", fun world_config_zone_settings/0},
            {"world config: reads phase 2 settings", fun world_config_phase2_settings/0},
            {"game_type world selects world bridge", fun game_type_world_selects_world_bridge/0},
            {"game_type absent defaults to match bridge", fun game_type_absent_defaults_to_match/0},
            {"empty_grace_ms global is forwarded to mode config", fun empty_grace_ms_forwarded/0},
            {"player_ttl_ms positive is forwarded", fun player_ttl_ms_positive_forwarded/0},
            {"player_ttl_ms = -1 is forwarded (persistent world opt-in)",
                fun player_ttl_ms_minus_one_forwarded/0},
            {"player_ttl_ms = 0 is forwarded (explicit immediate cleanup)",
                fun player_ttl_ms_zero_forwarded/0},
            {"player_ttl_ms absent: key omitted from mode config",
                fun player_ttl_ms_absent_omitted/0},
            {"match_size = 0 is rejected", fun match_size_zero_rejected/0},
            {"match_size negative is rejected", fun match_size_negative_rejected/0},
            {"match_size float is truncated then rejected", fun match_size_float_rejected/0},
            {"unknown strategy is preserved as-is", fun unknown_strategy_preserved/0},
            {"strategy = skill_based is recognised", fun strategy_skill_based/0},
            {"state_strategy = shared resolves to asobi_lua_match_shared",
                fun state_strategy_shared/0},
            {"state_strategy absent resolves to asobi_lua_match", fun state_strategy_absent/0},
            {"state_strategy = unknown is ignored", fun state_strategy_unknown/0},
            {"config.lua returning non-table errors", fun config_returns_non_table/0},
            {"config.lua referencing missing match script errors",
                fun config_missing_match_script/0},
            {"bot_config table with min_players is forwarded", fun bot_config_min_players/0},
            {"bot_config min_players defaults to match_size",
                fun bot_config_min_players_defaults_to_match_size/0},
            {"bot_config enabled = false overrides the default true",
                fun bot_config_enabled_false_override/0},
            {"bot_config min_players far exceeding the ceiling is clamped, not rejected",
                fun bot_config_min_players_clamped_at_ceiling/0},
            {"world dimension globals (tick_rate/grid_size/zone_size/view_radius/persistent)",
                fun world_dimension_globals_forwarded/0},
            {"guest_auth = true global enables the asobi guest_auth flag",
                fun guest_auth_global_enables/0},
            {"guest_auth absent leaves the flag off", fun guest_auth_absent_leaves_off/0},
            {"guest_auth truthy non-bool does not enable",
                fun guest_auth_truthy_nonbool_stays_off/0},
            {"guest_auth resets a stale true when a later bundle omits it",
                fun guest_auth_stale_true_is_reset/0}
        ]}.

single_mode_loads_globals() ->
    application:set_env(asobi, game_dir, fixture_dir()),
    ok = asobi_lua_config:maybe_load_game_config(),
    Modes = get_game_modes(),
    ?assert(is_map_key(~"default", Modes)),
    Mode = maps:get(~"default", Modes),
    ?assertMatch(#{module := {lua, _}, match_size := 4, max_players := 10, strategy := fill}, Mode),
    #{bots := #{enabled := true, script := BotScript}} = Mode,
    ?assert(is_binary(BotScript)).

single_mode_registers_default_key() ->
    %% Load-bearing per asobi#244: asobi's known_mode/1 no longer
    %% special-cases "default" — it purely checks game_modes membership.
    %% load_single_mode/2's #{~"default" => ModeConfig} registration is
    %% what keeps single-mode games recognised at all now. Exercised via
    %% the real reload path (maybe_load_game_config/0 -> reload_game_modes/0
    %% -> load_single_mode/2), asserting directly against the app-env key
    %% asobi reads rather than the local get_game_modes/0 helper.
    TmpDir = make_temp_dir(),
    ok = file:write_file(filename:join(TmpDir, "match.lua"), ~"match_size = 2\n"),
    application:set_env(asobi, game_dir, TmpDir),
    ok = asobi_lua_config:maybe_load_game_config(),
    {ok, Modes} = application:get_env(asobi, game_modes),
    ?assert(is_map_key(~"default", Modes)),
    cleanup_temp_dir(TmpDir).

single_mode_minimal() ->
    TmpDir = make_temp_dir(),
    {ok, Content} = file:read_file(fixture("config_minimal.lua")),
    ok = file:write_file(filename:join(TmpDir, "match.lua"), Content),
    application:set_env(asobi, game_dir, TmpDir),
    ok = asobi_lua_config:maybe_load_game_config(),
    Modes = get_game_modes(),
    Mode = maps:get(~"default", Modes),
    ?assertEqual(2, maps:get(match_size, Mode)),
    ?assertEqual(2, maps:get(max_players, Mode)),
    cleanup_temp_dir(TmpDir).

guest_auth_global_enables() ->
    application:unset_env(asobi, guest_auth),
    TmpDir = make_temp_dir(),
    ok = file:write_file(
        filename:join(TmpDir, "match.lua"),
        ~"match_size = 2\nguest_auth = true\n"
    ),
    application:set_env(asobi, game_dir, TmpDir),
    ok = asobi_lua_config:maybe_load_game_config(),
    ?assertEqual({ok, true}, application:get_env(asobi, guest_auth)),
    application:unset_env(asobi, guest_auth),
    cleanup_temp_dir(TmpDir).

guest_auth_absent_leaves_off() ->
    application:unset_env(asobi, guest_auth),
    TmpDir = make_temp_dir(),
    ok = file:write_file(filename:join(TmpDir, "match.lua"), ~"match_size = 2\n"),
    application:set_env(asobi, game_dir, TmpDir),
    ok = asobi_lua_config:maybe_load_game_config(),
    ?assertNotEqual({ok, true}, application:get_env(asobi, guest_auth)),
    cleanup_temp_dir(TmpDir).

guest_auth_truthy_nonbool_stays_off() ->
    application:unset_env(asobi, guest_auth),
    TmpDir = make_temp_dir(),
    ok = file:write_file(
        filename:join(TmpDir, "match.lua"),
        ~"match_size = 2\nguest_auth = 1\n"
    ),
    application:set_env(asobi, game_dir, TmpDir),
    ok = asobi_lua_config:maybe_load_game_config(),
    ?assertNotEqual({ok, true}, application:get_env(asobi, guest_auth)),
    application:unset_env(asobi, guest_auth),
    cleanup_temp_dir(TmpDir).

guest_auth_stale_true_is_reset() ->
    application:set_env(asobi, guest_auth, true),
    TmpDir = make_temp_dir(),
    ok = file:write_file(filename:join(TmpDir, "match.lua"), ~"match_size = 2\n"),
    application:set_env(asobi, game_dir, TmpDir),
    ok = asobi_lua_config:maybe_load_game_config(),
    ?assertEqual({ok, false}, application:get_env(asobi, guest_auth)),
    application:unset_env(asobi, guest_auth),
    cleanup_temp_dir(TmpDir).

single_mode_missing_size() ->
    TmpDir = make_temp_dir(),
    {ok, Content} = file:read_file(fixture("config_no_size.lua")),
    ok = file:write_file(filename:join(TmpDir, "match.lua"), Content),
    application:set_env(asobi, game_dir, TmpDir),
    {error, _} = asobi_lua_config:maybe_load_game_config(),
    cleanup_temp_dir(TmpDir).

multi_mode_manifest() ->
    TmpDir = make_temp_dir(),
    {ok, Manifest} = file:read_file(fixture("config_manifest.lua")),
    ok = file:write_file(filename:join(TmpDir, "config.lua"), Manifest),
    {ok, Match} = file:read_file(fixture("config_match.lua")),
    ok = file:write_file(filename:join(TmpDir, "config_match.lua"), Match),
    {ok, Minimal} = file:read_file(fixture("config_minimal.lua")),
    ok = file:write_file(filename:join(TmpDir, "config_minimal.lua"), Minimal),
    {ok, Boons} = file:read_file(fixture("boons.lua")),
    ok = file:write_file(filename:join(TmpDir, "boons.lua"), Boons),
    ok = file:make_dir(filename:join(TmpDir, "bots")),
    {ok, Chaser} = file:read_file(fixture("bots/chaser.lua")),
    ok = file:write_file(filename:join(TmpDir, "bots/chaser.lua"), Chaser),

    application:set_env(asobi, game_dir, TmpDir),
    ok = asobi_lua_config:maybe_load_game_config(),
    Modes = get_game_modes(),
    ?assert(is_map_key(~"arena", Modes)),
    ?assert(is_map_key(~"minimal", Modes)),
    Arena = maps:get(~"arena", Modes),
    ?assertEqual(4, maps:get(match_size, Arena)),
    ?assertEqual(10, maps:get(max_players, Arena)),
    Minimal2 = maps:get(~"minimal", Modes),
    ?assertEqual(2, maps:get(match_size, Minimal2)),
    cleanup_temp_dir(TmpDir).

no_config_noop() ->
    TmpDir = make_temp_dir(),
    application:set_env(asobi, game_dir, TmpDir),
    application:set_env(asobi, game_modes, #{~"existing" => #{module => my_mod}}),
    ok = asobi_lua_config:maybe_load_game_config(),
    Modes = get_game_modes(),
    ?assert(is_map_key(~"existing", Modes)),
    cleanup_temp_dir(TmpDir).

bot_names_from_script() ->
    {ok, St0} = asobi_lua_loader:new(fixture("bots/named_bot.lua")),
    St = assert_luerl_state(St0),
    {ok, Val, St1} = luerl:get_table_keys([~"names"], St),
    Names = luerl:decode(Val, St1),
    NameList = [V || {_, V} <- ensure_list(Names), is_binary(V)],
    ?assertEqual([~"Spark", ~"Blitz", ~"Volt", ~"Neon", ~"Pulse"], NameList).

bot_names_fallback() ->
    {ok, St0} = asobi_lua_loader:new(fixture("bots/chaser.lua")),
    St = assert_luerl_state(St0),
    case luerl:get_table_keys([~"names"], St) of
        {ok, nil, _} -> ok;
        {ok, false, _} -> ok;
        _ -> ?assert(false)
    end.

world_config_zone_settings() ->
    TmpDir = make_temp_dir(),
    {ok, Content} = file:read_file(fixture("config_world.lua")),
    ok = file:write_file(filename:join(TmpDir, "match.lua"), Content),
    application:set_env(asobi, game_dir, TmpDir),
    ok = asobi_lua_config:maybe_load_game_config(),
    Modes = get_game_modes(),
    Mode = maps:get(~"default", Modes),
    ?assertEqual(true, maps:get(lazy_zones, Mode)),
    ?assertEqual(60000, maps:get(zone_idle_timeout, Mode)),
    ?assertEqual(500, maps:get(max_active_zones, Mode)),
    cleanup_temp_dir(TmpDir).

world_config_phase2_settings() ->
    TmpDir = make_temp_dir(),
    {ok, Content} = file:read_file(fixture("config_world_phase2.lua")),
    ok = file:write_file(filename:join(TmpDir, "match.lua"), Content),
    application:set_env(asobi, game_dir, TmpDir),
    ok = asobi_lua_config:maybe_load_game_config(),
    Modes = get_game_modes(),
    Mode = maps:get(~"default", Modes),
    ?assertEqual(64, maps:get(spatial_grid_cell_size, Mode)),
    ?assertEqual(5, maps:get(cold_tick_divisor, Mode)),
    ?assertEqual(true, maps:get(lazy_zones, Mode)),
    cleanup_temp_dir(TmpDir).

game_type_world_selects_world_bridge() ->
    TmpDir = make_temp_dir(),
    {ok, Content} = file:read_file(fixture("config_game_type_world.lua")),
    ok = file:write_file(filename:join(TmpDir, "match.lua"), Content),
    application:set_env(asobi, game_dir, TmpDir),
    ok = asobi_lua_config:maybe_load_game_config(),
    Modes = get_game_modes(),
    Mode = maps:get(~"default", Modes),
    ?assertEqual(world, maps:get(type, Mode)),
    {ok, GameMod, _} = asobi_game_modes:resolve_game_module(~"default"),
    ?assertEqual(asobi_lua_world, GameMod),
    cleanup_temp_dir(TmpDir).

game_type_absent_defaults_to_match() ->
    TmpDir = make_temp_dir(),
    {ok, Content} = file:read_file(fixture("config_minimal.lua")),
    ok = file:write_file(filename:join(TmpDir, "match.lua"), Content),
    application:set_env(asobi, game_dir, TmpDir),
    ok = asobi_lua_config:maybe_load_game_config(),
    Modes = get_game_modes(),
    Mode = maps:get(~"default", Modes),
    ?assertEqual(false, maps:is_key(type, Mode)),
    {ok, GameMod, _} = asobi_game_modes:resolve_game_module(~"default"),
    ?assertEqual(asobi_lua_match, GameMod),
    cleanup_temp_dir(TmpDir).

empty_grace_ms_forwarded() ->
    TmpDir = make_temp_dir(),
    {ok, Content} = file:read_file(fixture("config_grace.lua")),
    ok = file:write_file(filename:join(TmpDir, "match.lua"), Content),
    application:set_env(asobi, game_dir, TmpDir),
    ok = asobi_lua_config:maybe_load_game_config(),
    Modes = get_game_modes(),
    Mode = maps:get(~"default", Modes),
    ?assertEqual(30000, maps:get(empty_grace_ms, Mode)),
    cleanup_temp_dir(TmpDir).

player_ttl_ms_positive_forwarded() ->
    TmpDir = make_temp_dir(),
    {ok, Content} = file:read_file(fixture("config_player_ttl.lua")),
    ok = file:write_file(filename:join(TmpDir, "match.lua"), Content),
    application:set_env(asobi, game_dir, TmpDir),
    ok = asobi_lua_config:maybe_load_game_config(),
    Mode = maps:get(~"default", get_game_modes()),
    ?assertEqual(5000, maps:get(player_ttl_ms, Mode)),
    cleanup_temp_dir(TmpDir).

player_ttl_ms_minus_one_forwarded() ->
    TmpDir = make_temp_dir(),
    Content = ~"match_size = 1\nplayer_ttl_ms = -1\n",
    ok = file:write_file(filename:join(TmpDir, "match.lua"), Content),
    application:set_env(asobi, game_dir, TmpDir),
    ok = asobi_lua_config:maybe_load_game_config(),
    Mode = maps:get(~"default", get_game_modes()),
    ?assertEqual(-1, maps:get(player_ttl_ms, Mode)),
    cleanup_temp_dir(TmpDir).

player_ttl_ms_zero_forwarded() ->
    TmpDir = make_temp_dir(),
    Content = ~"match_size = 1\nplayer_ttl_ms = 0\n",
    ok = file:write_file(filename:join(TmpDir, "match.lua"), Content),
    application:set_env(asobi, game_dir, TmpDir),
    ok = asobi_lua_config:maybe_load_game_config(),
    Mode = maps:get(~"default", get_game_modes()),
    ?assertEqual(0, maps:get(player_ttl_ms, Mode)),
    cleanup_temp_dir(TmpDir).

player_ttl_ms_absent_omitted() ->
    TmpDir = make_temp_dir(),
    {ok, Content} = file:read_file(fixture("config_minimal.lua")),
    ok = file:write_file(filename:join(TmpDir, "match.lua"), Content),
    application:set_env(asobi, game_dir, TmpDir),
    ok = asobi_lua_config:maybe_load_game_config(),
    Mode = maps:get(~"default", get_game_modes()),
    ?assertEqual(false, maps:is_key(player_ttl_ms, Mode)),
    cleanup_temp_dir(TmpDir).

match_size_zero_rejected() ->
    TmpDir = make_temp_dir(),
    ok = file:write_file(filename:join(TmpDir, "match.lua"), ~"match_size = 0\n"),
    application:set_env(asobi, game_dir, TmpDir),
    ?assertMatch({error, _}, asobi_lua_config:maybe_load_game_config()),
    cleanup_temp_dir(TmpDir).

match_size_negative_rejected() ->
    TmpDir = make_temp_dir(),
    ok = file:write_file(filename:join(TmpDir, "match.lua"), ~"match_size = -3\n"),
    application:set_env(asobi, game_dir, TmpDir),
    ?assertMatch({error, _}, asobi_lua_config:maybe_load_game_config()),
    cleanup_temp_dir(TmpDir).

match_size_float_rejected() ->
    %% read_global_int truncates the float, so 1.5 becomes 1 — but a
    %% script author passing a float almost certainly intends "fractional
    %% match size", which is wrong. Today this silently rounds to 1.
    %% Documenting so we notice if behaviour changes.
    TmpDir = make_temp_dir(),
    ok = file:write_file(filename:join(TmpDir, "match.lua"), ~"match_size = 1.5\n"),
    application:set_env(asobi, game_dir, TmpDir),
    ?assertEqual(ok, asobi_lua_config:maybe_load_game_config()),
    Mode = maps:get(~"default", get_game_modes()),
    ?assertEqual(1, maps:get(match_size, Mode)),
    cleanup_temp_dir(TmpDir).

unknown_strategy_preserved() ->
    %% maybe_add_strategy/2 keeps the binary unchanged when it doesn't
    %% match a known atom. Documents that behaviour for downstream
    %% strategy resolution.
    TmpDir = make_temp_dir(),
    ok = file:write_file(
        filename:join(TmpDir, "match.lua"),
        ~"match_size = 2\nstrategy = 'totally_made_up'\n"
    ),
    application:set_env(asobi, game_dir, TmpDir),
    ok = asobi_lua_config:maybe_load_game_config(),
    Mode = maps:get(~"default", get_game_modes()),
    ?assertEqual(~"totally_made_up", maps:get(strategy, Mode)),
    cleanup_temp_dir(TmpDir).

strategy_skill_based() ->
    TmpDir = make_temp_dir(),
    ok = file:write_file(
        filename:join(TmpDir, "match.lua"),
        ~"match_size = 2\nstrategy = 'skill_based'\n"
    ),
    application:set_env(asobi, game_dir, TmpDir),
    ok = asobi_lua_config:maybe_load_game_config(),
    Mode = maps:get(~"default", get_game_modes()),
    ?assertEqual(skill_based, maps:get(strategy, Mode)),
    cleanup_temp_dir(TmpDir).

state_strategy_shared() ->
    TmpDir = make_temp_dir(),
    ok = file:write_file(
        filename:join(TmpDir, "match.lua"),
        ~"match_size = 2\nstate_strategy = 'shared'\n"
    ),
    application:set_env(asobi, game_dir, TmpDir),
    ok = asobi_lua_config:maybe_load_game_config(),
    Mode = maps:get(~"default", get_game_modes()),
    ?assertEqual(shared, maps:get(state_strategy, Mode)),
    {ok, GameMod, _} = asobi_game_modes:resolve_game_module(~"default"),
    ?assertEqual(asobi_lua_match_shared, GameMod),
    cleanup_temp_dir(TmpDir).

state_strategy_absent() ->
    TmpDir = make_temp_dir(),
    ok = file:write_file(
        filename:join(TmpDir, "match.lua"),
        ~"match_size = 2\n"
    ),
    application:set_env(asobi, game_dir, TmpDir),
    ok = asobi_lua_config:maybe_load_game_config(),
    Mode = maps:get(~"default", get_game_modes()),
    ?assertNot(maps:is_key(state_strategy, Mode)),
    {ok, GameMod, _} = asobi_game_modes:resolve_game_module(~"default"),
    ?assertEqual(asobi_lua_match, GameMod),
    cleanup_temp_dir(TmpDir).

state_strategy_unknown() ->
    TmpDir = make_temp_dir(),
    ok = file:write_file(
        filename:join(TmpDir, "match.lua"),
        ~"match_size = 2\nstate_strategy = 'totally_made_up'\n"
    ),
    application:set_env(asobi, game_dir, TmpDir),
    ok = asobi_lua_config:maybe_load_game_config(),
    Mode = maps:get(~"default", get_game_modes()),
    ?assertNot(maps:is_key(state_strategy, Mode)),
    cleanup_temp_dir(TmpDir).

config_returns_non_table() ->
    TmpDir = make_temp_dir(),
    ok = file:write_file(filename:join(TmpDir, "config.lua"), ~"return 42\n"),
    application:set_env(asobi, game_dir, TmpDir),
    %% A non-table return manifests as a config_error today.
    ?assertMatch({error, _}, asobi_lua_config:maybe_load_game_config()),
    cleanup_temp_dir(TmpDir).

config_missing_match_script() ->
    %% A manifest pointing at a non-existent script must surface as an
    %% error and NOT silently install a broken mode.
    TmpDir = make_temp_dir(),
    ok = file:write_file(
        filename:join(TmpDir, "config.lua"),
        ~"return { arena = 'does_not_exist.lua' }\n"
    ),
    application:set_env(asobi, game_dir, TmpDir),
    ?assertMatch({error, _}, asobi_lua_config:maybe_load_game_config()),
    cleanup_temp_dir(TmpDir).

bot_config_min_players() ->
    %% bots = { script = "...", min_players = 6 } must be forwarded so a
    %% Lua game can override the spawner's default fill target (#79).
    TmpDir = make_temp_dir(),
    ok = filelib:ensure_dir(filename:join([TmpDir, "bots", "x"])),
    {ok, Chaser} = file:read_file(fixture("bots/chaser.lua")),
    ok = file:write_file(filename:join([TmpDir, "bots", "chaser.lua"]), Chaser),
    ok = file:write_file(
        filename:join(TmpDir, "match.lua"),
        ~"""
        match_size = 4
        bots = { script = 'bots/chaser.lua', min_players = 6 }
        """
    ),
    application:set_env(asobi, game_dir, TmpDir),
    ok = asobi_lua_config:maybe_load_game_config(),
    Mode = maps:get(~"default", get_game_modes()),
    Bots = maps:get(bots, Mode),
    ?assertEqual(true, maps:get(enabled, Bots)),
    ?assertEqual(6, maps:get(min_players, Bots)),
    cleanup_temp_dir(TmpDir).

bot_config_min_players_defaults_to_match_size() ->
    %% Per #79 / guides/lua-bots.md: a Lua game that omits min_players
    %% gets match_size, not the spawner's hardcoded fallback of 4.
    TmpDir = make_temp_dir(),
    ok = filelib:ensure_dir(filename:join([TmpDir, "bots", "x"])),
    {ok, Chaser} = file:read_file(fixture("bots/chaser.lua")),
    ok = file:write_file(filename:join([TmpDir, "bots", "chaser.lua"]), Chaser),
    ok = file:write_file(
        filename:join(TmpDir, "match.lua"),
        ~"""
        match_size = 2
        bots = { script = 'bots/chaser.lua' }
        """
    ),
    application:set_env(asobi, game_dir, TmpDir),
    ok = asobi_lua_config:maybe_load_game_config(),
    Mode = maps:get(~"default", get_game_modes()),
    Bots = maps:get(bots, Mode),
    ?assertEqual(true, maps:get(enabled, Bots)),
    ?assertEqual(2, maps:get(min_players, Bots)),
    cleanup_temp_dir(TmpDir).

bot_config_enabled_false_override() ->
    %% bots.enabled = false lets a game keep the bots table (e.g. for
    %% min_players) while disabling bot-fill.
    TmpDir = make_temp_dir(),
    ok = filelib:ensure_dir(filename:join([TmpDir, "bots", "x"])),
    {ok, Chaser} = file:read_file(fixture("bots/chaser.lua")),
    ok = file:write_file(filename:join([TmpDir, "bots", "chaser.lua"]), Chaser),
    ok = file:write_file(
        filename:join(TmpDir, "match.lua"),
        ~"""
        match_size = 4
        bots = { script = 'bots/chaser.lua', enabled = false }
        """
    ),
    application:set_env(asobi, game_dir, TmpDir),
    ok = asobi_lua_config:maybe_load_game_config(),
    Mode = maps:get(~"default", get_game_modes()),
    Bots = maps:get(bots, Mode),
    ?assertEqual(false, maps:get(enabled, Bots)),
    cleanup_temp_dir(TmpDir).

bot_config_min_players_clamped_at_ceiling() ->
    %% #79 follow-up (HIGH severity DoS, security review): a config
    %% declaring min_players in the millions (paired with an equally large
    %% max_players, so the spawner's own cap doesn't save us) must clamp to
    %% ?MAX_BOT_FILL at load time, not load unbounded and not fail the
    %% whole config load.
    TmpDir = make_temp_dir(),
    ok = filelib:ensure_dir(filename:join([TmpDir, "bots", "x"])),
    {ok, Chaser} = file:read_file(fixture("bots/chaser.lua")),
    ok = file:write_file(filename:join([TmpDir, "bots", "chaser.lua"]), Chaser),
    ok = file:write_file(
        filename:join(TmpDir, "match.lua"),
        ~"""
        match_size = 2
        max_players = 5000000
        bots = { script = 'bots/chaser.lua', min_players = 5000000 }
        """
    ),
    application:set_env(asobi, game_dir, TmpDir),
    ?assertEqual(ok, asobi_lua_config:maybe_load_game_config()),
    Mode = maps:get(~"default", get_game_modes()),
    Bots = maps:get(bots, Mode),
    ?assertEqual(true, maps:get(enabled, Bots)),
    ?assertEqual(?MAX_BOT_FILL, maps:get(min_players, Bots)),
    cleanup_temp_dir(TmpDir).

world_dimension_globals_forwarded() ->
    %% tick_rate / grid_size / zone_size / view_radius / persistent must
    %% flow from Lua globals into the mode config so
    %% asobi_game_modes:world_config/1 picks them up. Without this, a
    %% Lua-only world is stuck on the defaults (10x10 grid, view_radius
    %% 1) and two random spawns can land outside each other's interest
    %% set — the canonical "I joined but I see no one" failure.
    TmpDir = make_temp_dir(),
    {ok, Content} = file:read_file(fixture("config_world_dimensions.lua")),
    ok = file:write_file(filename:join(TmpDir, "match.lua"), Content),
    application:set_env(asobi, game_dir, TmpDir),
    ok = asobi_lua_config:maybe_load_game_config(),
    Mode = maps:get(~"default", get_game_modes()),
    ?assertEqual(100, maps:get(tick_rate, Mode)),
    ?assertEqual(1, maps:get(grid_size, Mode)),
    ?assertEqual(1500, maps:get(zone_size, Mode)),
    ?assertEqual(0, maps:get(view_radius, Mode)),
    ?assertEqual(true, maps:get(persistent, Mode)),
    %% And world_config/1 must echo them through.
    {ok, WorldConfig} = asobi_game_modes:world_config(~"default"),
    ?assertEqual(100, maps:get(tick_rate, WorldConfig)),
    ?assertEqual(1, maps:get(grid_size, WorldConfig)),
    ?assertEqual(1500, maps:get(zone_size, WorldConfig)),
    ?assertEqual(0, maps:get(view_radius, WorldConfig)),
    ?assertEqual(true, maps:get(persistent, WorldConfig)),
    cleanup_temp_dir(TmpDir).

%% --- Helpers ---

-spec get_game_modes() -> #{dynamic() => dynamic()}.
get_game_modes() ->
    case application:get_env(asobi, game_modes, #{}) of
        M when is_map(M) -> M;
        _ -> #{}
    end.

-spec assert_luerl_state(dynamic()) -> dynamic().
assert_luerl_state(St) when is_tuple(St), element(1, St) =:= luerl ->
    St.

-spec ensure_list(term()) -> list().
ensure_list(L) when is_list(L) -> L;
ensure_list(_) -> [].

make_temp_dir() ->
    TmpDir = "/tmp/asobi_lua_config_test_" ++ integer_to_list(erlang:unique_integer([positive])),
    ok = filelib:ensure_dir(filename:join(TmpDir, "dummy")),
    TmpDir.

cleanup_temp_dir(Dir) ->
    os:cmd("rm -rf " ++ Dir),
    ok.
