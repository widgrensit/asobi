-module(asobi_lua_match_shared_tests).
-include_lib("eunit/include/eunit.hrl").

-spec fixture(string()) -> file:filename_all().
fixture(Name) ->
    {ok, LibDir} = safe_lib_dir(),
    filename:join([LibDir, "test", "fixtures", "lua", Name]).

-spec safe_lib_dir() -> {ok, string()}.
safe_lib_dir() ->
    case code:lib_dir(asobi) of
        {error, bad_name} -> error(asobi_not_loaded);
        Dir -> {ok, Dir}
    end.

shared_match_test_() ->
    [
        {"init delegates to asobi_lua_match", fun init_ok/0},
        {"join/leave/handle_input/tick still work", fun lifecycle/0},
        {"get_state/1 returns Lua's get_state(state) result", fun get_state_one_arg/0}
    ].

init_ok() ->
    Config = #{lua_script => fixture("test_match_shared.lua")},
    {ok, State} = asobi_lua_match_shared:init(Config),
    ?assertMatch(#{lua_state := _, game_state := _}, State).

lifecycle() ->
    Config = #{lua_script => fixture("test_match_shared.lua")},
    {ok, S0} = asobi_lua_match_shared:init(Config),
    {ok, S1} = asobi_lua_match_shared:join(~"p1", S0),
    {ok, S2} = asobi_lua_match_shared:handle_input(~"p1", #{~"action" => ~"noop"}, S1),
    {ok, S3} = asobi_lua_match_shared:tick(S2),
    {ok, _S4} = asobi_lua_match_shared:leave(~"p1", S3).

get_state_one_arg() ->
    Config = #{lua_script => fixture("test_match_shared.lua")},
    {ok, S0} = asobi_lua_match_shared:init(Config),
    {ok, S1} = asobi_lua_match_shared:join(~"p1", S0),
    {ok, S2} = asobi_lua_match_shared:tick(S1),
    Shared = asobi_lua_match_shared:get_state(S2),
    %% Shared payload includes tick count + world data, NOT player_id-keyed
    %% per-player data.
    ?assertMatch(#{~"tick" := _, ~"world" := _}, Shared).
