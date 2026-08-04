-module(asobi_bot_script_env_tests).
-include_lib("eunit/include/eunit.hrl").

%% Locks the environment guides/lua-bots.md documents for a bot script.
%% asobi_bot loads its script with asobi_lua_loader:new/1, whose PreInstall
%% is the identity function, so a bot gets the hardened base state and NOT
%% the `game.*` namespace that asobi_lua_match installs for match scripts.

bot_state_has_no_game_namespace_test() ->
    with_bot_script(~"probe = type(game)\n", fun(St) ->
        ?assertEqual(nil, global(~"game", St)),
        ?assertEqual(~"nil", global(~"probe", St))
    end).

%% Contrast case: the same script loaded the way asobi_lua_match loads a match
%% script DOES have `game`. Without this the assertion above could pass because
%% the probe is broken rather than because bots lack the namespace.
match_state_does_have_game_namespace_test() ->
    Ctx = #{match_id => ~"m1", match_pid => self(), script => ~"match.lua"},
    PreInstall = fun(St) -> asobi_lua_api:install(Ctx, St) end,
    Path = filename:join(temp_dir(), script_name()),
    ok = file:write_file(Path, ~"probe = type(game)\n"),
    try
        {ok, St} = asobi_lua_loader:new(Path, 2000, PreInstall),
        ?assertEqual(~"table", global(~"probe", St))
    after
        file:delete(Path)
    end.

bot_state_has_no_game_subtables_test() ->
    Code =
        ~"""
        ok_pcall, err = pcall(function() return game.economy end)
        """,
    with_bot_script(Code, fun(St) ->
        ?assertEqual(false, global(~"ok_pcall", St))
    end).

bot_state_strips_dangerous_globals_test() ->
    with_bot_script(~"return nil\n", fun(St) ->
        [
            ?assertEqual(nil, global(Name, St))
         || Name <- [
                ~"io",
                ~"package",
                ~"load",
                ~"loadfile",
                ~"loadstring",
                ~"dofile",
                ~"print",
                ~"eprint"
            ]
        ],
        [
            ?assertEqual(nil, path([~"os", Name], St))
         || Name <- [~"execute", ~"exit", ~"getenv", ~"remove", ~"rename", ~"tmpname"]
        ]
    end).

bot_state_keeps_math_helpers_test() ->
    Code =
        ~"""
        root = math.sqrt(16)
        roll = math.random(3, 3)
        """,
    with_bot_script(Code, fun(St) ->
        ?assertEqual(4.0, global(~"root", St)),
        ?assertEqual(3, global(~"roll", St))
    end).

bot_state_can_require_next_to_the_script_test() ->
    Dir = temp_dir(),
    ok = file:write_file(filename:join(Dir, "targeting.lua"), ~"return { pick = 7 }\n"),
    Path = filename:join(Dir, "bot.lua"),
    ok = file:write_file(Path, ~"picked = require(\"targeting\").pick\n"),
    try
        {ok, St} = asobi_lua_loader:new(Path),
        ?assertEqual(7, global(~"picked", St))
    after
        file:delete(Path),
        file:delete(filename:join(Dir, "targeting.lua"))
    end.

%% --- helpers ---

-spec with_bot_script(binary(), fun((dynamic()) -> term())) -> term().
with_bot_script(Code, Fun) ->
    Path = filename:join(temp_dir(), script_name()),
    ok = file:write_file(Path, Code),
    try
        {ok, St} = asobi_lua_loader:new(Path),
        Fun(St)
    after
        file:delete(Path)
    end.

-spec temp_dir() -> file:filename_all().
temp_dir() ->
    Dir = filename:join(filename:basedir(user_cache, "asobi_bot_script_env_tests"), "game"),
    ok = filelib:ensure_dir(filename:join(Dir, "keep")),
    Dir.

-spec script_name() -> string().
script_name() ->
    "bot_" ++ integer_to_list(erlang:unique_integer([positive])) ++ ".lua".

-spec global(binary(), dynamic()) -> term().
global(Name, St) ->
    path([Name], St).

-spec path([binary()], dynamic()) -> term().
path(Keys, St) ->
    {ok, Value, St1} = luerl:get_table_keys(Keys, St),
    luerl:decode(Value, St1).
