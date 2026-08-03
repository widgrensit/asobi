-module(asobi_lua_surface_tests).
-include_lib("eunit/include/eunit.hrl").

%% Parity with what asobi_lua_api:install/2 actually creates is asserted in
%% asobi_lua_api_tests (install_creates_reserved/0) - these cover the
%% vocabulary itself.

root_namespace_leads_the_list_test() ->
    [Root | Nested] = asobi_lua_surface:reserved_namespaces(),
    ?assertEqual([~"game"], Root),
    ?assert(
        lists:all(
            fun
                ([~"game", _]) -> true;
                (_) -> false
            end,
            Nested
        )
    ).

reserved_namespaces_are_unique_test() ->
    Reserved = asobi_lua_surface:reserved_namespaces(),
    ?assertEqual(lists:usort(Reserved), lists:sort(Reserved)).

is_reserved_test() ->
    ?assert(asobi_lua_surface:is_reserved([~"game"])),
    ?assert(asobi_lua_surface:is_reserved([~"game", ~"economy"])),
    ?assertNot(asobi_lua_surface:is_reserved([~"game", ~"my_shop"])),
    ?assertNot(asobi_lua_surface:is_reserved([~"economy"])).

name_renders_the_lua_path_test() ->
    ?assertEqual(~"game", asobi_lua_surface:name([~"game"])),
    ?assertEqual(~"game.economy.grant", asobi_lua_surface:name([~"game", ~"economy", ~"grant"])).

effects_test() ->
    ?assertEqual([write, none], asobi_lua_surface:effects()).

vm_kinds_test() ->
    ?assertEqual([match, world, zone, bot], asobi_lua_surface:vm_kinds()).
