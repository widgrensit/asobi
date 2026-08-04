-module(asobi_lua_bot_tests).
-include_lib("eunit/include/eunit.hrl").

%% Direct unit tests for asobi_bot. These complement the
%% integration coverage in asobi_lua_SUITE by exercising the
%% callback-failure paths that the suite currently glosses over:
%% missing think/, throwing think/, infinite-loop think/, and the
%% per-tick degradation policy.

-spec fixture(string()) -> file:filename_all().
fixture(Name) ->
    {ok, LibDir} = safe_lib_dir(),
    filename:absname(filename:join([LibDir, "test", "fixtures", "lua", Name])).

-spec safe_lib_dir() -> {ok, string()}.
safe_lib_dir() ->
    case code:lib_dir(asobi) of
        {error, bad_name} -> error(asobi_not_loaded);
        Dir -> {ok, Dir}
    end.

%% --- think() failure modes ---

bot_loader_succeeds_with_minimal_script_test() ->
    %% A bot script with no `think` function is allowed at load time —
    %% the bot will fall back to default_ai on every tick. We only
    %% verify the loader returns a usable state.
    Path = bot_temp_script(~"return nil\n"),
    try
        ?assertMatch({ok, _}, asobi_lua_loader:new(Path))
    after
        file:delete(Path)
    end.

think_undefined_returns_error_test() ->
    %% Calling a missing think/ via the loader returns an error, which
    %% asobi_bot:send_input/1 then maps to default_ai().
    Path = bot_temp_script(~"return nil\n"),
    try
        {ok, St} = asobi_lua_loader:new(Path),
        ?assertMatch({error, _}, asobi_lua_loader:call(think, [~"bot1", #{}], St, 50))
    after
        file:delete(Path)
    end.

think_raising_returns_error_test() ->
    Path = bot_temp_script(~"function think(_, _) error('boom') end\n"),
    try
        {ok, St} = asobi_lua_loader:new(Path),
        %% Loader catches Lua exceptions and returns {error, _}; the
        %% specific shape (lua_error vs call_failed) varies depending
        %% on which catch arm fires. The bot's send_input/1 only cares
        %% about the {error, _} shape so it can fall back to default_ai.
        ?assertMatch({error, _}, asobi_lua_loader:call(think, [~"bot1", #{}], St, 50))
    after
        file:delete(Path)
    end.

think_infinite_loop_is_terminated_test() ->
    %% asobi_bot uses a 50ms budget for think. A while-true must hit one of
    %% its bounds and produce an error so the bot falls back to default_ai
    %% for that tick rather than hanging the gen_server. Which bound trips
    %% first (deadline or #348's CPU budget) is machine-dependent.
    Path = bot_temp_script(~"function think(_, _) while true do end end\n"),
    try
        {ok, St} = asobi_lua_loader:new(Path),
        Start = erlang:monotonic_time(millisecond),
        Result = asobi_lua_loader:call(think, [~"bot1", #{}], St, 50),
        Elapsed = erlang:monotonic_time(millisecond) - Start,
        ?assert(lists:member(Result, [{error, timeout}, {error, reductions_exhausted}])),
        %% Wall-clock close to 50ms; never near a second.
        ?assert(Elapsed < 500)
    after
        file:delete(Path)
    end.

%% --- think() return-type tolerance ---

think_returning_non_table_falls_back_test() ->
    %% asobi_bot:decode_result/2 turns non-map returns into #{} silently.
    %% Documenting that the bot keeps moving (with default input) rather
    %% than crashing.
    Path = bot_temp_script(~"function think(_, _) return 42 end\n"),
    try
        {ok, St} = asobi_lua_loader:new(Path),
        {ok, [Result | _], _} = asobi_lua_loader:call(think, [~"bot1", #{}], St, 50),
        %% Result is a Luerl-encoded number; the bridge would decode it
        %% to an integer. The bot's downstream decode_result/2 treats
        %% non-list/non-map as #{}.
        ?assert(is_number(Result) orelse is_integer(Result))
    after
        file:delete(Path)
    end.

think_returning_map_works_test() ->
    Path = bot_temp_script(
        ~"""
        function think(bot, state)
            return { right = true, shoot = false }
        end
        """
    ),
    try
        {ok, St} = asobi_lua_loader:new(Path),
        {ok, [Result | _], St1} = asobi_lua_loader:call(think, [~"bot1", #{}], St, 50),
        Decoded = luerl:decode(Result, St1),
        ?assert(is_list(Decoded)),
        ?assertEqual(true, proplists:get_value(~"right", Decoded))
    after
        file:delete(Path)
    end.

%% --- bot_names global ---

names_global_decodes_test() ->
    {ok, St} = asobi_lua_loader:new(fixture("bots/named_bot.lua")),
    {ok, Val, St1} = luerl:get_table_keys([~"names"], St),
    Names = luerl:decode(Val, St1),
    NameList = [V || {_, V} <- Names, is_binary(V)],
    ?assertEqual([~"Spark", ~"Blitz", ~"Volt", ~"Neon", ~"Pulse"], NameList).

names_absent_returns_nil_or_false_test() ->
    {ok, St} = asobi_lua_loader:new(fixture("bots/chaser.lua")),
    case luerl:get_table_keys([~"names"], St) of
        {ok, nil, _} -> ok;
        {ok, false, _} -> ok;
        Other -> ?assert({unexpected, Other} =:= ok)
    end.

%% --- Helpers ---

-spec bot_temp_script(binary()) -> file:filename_all().
bot_temp_script(Code) ->
    Name = "bot_" ++ integer_to_list(erlang:unique_integer([positive])) ++ ".lua",
    Path = filename:join([filename:basedir(user_cache, "asobi_lua_tests"), Name]),
    ok = filelib:ensure_dir(Path),
    ok = file:write_file(Path, Code),
    Path.
