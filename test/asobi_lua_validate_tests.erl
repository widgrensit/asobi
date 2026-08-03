-module(asobi_lua_validate_tests).
-include_lib("eunit/include/eunit.hrl").

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

validate_test_() ->
    [
        {"validate ok on a clean script", fun ok_on_clean/0},
        {"validate fails on syntax error", fun fail_on_syntax/0},
        {"validate fails on missing file", fun fail_on_missing/0}
    ].

ok_on_clean() ->
    ?assertEqual(ok, asobi_lua_validate:validate(fixture("test_match.lua"))).

fail_on_syntax() ->
    ?assertMatch({error, _}, asobi_lua_validate:validate(fixture("bad_script.lua"))).

fail_on_missing() ->
    ?assertMatch(
        {error, {file_error, _, enoent}},
        asobi_lua_validate:validate(fixture("nonexistent.lua"))
    ).
