-module(asobi_extension_reserved_tests).

-include_lib("eunit/include/eunit.hrl").

kinds_are_the_five_namespaces_owns_declares_test() ->
    ?assertEqual([http, lua, queues, rpc, tables], lists:sort(asobi_extension_reserved:kinds())).

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

%% `seasons` left core for asobi_seasons, but its CREATE TABLE stayed in
%% m20260412172429 - it shares that file with zone_snapshots and the migration
%% has run against live databases. Re-adding a core schema for it would reserve
%% the name and make the extension's owns/0 claim invalid at boot.
seasons_is_no_longer_reserved_test() ->
    #{tables := Reserved} = asobi_extension_reserved:namespaces(),
    ?assertNot(lists:member(~"seasons", Reserved)),
    _ = application:load(asobi),
    {ok, Modules} = application:get_key(asobi, modules),
    ?assertNot(lists:member(asobi_season, Modules)),
    ?assertNot(lists:member(asobi_season_manager, Modules)).

queues_come_from_core_shigoto_workers_test() ->
    #{queues := Reserved} = asobi_extension_reserved:namespaces(),
    ?assertEqual([asobi_broadcast_worker:queue()], Reserved).

%% Derived from core's own route table - `asobi_router:core_routes/0`, the
%% groups without the extension mounts - so a route core gains is reserved
%% here with no second edit, and resolving inside Nova's boot cannot re-enter
%% the resolver to read it.
http_paths_come_from_the_core_route_table_test() ->
    #{http := Reserved} = asobi_extension_reserved:namespaces(),
    [
        ?assert(lists:member(Path, Reserved))
     || Path <- [
            ~"/api/v1/matches/:id",
            ~"/api/v1/auth/register",
            ~"/api/v1/ops/ext/:extension/:action",
            ~"/console",
            ~"/ws"
        ]
    ],
    ?assertNot(lists:member(~"/api/v1/quests/board", Reserved)).

%% The compiled dispatch is [nova, asobi | nova_apps] and the first insert of
%% a path wins, so a co-mounted app's paths - nova_resilience answers the
%% k8s probes in both shipped configs - must be as unclaimable as core's own.
http_paths_cover_every_co_mounted_app_test() ->
    application:set_env(nova, bootstrap_application, asobi),
    application:set_env(asobi, nova_apps, [nova_resilience]),
    try
        #{http := Reserved} = asobi_extension_reserved:namespaces(),
        [?assert(lists:member(P, Reserved)) || P <- [~"/health", ~"/ready", ~"/live"]],
        %% nova_resilience mounts under its configured prefix, and the
        %% reserved set derives through the same routes/1 call, so the two
        %% cannot disagree about where the probes live.
        application:set_env(nova_resilience, health_prefix, ~"/probes"),
        #{http := Prefixed} = asobi_extension_reserved:namespaces(),
        ?assert(lists:member(~"/probes/health", Prefixed)),
        ?assertNot(lists:member(~"/health", Prefixed))
    after
        application:unset_env(nova_resilience, health_prefix),
        application:unset_env(asobi, nova_apps),
        application:unset_env(nova, bootstrap_application)
    end.

%% A policy list, not a derivation: which plane roots are closed to
%% extensions outright is a judgment the route table cannot express.
the_privileged_plane_prefixes_test() ->
    ?assertEqual(
        [~"/api/v1/ops", ~"/api/v1/auth", ~"/api/v1/iap", ~"/api/v1/rpc", ~"/console", ~"/ws"],
        asobi_extension_reserved:route_prefixes()
    ).

%% An RPC prefix and an error-code domain are the same token by construction,
%% so core's closed code set reserves the prefixes too.
rpc_prefixes_cover_error_domains_and_lua_test() ->
    #{rpc := Reserved, lua := Lua} = asobi_extension_reserved:namespaces(),
    ?assert(lists:member(~"storage", Reserved)),
    ?assert(lists:member(~"matchmaker", Reserved)),
    [?assert(lists:member(N, Reserved)) || N <- Lua],
    ?assertNot(lists:member(~"quests", Reserved)).

%% session.*, presence.* and module.* are core wire frame families with no
%% error domain and no Lua namespace, so error_domains/0 and lua/0 miss their
%% prefixes. core_wire_prefixes/0 folds them into the rpc union. Anti-drift:
%% every prefix the constant names must land in the reserved rpc set, so a
%% frame family added to the constant later cannot be silently unreserved.
core_wire_prefixes_are_reserved_rpc_prefixes_test() ->
    #{rpc := Reserved} = asobi_extension_reserved:namespaces(),
    [
        ?assert(lists:member(Prefix, Reserved))
     || Prefix <- asobi_extension_reserved:core_wire_prefixes()
    ],
    ?assert(lists:member(~"session", Reserved)),
    ?assert(lists:member(~"presence", Reserved)),
    ?assert(lists:member(~"module", Reserved)).

%% Deleting this env key silently removes `rebar3 asobi check` from every host.
the_build_time_gate_is_declared_to_rebar3_test() ->
    _ = application:load(asobi),
    {ok, Env} = application:get_key(asobi, env),
    Providers = proplists:get_value(providers, Env),
    ?assert(lists:member(rebar3_asobi_check, Providers)),
    Exports = rebar3_asobi_check:module_info(exports),
    [?assert(lists:member(E, Exports)) || E <- [{init, 1}, {do, 1}, {format_error, 1}]].

%% The console builder ships through the same env key, so dropping it would
%% silently remove `rebar3 asobi console` the same way.
the_console_builder_is_declared_to_rebar3_test() ->
    _ = application:load(asobi),
    {ok, Env} = application:get_key(asobi, env),
    Providers = proplists:get_value(providers, Env),
    ?assert(lists:member(rebar3_asobi_console, Providers)),
    Exports = rebar3_asobi_console:module_info(exports),
    [?assert(lists:member(E, Exports)) || E <- [{init, 1}, {do, 1}, {format_error, 1}]].
