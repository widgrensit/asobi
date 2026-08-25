-module(asobi_lua_config_tests).
-include_lib("eunit/include/eunit.hrl").
-include("asobi_lua_bots.hrl").

%% logger handler callback, used by discovery_flag_non_boolean_warns/0.
-export([log/2]).

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
    {foreach, fun setup_modes/0, fun(_) -> teardown_modes() end, [
        {"single mode: loads match.lua globals", fun single_mode_loads_globals/0},
        {"single mode: registers 'default' key in game_modes (load-bearing, asobi#244)",
            fun single_mode_registers_default_key/0},
        {"single mode: minimal config (only match_size)", fun single_mode_minimal/0},
        {"single mode: missing match_size fails", fun single_mode_missing_size/0},
        {"multi mode: loads config.lua manifest", fun multi_mode_manifest/0},
        {"no config files: declares no modes, operator modes untouched",
            fun no_config_leaves_operator_modes/0},
        {"bot names: reads from bot script", fun bot_names_from_script/0},
        {"bot names: falls back to defaults", fun bot_names_fallback/0},
        {"world config: reads zone settings", fun world_config_zone_settings/0},
        {"world config: reads phase 2 settings", fun world_config_phase2_settings/0},
        {"world config: cold_tick_divisor = 0 survives parsing",
            fun world_config_cold_divisor_zero/0},
        {"game_type world selects world bridge", fun game_type_world_selects_world_bridge/0},
        {"game_type absent defaults to match bridge", fun game_type_absent_defaults_to_match/0},
        {"empty_grace_ms global is forwarded to mode config", fun empty_grace_ms_forwarded/0},
        {"player_ttl_ms positive is forwarded", fun player_ttl_ms_positive_forwarded/0},
        {"player_ttl_ms = -1 is forwarded (persistent world opt-in)",
            fun player_ttl_ms_minus_one_forwarded/0},
        {"player_ttl_ms = 0 is forwarded (explicit immediate cleanup)",
            fun player_ttl_ms_zero_forwarded/0},
        {"player_ttl_ms absent: key omitted from mode config", fun player_ttl_ms_absent_omitted/0},
        {"match_size = 0 is rejected", fun match_size_zero_rejected/0},
        {"match_size negative is rejected", fun match_size_negative_rejected/0},
        {"match_size float is truncated then rejected", fun match_size_float_rejected/0},
        {"unknown strategy is preserved as-is", fun unknown_strategy_preserved/0},
        {"strategy = skill_based is recognised", fun strategy_skill_based/0},
        {"state_strategy = shared resolves to asobi_lua_match_shared", fun state_strategy_shared/0},
        {"state_strategy absent resolves to asobi_lua_match", fun state_strategy_absent/0},
        {"state_strategy = unknown is ignored", fun state_strategy_unknown/0},
        {"config.lua returning non-table errors", fun config_returns_non_table/0},
        {"config.lua referencing missing match script errors", fun config_missing_match_script/0},
        {"bot_config table with min_players is forwarded", fun bot_config_min_players/0},
        {"bot_config min_players defaults to match_size",
            fun bot_config_min_players_defaults_to_match_size/0},
        {"bot_config enabled = false overrides the default true",
            fun bot_config_enabled_false_override/0},
        {"bot_config min_players far exceeding the ceiling is clamped, not rejected",
            fun bot_config_min_players_clamped_at_ceiling/0},
        {"world dimension globals (tick_rate/grid_size/zone_size/view_radius/persistent)",
            fun world_dimension_globals_forwarded/0},
        {"listed/quick_play = false on a world reach the mode and world config",
            fun discovery_flags_forwarded/0},
        {"listed = true opts a match mode into the live-match browser",
            fun listed_match_global_forwarded/0},
        {"min_players reaches the mode config (#481)", fun min_players_global_forwarded/0},
        {"min_players absent leaves the key out so match_size still defaults it (#481)",
            fun min_players_absent_keeps_match_size/0},
        {"absent listed/quick_play leave the per-kind defaults alone",
            fun discovery_flags_absent_keep_defaults/0},
        {"a non-boolean listed is ignored and warns rather than failing open",
            fun discovery_flag_non_boolean_warns/0},
        {"a non-boolean quick_play is ignored and warns, and stays true downstream",
            fun quick_play_non_boolean_warns/0},
        {"a huge global value is elided in the warning rather than logged whole",
            fun oversized_global_value_elided/0},
        {"guest_auth = true global enables the asobi guest_auth flag",
            fun guest_auth_global_enables/0},
        {"guest_auth absent leaves the flag off", fun guest_auth_absent_leaves_off/0},
        {"guest_auth truthy non-bool does not enable", fun guest_auth_truthy_nonbool_stays_off/0},
        {"guest_auth resets a stale true when a later bundle omits it",
            fun guest_auth_stale_true_is_reset/0},
        {"an operator guest_auth survives a boot with no bundle at all",
            fun operator_guest_auth_survives_a_bundleless_boot/0},
        {"an operator guest_auth = false beats a bundle that declares true",
            fun operator_guest_auth_false_beats_a_declaring_bundle/0},
        {"registration global sets the effective registration mode",
            fun registration_global_sets_mode/0},
        {"registration global is read from config.lua in multi-mode",
            fun registration_global_from_manifest/0},
        {"registration absent leaves the operator's app env alone",
            fun registration_absent_keeps_app_env/0},
        {"registration with an unrecognised value keeps the configured mode",
            fun registration_invalid_keeps_app_env/0},
        {"an operator sys.config registration mode beats the script's",
            fun operator_registration_beats_script/0},
        {"a mode deleted from config.lua disappears on reload",
            fun deleted_mode_disappears_on_reload/0},
        {"an operator sys.config mode survives a bundle load",
            fun operator_mode_survives_bundle_load/0}
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
    %% -> read_single_mode/1), asserting against the registry asobi actually
    %% reads (asobi_game_config:modes/0) rather than a local helper.
    TmpDir = make_temp_dir(),
    ok = file:write_file(filename:join(TmpDir, "match.lua"), ~"match_size = 2\n"),
    application:set_env(asobi, game_dir, TmpDir),
    ok = asobi_lua_config:maybe_load_game_config(),
    ?assert(is_map_key(~"default", asobi_game_config:modes())),
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

%% These assert through asobi_game_config:guest_auth/0 rather than the raw app
%% env, the way the registration cases below assert through
%% asobi_registration:mode/0: what a script declares is the script layer, and
%% the effective flag is that layer composed with the operator's (ADR 0014).
guest_auth_global_enables() ->
    reset_guest_auth(),
    TmpDir = make_temp_dir(),
    ok = file:write_file(
        filename:join(TmpDir, "match.lua"),
        ~"match_size = 2\nguest_auth = true\n"
    ),
    application:set_env(asobi, game_dir, TmpDir),
    ok = asobi_lua_config:maybe_load_game_config(),
    ?assertEqual({ok, true}, application:get_env(asobi, script_guest_auth)),
    ?assert(asobi_game_config:guest_auth()),
    reset_guest_auth(),
    cleanup_temp_dir(TmpDir).

guest_auth_absent_leaves_off() ->
    reset_guest_auth(),
    TmpDir = make_temp_dir(),
    ok = file:write_file(filename:join(TmpDir, "match.lua"), ~"match_size = 2\n"),
    application:set_env(asobi, game_dir, TmpDir),
    ok = asobi_lua_config:maybe_load_game_config(),
    ?assertNot(asobi_game_config:guest_auth()),
    cleanup_temp_dir(TmpDir).

guest_auth_truthy_nonbool_stays_off() ->
    reset_guest_auth(),
    TmpDir = make_temp_dir(),
    ok = file:write_file(
        filename:join(TmpDir, "match.lua"),
        ~"match_size = 2\nguest_auth = 1\n"
    ),
    application:set_env(asobi, game_dir, TmpDir),
    ok = asobi_lua_config:maybe_load_game_config(),
    ?assertNot(asobi_game_config:guest_auth()),
    reset_guest_auth(),
    cleanup_temp_dir(TmpDir).

%% The stale value a new bundle has to clear is the previous *bundle's*, so the
%% reset lands in the script layer. Seed it there, not in the operator's key.
guest_auth_stale_true_is_reset() ->
    reset_guest_auth(),
    application:set_env(asobi, script_guest_auth, true),
    TmpDir = make_temp_dir(),
    ok = file:write_file(filename:join(TmpDir, "match.lua"), ~"match_size = 2\n"),
    application:set_env(asobi, game_dir, TmpDir),
    ok = asobi_lua_config:maybe_load_game_config(),
    ?assertEqual({ok, false}, application:get_env(asobi, script_guest_auth)),
    ?assertNot(asobi_game_config:guest_auth()),
    reset_guest_auth(),
    cleanup_temp_dir(TmpDir).

%% The reported bug: a release that embeds asobi as an Erlang library ships no
%% Lua bundle, so this loader took the "no config script" branch and wrote the
%% flag `false` straight over the operator's `{guest_auth, true}` - silently, on
%% every boot, leaving POST /auth/guest answering 403 guest.disabled forever.
%% The loader still writes that `false`, which is what resets a stale bundle,
%% but it writes it to the script layer where the operator's key outranks it.
operator_guest_auth_survives_a_bundleless_boot() ->
    reset_guest_auth(),
    application:set_env(asobi, guest_auth, true),
    %% No config.lua and no match.lua, like a /app/game that does not exist.
    TmpDir = make_temp_dir(),
    application:set_env(asobi, game_dir, TmpDir),
    ok = asobi_lua_config:maybe_load_game_config(),
    ?assertEqual({ok, true}, application:get_env(asobi, guest_auth)),
    ?assertEqual({ok, false}, application:get_env(asobi, script_guest_auth)),
    ?assert(asobi_game_config:guest_auth()),
    reset_guest_auth(),
    cleanup_temp_dir(TmpDir).

%% The other direction, and the half that keeps ADR 0004's trust boundary: a
%% bundle cannot open an unauthenticated endpoint on a deployment that said no.
operator_guest_auth_false_beats_a_declaring_bundle() ->
    reset_guest_auth(),
    application:set_env(asobi, guest_auth, false),
    TmpDir = make_temp_dir(),
    ok = file:write_file(
        filename:join(TmpDir, "match.lua"),
        ~"match_size = 2\nguest_auth = true\n"
    ),
    application:set_env(asobi, game_dir, TmpDir),
    ok = asobi_lua_config:maybe_load_game_config(),
    ?assertEqual({ok, true}, application:get_env(asobi, script_guest_auth)),
    ?assertNot(asobi_game_config:guest_auth()),
    reset_guest_auth(),
    cleanup_temp_dir(TmpDir).

reset_guest_auth() ->
    application:unset_env(asobi, guest_auth),
    application:unset_env(asobi, script_guest_auth).

%% asobi_lua#122: an engine-hosted game has no sys.config, so a posture it
%% cannot declare is a posture it never gets. Assert the effective mode
%% asobi_registration resolves, not the raw key, since the script writes the
%% script layer and only the composition is the observable behaviour.
registration_global_sets_mode() ->
    application:unset_env(asobi, registration),
    application:unset_env(asobi, script_registration),
    TmpDir = make_temp_dir(),
    ok = file:write_file(
        filename:join(TmpDir, "match.lua"),
        ~"match_size = 2\nregistration = \"closed\"\n"
    ),
    application:set_env(asobi, game_dir, TmpDir),
    ok = asobi_lua_config:maybe_load_game_config(),
    ?assertEqual(closed, asobi_registration:mode()),
    ?assertEqual({deny, ~"registration_closed"}, asobi_registration:check(password)),
    reset_registration(),
    cleanup_temp_dir(TmpDir).

registration_global_from_manifest() ->
    application:unset_env(asobi, registration),
    application:unset_env(asobi, script_registration),
    TmpDir = make_temp_dir(),
    ok = file:write_file(
        filename:join(TmpDir, "config.lua"),
        ~"registration = \"oauth_only\"\nreturn { solo = \"solo.lua\" }\n"
    ),
    ok = file:write_file(filename:join(TmpDir, "solo.lua"), ~"match_size = 2\n"),
    application:set_env(asobi, game_dir, TmpDir),
    ok = asobi_lua_config:maybe_load_game_config(),
    ?assertEqual(oauth_only, asobi_registration:mode()),
    reset_registration(),
    cleanup_temp_dir(TmpDir).

registration_absent_keeps_app_env() ->
    application:set_env(asobi, registration, closed),
    application:unset_env(asobi, script_registration),
    TmpDir = make_temp_dir(),
    ok = file:write_file(filename:join(TmpDir, "match.lua"), ~"match_size = 2\n"),
    application:set_env(asobi, game_dir, TmpDir),
    ok = asobi_lua_config:maybe_load_game_config(),
    ?assertEqual(closed, asobi_registration:mode()),
    ?assertEqual(undefined, application:get_env(asobi, script_registration)),
    reset_registration(),
    cleanup_temp_dir(TmpDir).

registration_invalid_keeps_app_env() ->
    application:set_env(asobi, registration, closed),
    application:unset_env(asobi, script_registration),
    TmpDir = make_temp_dir(),
    ok = file:write_file(
        filename:join(TmpDir, "match.lua"),
        ~"match_size = 2\nregistration = \"invite_only\"\n"
    ),
    application:set_env(asobi, game_dir, TmpDir),
    ok = asobi_lua_config:maybe_load_game_config(),
    ?assertEqual(closed, asobi_registration:mode()),
    ?assertEqual(undefined, application:get_env(asobi, script_registration)),
    reset_registration(),
    cleanup_temp_dir(TmpDir).

%% ADR 0006's trust direction, applied to the signup gate: a bundle may pick a
%% posture for a deployment that states none, and may never widen one that
%% does. Without the two layers this `open` would overwrite the operator's
%% `closed` and reopen public signup.
operator_registration_beats_script() ->
    application:set_env(asobi, registration, closed),
    application:unset_env(asobi, script_registration),
    TmpDir = make_temp_dir(),
    ok = file:write_file(
        filename:join(TmpDir, "match.lua"),
        ~"match_size = 2\nregistration = \"open\"\n"
    ),
    application:set_env(asobi, game_dir, TmpDir),
    ok = asobi_lua_config:maybe_load_game_config(),
    ?assertEqual({ok, open}, application:get_env(asobi, script_registration)),
    ?assertEqual(closed, asobi_registration:mode()),
    ?assertEqual({deny, ~"registration_closed"}, asobi_registration:check(password)),
    reset_registration(),
    cleanup_temp_dir(TmpDir).

reset_registration() ->
    application:unset_env(asobi, registration),
    application:unset_env(asobi, script_registration).

%% The registry used to be a "new wins, nothing is ever removed" merge, so a
%% mode dropped from config.lua stayed matchable for the life of the node. The
%% script layer is now replaced wholesale by asobi_game_config (ADR 0006).
deleted_mode_disappears_on_reload() ->
    TmpDir = make_temp_dir(),
    ok = file:write_file(filename:join(TmpDir, "arena.lua"), ~"match_size = 4\n"),
    ok = file:write_file(filename:join(TmpDir, "ctf.lua"), ~"match_size = 8\n"),
    ConfigPath = filename:join(TmpDir, "config.lua"),
    ok = file:write_file(ConfigPath, ~"return { arena = \"arena.lua\", ctf = \"ctf.lua\" }\n"),
    application:set_env(asobi, game_dir, TmpDir),
    ok = asobi_lua_config:maybe_load_game_config(),
    ?assertEqual([~"arena", ~"ctf"], lists:sort(maps:keys(get_game_modes()))),

    ok = file:write_file(ConfigPath, ~"return { arena = \"arena.lua\" }\n"),
    ok = asobi_lua_config:reload_game_modes(),
    ?assertEqual([~"arena"], maps:keys(get_game_modes())),
    ?assertEqual(#{}, asobi_game_modes:mode_config(~"ctf")),
    ?assertEqual({error, not_found}, asobi_game_modes:resolve_game_module(~"ctf")),
    cleanup_temp_dir(TmpDir).

%% A bundle load must not overwrite or drop what the operator put in
%% sys.config: the two layers live in separate keys and the operator wins.
operator_mode_survives_bundle_load() ->
    application:set_env(asobi, game_modes, #{~"ranked" => #{module => my_mod, match_size => 2}}),
    TmpDir = make_temp_dir(),
    ok = file:write_file(filename:join(TmpDir, "match.lua"), ~"match_size = 4\n"),
    application:set_env(asobi, game_dir, TmpDir),
    ok = asobi_lua_config:maybe_load_game_config(),
    ?assertEqual([~"default", ~"ranked"], lists:sort(maps:keys(get_game_modes()))),
    ok = asobi_lua_config:reload_game_modes(),
    ?assertEqual(
        #{module => my_mod, match_size => 2},
        asobi_game_modes:mode_config(~"ranked")
    ),
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

no_config_leaves_operator_modes() ->
    TmpDir = make_temp_dir(),
    application:set_env(asobi, game_dir, TmpDir),
    application:set_env(asobi, game_modes, #{~"existing" => #{module => my_mod}}),
    ok = asobi_lua_config:maybe_load_game_config(),
    Modes = get_game_modes(),
    ?assertEqual([~"existing"], maps:keys(Modes)),
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

%% widgrensit/asobi#561: 0 is meaningful - an idle zone is never ticked - so it
%% cannot go through maybe_add_int/3, which requires `Val > 0` and would drop it
%% back to the default of 10 without a word. This one token is the whole
%% user-facing entry point for ADR 0021 on a Lua game, and asobi's docs are
%% Lua-first. `maps:get/2` raises badkey when the value is dropped.
world_config_cold_divisor_zero() ->
    TmpDir = make_temp_dir(),
    {ok, Content} = file:read_file(fixture("config_world_cold_zero.lua")),
    ok = file:write_file(filename:join(TmpDir, "match.lua"), Content),
    application:set_env(asobi, game_dir, TmpDir),
    ok = asobi_lua_config:maybe_load_game_config(),
    Mode = maps:get(~"default", get_game_modes()),
    ?assertEqual(0, maps:get(cold_tick_divisor, Mode)),
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
    %% broadcast_interval reaches the mode config too, so a world can decimate
    %% the wire delta rate (asobi#463: it was read by asobi_zone but never
    %% plumbed, so every zone was stuck on the default 3).
    ?assertEqual(2, maps:get(broadcast_interval, Mode)),
    %% And world_config/1 must echo them through.
    {ok, WorldConfig} = asobi_game_modes:world_config(~"default"),
    ?assertEqual(100, maps:get(tick_rate, WorldConfig)),
    ?assertEqual(1, maps:get(grid_size, WorldConfig)),
    ?assertEqual(1500, maps:get(zone_size, WorldConfig)),
    ?assertEqual(0, maps:get(view_radius, WorldConfig)),
    ?assertEqual(true, maps:get(persistent, WorldConfig)),
    ?assertEqual(2, maps:get(broadcast_interval, WorldConfig)),
    cleanup_temp_dir(TmpDir).

discovery_flags_forwarded() ->
    %% Both flags are discovery-tier only and default to true for a world, so
    %% a hub is browsable and quick-playable without saying anything. A script
    %% that wants a hidden or out-of-rotation mode had no way to say so from
    %% Lua and needed an operator game_modes entry, which replaces the whole
    %% mode map rather than merging into it.
    TmpDir = make_temp_dir(),
    {ok, Content} = file:read_file(fixture("config_discovery_flags.lua")),
    ok = file:write_file(filename:join(TmpDir, "match.lua"), Content),
    application:set_env(asobi, game_dir, TmpDir),
    ok = asobi_lua_config:maybe_load_game_config(),
    Mode = maps:get(~"default", get_game_modes()),
    ?assertEqual(false, maps:get(listed, Mode)),
    ?assertEqual(false, maps:get(quick_play, Mode)),
    %% And world_config/1 must echo them through, or the world server still
    %% boots listed and the script's declaration is decorative.
    {ok, WorldConfig} = asobi_game_modes:world_config(~"default"),
    ?assertEqual(false, maps:get(listed, WorldConfig)),
    ?assertEqual(false, maps:get(quick_play, WorldConfig)),
    cleanup_temp_dir(TmpDir).

min_players_global_forwarded() ->
    %% asobi#481: asobi_match_server reads min_players at :219 and honours it in
    %% maybe_start/2, but the matchmaker hardcoded it to match_size and the Lua
    %% globals reader did not read it at all, so declaring it was silence.
    TmpDir = make_temp_dir(),
    {ok, Content} = file:read_file(fixture("config_min_players.lua")),
    ok = file:write_file(filename:join(TmpDir, "match.lua"), Content),
    application:set_env(asobi, game_dir, TmpDir),
    ok = asobi_lua_config:maybe_load_game_config(),
    Mode = maps:get(~"default", get_game_modes()),
    ?assertEqual(4, maps:get(min_players, Mode)),
    ?assertEqual(2, maps:get(match_size, Mode)),
    cleanup_temp_dir(TmpDir).

min_players_absent_keeps_match_size() ->
    %% The compatibility case, and the reason the default lives downstream
    %% rather than here: a script that never mentions min_players must produce
    %% a mode map with no such key, so asobi_matchmaker keeps defaulting it to
    %% match_size and no existing mode moves.
    TmpDir = make_temp_dir(),
    {ok, Content} = file:read_file(fixture("config_listed_match.lua")),
    ok = file:write_file(filename:join(TmpDir, "match.lua"), Content),
    application:set_env(asobi, game_dir, TmpDir),
    ok = asobi_lua_config:maybe_load_game_config(),
    Mode = maps:get(~"default", get_game_modes()),
    ?assertNot(maps:is_key(min_players, Mode)),
    cleanup_temp_dir(TmpDir).

listed_match_global_forwarded() ->
    %% The inverse default: matches are unlisted, so a match script has to opt
    %% in before match.list will ever return it.
    TmpDir = make_temp_dir(),
    {ok, Content} = file:read_file(fixture("config_listed_match.lua")),
    ok = file:write_file(filename:join(TmpDir, "match.lua"), Content),
    application:set_env(asobi, game_dir, TmpDir),
    ok = asobi_lua_config:maybe_load_game_config(),
    Mode = maps:get(~"default", get_game_modes()),
    ?assertEqual(true, maps:get(listed, Mode)),
    cleanup_temp_dir(TmpDir).

discovery_flags_absent_keep_defaults() ->
    %% The compatibility case. A script that never mentions either flag must
    %% produce a mode map with neither key, so the differing per-kind defaults
    %% downstream (matches false, worlds true) keep deciding. Writing a
    %% default here instead would silently flip every existing Lua match mode
    %% into the browser.
    TmpDir = make_temp_dir(),
    {ok, Content} = file:read_file(fixture("config_world_dimensions.lua")),
    ok = file:write_file(filename:join(TmpDir, "match.lua"), Content),
    application:set_env(asobi, game_dir, TmpDir),
    ok = asobi_lua_config:maybe_load_game_config(),
    Mode = maps:get(~"default", get_game_modes()),
    ?assertEqual(false, maps:is_key(listed, Mode)),
    ?assertEqual(false, maps:is_key(quick_play, Mode)),
    %% world_config/1 then supplies the world default, which is true for both.
    {ok, WorldConfig} = asobi_game_modes:world_config(~"default"),
    ?assertEqual(true, maps:get(listed, WorldConfig)),
    ?assertEqual(true, maps:get(quick_play, WorldConfig)),
    cleanup_temp_dir(TmpDir).

discovery_flag_non_boolean_warns() ->
    %% These two are the first boolean globals whose downstream default is
    %% true, so an unreadable value fails OPEN - the script asked to hide the
    %% world and it stays browsable. `listed = 0` is the plausible version of
    %% that mistake, because 0 is truthy in Lua but reads as "off" to most
    %% authors. The key must stay absent (so the default still decides) AND
    %% the loader must say so, or this is a silent dev-facing failure.
    TmpDir = make_temp_dir(),
    {ok, Content} = file:read_file(fixture("config_listed_not_boolean.lua")),
    ok = file:write_file(filename:join(TmpDir, "match.lua"), Content),
    application:set_env(asobi, game_dir, TmpDir),
    ok = logger:add_handler(?FUNCTION_NAME, ?MODULE, #{config => #{pid => self()}}),
    try
        ok = asobi_lua_config:maybe_load_game_config(),
        Mode = maps:get(~"default", get_game_modes()),
        ?assertEqual(false, maps:is_key(listed, Mode)),
        receive
            {log_event, #{
                event := lua_config_global_ignored,
                global := ~"listed",
                value := Value
            }} ->
                %% The value is what makes the warning actionable, so assert it
                %% reaches the report rather than only that something was logged.
                ?assertEqual(~"0", Value)
        after 1000 -> erlang:error(no_warning_logged_for_non_boolean_listed)
        end
    after
        _ = logger:remove_handler(?FUNCTION_NAME),
        cleanup_temp_dir(TmpDir)
    end.

quick_play_non_boolean_warns() ->
    %% quick_play defaults to true on both kinds, so unlike listed it can never
    %% fail closed - there is no configuration where a dropped value is safe.
    TmpDir = make_temp_dir(),
    {ok, Content} = file:read_file(fixture("config_quick_play_not_boolean.lua")),
    ok = file:write_file(filename:join(TmpDir, "match.lua"), Content),
    application:set_env(asobi, game_dir, TmpDir),
    ok = logger:add_handler(?FUNCTION_NAME, ?MODULE, #{config => #{pid => self()}}),
    try
        ok = asobi_lua_config:maybe_load_game_config(),
        Mode = maps:get(~"default", get_game_modes()),
        ?assertEqual(false, maps:is_key(quick_play, Mode)),
        {ok, WorldConfig} = asobi_game_modes:world_config(~"default"),
        ?assertEqual(true, maps:get(quick_play, WorldConfig)),
        receive
            {log_event, #{
                event := lua_config_global_ignored,
                global := ~"quick_play",
                value := ~"false"
            }} ->
                ok
        after 1000 -> erlang:error(no_warning_logged_for_non_boolean_quick_play)
        end
    after
        _ = logger:remove_handler(?FUNCTION_NAME),
        cleanup_temp_dir(TmpDir)
    end.

oversized_global_value_elided() ->
    %% The value in this report is chosen by whoever wrote the bundle, so
    %% `listed = string.rep("A", 400000)` is otherwise a 400 KB log line per
    %% load - and the config watcher reloads on any mtime change.
    TmpDir = make_temp_dir(),
    Script = [
        "match_size = 1\n",
        "game_type = \"world\"\n",
        "listed = string.rep(\"A\", 400000)\n",
        "function init(config) return {} end\n",
        "function spawn_position(p, s) return { x = 0, y = 0 } end\n",
        "function join(p, s) return s end\n",
        "function leave(p, s) return s end\n",
        "function zone_tick(e, z) return e, z end\n",
        "function handle_input(p, i, e) return e end\n",
        "function post_tick(t, s) return s end\n",
        "function generate_world(seed, c) return { [\"0,0\"] = {} } end\n"
    ],
    ok = file:write_file(filename:join(TmpDir, "match.lua"), Script),
    application:set_env(asobi, game_dir, TmpDir),
    ok = logger:add_handler(?FUNCTION_NAME, ?MODULE, #{config => #{pid => self()}}),
    try
        ok = asobi_lua_config:maybe_load_game_config(),
        receive
            {log_event, #{event := lua_config_global_ignored, global := ~"listed", value := V}} ->
                ?assert(byte_size(V) < 300),
                ?assertMatch({_, _}, binary:match(V, ~"400000 bytes"))
        after 1000 -> erlang:error(no_warning_logged_for_oversized_listed)
        end
    after
        _ = logger:remove_handler(?FUNCTION_NAME),
        cleanup_temp_dir(TmpDir)
    end.

%% logger handler callback: forwards the report of each event to the test pid
%% so a case can assert on what the loader logged.
-spec log(logger:log_event(), logger:handler_config()) -> ok.
log(#{msg := {report, Report}}, #{config := #{pid := Pid}}) when is_pid(Pid) ->
    Pid ! {log_event, Report},
    ok;
log(_Event, _Config) ->
    ok.

%% --- Helpers ---

-spec get_game_modes() -> #{dynamic() => dynamic()}.
get_game_modes() ->
    asobi_game_config:modes().

%% Both layers, so neither a leftover operator mode nor a leftover script mode
%% from an earlier case leaks into the next one.
%% Same registration asobi_app:start/2 performs: without it every {lua, _}
%% mode resolves to lua_runtime_unavailable. Undone after each case because
%% the registry is a global persistent_term and would otherwise decide the
%% result of any later module that asserts a provider is absent.
setup_modes() ->
    ok = asobi_lua_sup:register_game_modes(),
    reset_modes().

teardown_modes() ->
    [
        asobi_game_modes:unregister_game_mode(K)
     || K <- [lua_match, lua_match_shared, lua_world]
    ],
    reset_modes().

reset_modes() ->
    application:set_env(asobi, game_modes, #{}),
    application:set_env(asobi, script_game_modes, #{}),
    %% Both auth layers too: the guest cases write these, and eunit runs every
    %% module in one node, so a leftover `true` would decide a later assertion.
    reset_guest_auth().

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
