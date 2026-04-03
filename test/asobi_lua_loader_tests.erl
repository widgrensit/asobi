-module(asobi_lua_loader_tests).
-include_lib("eunit/include/eunit.hrl").

fixture(Name) ->
    filename:absname(
        filename:join([code:lib_dir(asobi), "test", "fixtures", "lua", Name])
    ).

%% --- Loader tests ---

loader_test_() ->
    [
        {"loads valid script", fun loads_valid_script/0},
        {"returns error for missing file", fun missing_file_error/0},
        {"returns error for syntax error", fun syntax_error/0},
        {"call executes lua function", fun call_function/0},
        {"call with atom name", fun call_atom_name/0},
        {"call returns error for undefined function", fun call_undefined_function/0},
        {"require loads submodule", fun require_loads_submodule/0},
        {"call with timeout succeeds", fun call_with_timeout_ok/0},
        {"math.random works", fun math_random_works/0},
        {"math.sqrt works", fun math_sqrt_works/0}
    ].

loads_valid_script() ->
    {ok, _St} = asobi_lua_loader:new(fixture("test_match.lua")).

missing_file_error() ->
    {error, {file_error, _, enoent}} = asobi_lua_loader:new(fixture("nonexistent.lua")).

syntax_error() ->
    {error, _} = asobi_lua_loader:new(fixture("bad_script.lua")).

call_function() ->
    {ok, St0} = asobi_lua_loader:new(fixture("test_match.lua")),
    %% Encode the config map before passing to Lua
    {Cfg, St1} = luerl:encode(#{}, St0),
    {ok, [State | _], _St2} = asobi_lua_loader:call(init, [Cfg], St1),
    ?assert(is_map(State) orelse is_list(State) orelse is_tuple(State)).

call_atom_name() ->
    {ok, St0} = asobi_lua_loader:new(fixture("test_match.lua")),
    {Cfg, St1} = luerl:encode(#{}, St0),
    {ok, [State | _], _St2} = asobi_lua_loader:call(init, [Cfg], St1),
    ?assert(is_map(State) orelse is_list(State) orelse is_tuple(State)).

call_undefined_function() ->
    {ok, St} = asobi_lua_loader:new(fixture("test_match.lua")),
    {error, _} = asobi_lua_loader:call(nonexistent_function, [], St).

require_loads_submodule() ->
    %% test_match.lua does require("boons") — if it loads, require works
    {ok, St0} = asobi_lua_loader:new(fixture("test_match.lua")),
    {Cfg, St1} = luerl:encode(#{}, St0),
    {ok, _, _} = asobi_lua_loader:call(init, [Cfg], St1).

call_with_timeout_ok() ->
    {ok, St0} = asobi_lua_loader:new(fixture("test_match.lua")),
    {Cfg, St1} = luerl:encode(#{}, St0),
    {ok, [_ | _], _} = asobi_lua_loader:call(init, [Cfg], St1, 5000).

math_random_works() ->
    {ok, St} = asobi_lua_loader:new(fixture("test_match.lua")),
    {ok, [Result | _], _} = asobi_lua_loader:call(
        [<<"math">>, <<"random">>], [10], St
    ),
    ?assert(is_number(Result)),
    ?assert(Result >= 1 andalso Result =< 10).

math_sqrt_works() ->
    {ok, St} = asobi_lua_loader:new(fixture("test_match.lua")),
    {ok, [Result | _], _} = asobi_lua_loader:call(
        [<<"math">>, <<"sqrt">>], [16.0], St
    ),
    ?assertEqual(4.0, Result).
