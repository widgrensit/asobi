-module(asobi_extension_reserved_tests).

-include_lib("eunit/include/eunit.hrl").

kinds_are_the_four_namespaces_owns_declares_test() ->
    ?assertEqual([lua, queues, rpc, tables], lists:sort(asobi_extension_reserved:kinds())).

%% Derived from asobi_lua_surface, the one place the `game.*` vocabulary is
%% written down, so adding a core namespace there reserves it here with no
%% second edit.
lua_namespaces_come_from_the_surface_module_test() ->
    #{lua := Reserved} = asobi_extension_reserved:namespaces(),
    Expected = [N || [~"game", N] <- asobi_lua_surface:reserved_namespaces()],
    ?assertNotEqual([], Expected),
    [?assert(lists:member(N, Reserved)) || N <- Expected],
    ?assert(lists:member(~"economy", Reserved)),
    %% `game` is the root every namespace hangs off; no extension may own it.
    ?assert(lists:member(~"game", Reserved)).

%% Derived from core's kura_schema modules, found the same way asobi finds an
%% extension's schemas.
tables_come_from_core_schemas_test() ->
    #{tables := Reserved} = asobi_extension_reserved:namespaces(),
    ?assert(lists:member(asobi_player:table(), Reserved)),
    ?assert(lists:member(asobi_wallet:table(), Reserved)),
    ?assertNot(lists:member(~"quests", Reserved)).

queues_come_from_core_shigoto_workers_test() ->
    #{queues := Reserved} = asobi_extension_reserved:namespaces(),
    ?assertEqual([asobi_broadcast_worker:queue()], Reserved).

%% An RPC prefix and an error-code domain are the same token by construction,
%% so core's closed code set reserves the prefixes too.
rpc_prefixes_cover_error_domains_and_lua_test() ->
    #{rpc := Reserved, lua := Lua} = asobi_extension_reserved:namespaces(),
    ?assert(lists:member(~"storage", Reserved)),
    ?assert(lists:member(~"matchmaker", Reserved)),
    [?assert(lists:member(N, Reserved)) || N <- Lua],
    ?assertNot(lists:member(~"quests", Reserved)).

%% Deleting this env key silently removes `rebar3 asobi check` from every host.
the_build_time_gate_is_declared_to_rebar3_test() ->
    _ = application:load(asobi),
    {ok, Env} = application:get_key(asobi, env),
    ?assertEqual([rebar3_asobi_check], proplists:get_value(providers, Env)),
    Exports = rebar3_asobi_check:module_info(exports),
    [?assert(lists:member(E, Exports)) || E <- [{init, 1}, {do, 1}, {format_error, 1}]].
