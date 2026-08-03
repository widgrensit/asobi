-module(asobi_lua_decode_tests).
-include_lib("eunit/include/eunit.hrl").

decode_to_map_test_() ->
    {foreach, fun setup/0, fun cleanup/1, [
        {"empty Lua table -> empty Erlang map", fun empty_table_to_empty_map/0},
        {"map-shaped table -> map", fun map_table_to_map/0},
        {"nested map-shaped table -> nested map", fun nested_map_to_map/0},
        {"list-shaped table -> empty map + warning", fun list_table_to_empty_map/0}
    ]}.

setup() ->
    {ok, asobi_lua_loader:init_sandboxed()}.

cleanup(_) ->
    ok.

empty_table_to_empty_map() ->
    {ok, St0} = setup(),
    {ok, [Tbl | _], St1} = luerl:do(<<"return {}">>, St0),
    ?assertEqual(#{}, asobi_lua_api:decode_to_map(Tbl, St1)).

map_table_to_map() ->
    {ok, St0} = setup(),
    {ok, [Tbl | _], St1} = luerl:do(<<"return { x = 1, y = 2 }">>, St0),
    ?assertEqual(#{~"x" => 1, ~"y" => 2}, asobi_lua_api:decode_to_map(Tbl, St1)).

nested_map_to_map() ->
    {ok, St0} = setup(),
    {ok, [Tbl | _], St1} = luerl:do(
        <<"return { p1 = { x = 10, y = 20 }, p2 = { x = 30, y = 40 } }">>, St0
    ),
    Result = asobi_lua_api:decode_to_map(Tbl, St1),
    ?assertEqual(#{~"x" => 10, ~"y" => 20}, maps:get(~"p1", Result)),
    ?assertEqual(#{~"x" => 30, ~"y" => 40}, maps:get(~"p2", Result)).

list_table_to_empty_map() ->
    {ok, St0} = setup(),
    {ok, [Tbl | _], St1} = luerl:do(<<"return { 'a', 'b', 'c' }">>, St0),
    ?assertEqual(#{}, asobi_lua_api:decode_to_map(Tbl, St1)).
