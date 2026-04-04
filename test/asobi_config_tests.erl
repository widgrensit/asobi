-module(asobi_config_tests).
-include_lib("eunit/include/eunit.hrl").

fixture(Name) ->
    filename:absname(
        filename:join([code:lib_dir(asobi), "test", "fixtures", "lua", Name])
    ).

fixture_dir() ->
    filename:absname(
        filename:join([code:lib_dir(asobi), "test", "fixtures", "lua"])
    ).

%% --- Tests ---

config_test_() ->
    {foreach, fun() -> application:set_env(asobi, game_modes, #{}) end,
        fun(_) -> application:set_env(asobi, game_modes, #{}) end, [
            {"single mode: loads match.lua globals", fun single_mode_loads_globals/0},
            {"single mode: minimal config (only match_size)", fun single_mode_minimal/0},
            {"single mode: missing match_size fails", fun single_mode_missing_size/0},
            {"multi mode: loads config.lua manifest", fun multi_mode_manifest/0},
            {"no config files: no-op", fun no_config_noop/0},
            {"bot names: reads from bot script", fun bot_names_from_script/0},
            {"bot names: falls back to defaults", fun bot_names_fallback/0}
        ]}.

single_mode_loads_globals() ->
    application:set_env(asobi, game_dir, fixture_dir()),
    %% Rename config_match.lua content expectations:
    %% match_size=4, max_players=10, strategy=fill, bots with script
    ok = asobi_config:maybe_load_game_config(),
    {ok, Modes} = application:get_env(asobi, game_modes),
    ?assert(is_map_key(~"default", Modes)),
    Mode = maps:get(~"default", Modes),
    ?assertMatch(#{module := {lua, _}, match_size := 4, max_players := 10, strategy := fill}, Mode),
    #{bots := #{enabled := true, script := BotScript}} = Mode,
    ?assert(is_binary(BotScript)).

single_mode_minimal() ->
    %% Point game_dir to a temp dir with only config_minimal.lua renamed to match.lua
    TmpDir = make_temp_dir(),
    {ok, Content} = file:read_file(fixture("config_minimal.lua")),
    ok = file:write_file(filename:join(TmpDir, "match.lua"), Content),
    application:set_env(asobi, game_dir, TmpDir),
    ok = asobi_config:maybe_load_game_config(),
    {ok, Modes} = application:get_env(asobi, game_modes),
    Mode = maps:get(~"default", Modes),
    ?assertEqual(2, maps:get(match_size, Mode)),
    ?assertEqual(2, maps:get(max_players, Mode)),
    cleanup_temp_dir(TmpDir).

single_mode_missing_size() ->
    TmpDir = make_temp_dir(),
    {ok, Content} = file:read_file(fixture("config_no_size.lua")),
    ok = file:write_file(filename:join(TmpDir, "match.lua"), Content),
    application:set_env(asobi, game_dir, TmpDir),
    {error, _} = asobi_config:maybe_load_game_config(),
    cleanup_temp_dir(TmpDir).

multi_mode_manifest() ->
    TmpDir = make_temp_dir(),
    %% Copy config.lua manifest and the match scripts it references
    {ok, Manifest} = file:read_file(fixture("config_manifest.lua")),
    ok = file:write_file(filename:join(TmpDir, "config.lua"), Manifest),
    {ok, Match} = file:read_file(fixture("config_match.lua")),
    ok = file:write_file(filename:join(TmpDir, "config_match.lua"), Match),
    {ok, Minimal} = file:read_file(fixture("config_minimal.lua")),
    ok = file:write_file(filename:join(TmpDir, "config_minimal.lua"), Minimal),
    %% Copy boons.lua (required by config_match.lua)
    {ok, Boons} = file:read_file(fixture("boons.lua")),
    ok = file:write_file(filename:join(TmpDir, "boons.lua"), Boons),
    %% Copy bots dir
    ok = file:make_dir(filename:join(TmpDir, "bots")),
    {ok, Chaser} = file:read_file(fixture("bots/chaser.lua")),
    ok = file:write_file(filename:join(TmpDir, "bots/chaser.lua"), Chaser),

    application:set_env(asobi, game_dir, TmpDir),
    ok = asobi_config:maybe_load_game_config(),
    {ok, Modes} = application:get_env(asobi, game_modes),
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
    ok = asobi_config:maybe_load_game_config(),
    {ok, Modes} = application:get_env(asobi, game_modes),
    ?assert(is_map_key(~"existing", Modes)),
    cleanup_temp_dir(TmpDir).

bot_names_from_script() ->
    {ok, St} = asobi_lua_loader:new(fixture("bots/named_bot.lua")),
    {ok, Val, St1} = luerl:get_table_keys([~"names"], St),
    Names = luerl:decode(Val, St1),
    NameList = [V || {_, V} <- Names, is_binary(V)],
    ?assertEqual([~"Spark", ~"Blitz", ~"Volt", ~"Neon", ~"Pulse"], NameList).

bot_names_fallback() ->
    {ok, St} = asobi_lua_loader:new(fixture("bots/chaser.lua")),
    case luerl:get_table_keys([~"names"], St) of
        {ok, nil, _} -> ok;
        {ok, false, _} -> ok;
        _ -> ?assert(false)
    end.

%% --- Helpers ---

make_temp_dir() ->
    TmpDir = "/tmp/asobi_config_test_" ++ integer_to_list(erlang:unique_integer([positive])),
    ok = filelib:ensure_dir(filename:join(TmpDir, "dummy")),
    TmpDir.

cleanup_temp_dir(Dir) ->
    os:cmd("rm -rf " ++ Dir),
    ok.
