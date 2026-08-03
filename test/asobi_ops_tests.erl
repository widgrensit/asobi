-module(asobi_ops_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("kura/include/kura.hrl").

%%--------------------------------------------------------------------
%% Envelope
%%--------------------------------------------------------------------

envelope_test_() ->
    {setup, fun setup_paginator/0, fun cleanup_paginator/1, [
        fun envelope_shape/0,
        fun envelope_reports_total/0,
        fun envelope_echoes_requested_window/0,
        fun envelope_applies_projection/0,
        fun envelope_translates_offset_to_page/0,
        fun envelope_propagates_repo_error/0
    ]}.

setup_paginator() ->
    meck:new(kura_paginator, [passthrough]),
    ok.

cleanup_paginator(_) ->
    catch meck:unload(kura_paginator),
    ok.

expect_page(Entries, Total) ->
    meck:expect(kura_paginator, paginate, fun(asobi_repo, _Query, Opts) ->
        {ok, #{
            entries => Entries,
            page => maps:get(page, Opts),
            page_size => maps:get(page_size, Opts),
            total_entries => Total,
            total_pages => 1
        }}
    end).

envelope_shape() ->
    expect_page([#{id => ~"a"}], 1),
    {ok, Envelope} = asobi_ops_page:list(query(), #{limit => 50, offset => 0}, fun identity/1),
    ?assertEqual([data, page], lists:sort(maps:keys(Envelope))),
    #{page := Page} = Envelope,
    ?assertEqual([limit, offset, total], lists:sort(maps:keys(Page))).

envelope_reports_total() ->
    expect_page([#{id => ~"a"}, #{id => ~"b"}], 137),
    {ok, #{data := Data, page := Page}} = asobi_ops_page:list(
        query(), #{limit => 2, offset => 0}, fun identity/1
    ),
    ?assertEqual(2, length(Data)),
    ?assertEqual(137, maps:get(total, Page)).

envelope_echoes_requested_window() ->
    expect_page([], 0),
    {ok, #{page := Page}} = asobi_ops_page:list(
        query(), #{limit => 20, offset => 40}, fun identity/1
    ),
    ?assertEqual(#{limit => 20, offset => 40, total => 0}, Page).

envelope_applies_projection() ->
    expect_page([#{id => ~"a", hashed_password => ~"secret"}], 1),
    {ok, #{data := [Row]}} = asobi_ops_page:list(
        query(), #{limit => 50, offset => 0}, fun asobi_ops_players:project/1
    ),
    ?assertEqual(#{id => ~"a"}, Row).

envelope_translates_offset_to_page() ->
    expect_page([], 0),
    meck:reset(kura_paginator),
    {ok, _} = asobi_ops_page:list(query(), #{limit => 25, offset => 50}, fun identity/1),
    [{_, {kura_paginator, paginate, [_, _, Opts]}, _}] = meck:history(kura_paginator),
    ?assertEqual(#{page => 3, page_size => 25}, Opts).

envelope_propagates_repo_error() ->
    meck:expect(kura_paginator, paginate, fun(_, _, _) -> {error, closed} end),
    ?assertEqual(
        {error, closed},
        asobi_ops_page:list(query(), #{limit => 50, offset => 0}, fun identity/1)
    ).

query() ->
    kura_query:order_by(kura_query:from(asobi_player), [{id, desc}]).

identity(Row) -> Row.

%%--------------------------------------------------------------------
%% Player query
%%--------------------------------------------------------------------

players_default_order_is_deterministic_test() ->
    {ok, #kura_query{order_bys = Orders}} = asobi_ops_players:query(#{}),
    ?assertEqual([{inserted_at, desc}, {id, desc}], Orders).

players_sort_uses_allowlisted_atom_test() ->
    {ok, #kura_query{order_bys = Orders}} = asobi_ops_players:query(#{~"sort" => ~"username"}),
    ?assertEqual([{username, asc}, {id, desc}], Orders).

players_reject_unknown_sort_test() ->
    ?assertEqual(
        {error, {unknown_sort, ~"hashed_password"}},
        asobi_ops_players:query(#{~"sort" => ~"hashed_password"})
    ).

players_sortable_fields_are_all_projected_test() ->
    Projected = maps:keys(asobi_ops_players:project(sample_player())),
    [
        ?assert(lists:member(Column, Projected))
     || {_Wire, Column} <- asobi_ops_players:sortable()
    ].

players_search_uses_ilike_on_both_names_test() ->
    {ok, #kura_query{wheres = Wheres}} = asobi_ops_players:query(#{~"q" => ~"kai"}),
    ?assertEqual(
        [{'or', [{username, ilike, ~"%kai%"}, {display_name, ilike, ~"%kai%"}]}],
        Wheres
    ).

players_no_search_no_filter_test() ->
    {ok, #kura_query{wheres = Wheres}} = asobi_ops_players:query(#{}),
    ?assertEqual([], Wheres).

%% The projection is a positive allowlist, so a credential column cannot leak
%% even if a future schema change adds one.
players_projection_drops_credentials_test() ->
    Projected = asobi_ops_players:project(sample_player()),
    ?assertNot(maps:is_key(hashed_password, Projected)),
    ?assertNot(maps:is_key(password, Projected)),
    ?assertNot(maps:is_key(banned_at, Projected)),
    ?assertEqual(~"kaito", maps:get(username, Projected)).

sample_player() ->
    #{
        id => ~"p1",
        username => ~"kaito",
        display_name => ~"Kaito",
        avatar_url => ~"https://example.test/a.png",
        metadata => #{},
        hashed_password => ~"pbkdf2$secret",
        password => ~"hunter2",
        banned_at => undefined,
        inserted_at => {{2026, 8, 3}, {12, 0, 0}},
        updated_at => {{2026, 8, 3}, {12, 0, 0}}
    }.

%%--------------------------------------------------------------------
%% Match query
%%--------------------------------------------------------------------

matches_default_order_is_deterministic_test() ->
    {ok, #kura_query{order_bys = Orders}} = asobi_ops_matches:query(#{}),
    ?assertEqual([{inserted_at, desc}, {id, desc}], Orders).

matches_reject_unknown_sort_test() ->
    ?assertEqual(
        {error, {unknown_sort, ~"players"}},
        asobi_ops_matches:query(#{~"sort" => ~"players"})
    ).

matches_reject_unknown_order_test() ->
    ?assertEqual(
        {error, {unknown_order, ~"random"}},
        asobi_ops_matches:query(#{~"sort" => ~"mode", ~"order" => ~"random"})
    ).

matches_filters_are_equality_on_columns_test() ->
    {ok, #kura_query{wheres = Wheres}} = asobi_ops_matches:query(#{
        ~"mode" => ~"deathmatch", ~"status" => ~"finished"
    }),
    ?assertEqual([{mode, ~"deathmatch"}, {status, ~"finished"}], Wheres).

matches_oversized_filter_is_dropped_test() ->
    {ok, #kura_query{wheres = Wheres}} = asobi_ops_matches:query(#{
        ~"mode" => binary:copy(~"m", 65)
    }),
    ?assertEqual([], Wheres).

matches_projection_drops_roster_test() ->
    Record = #{
        id => ~"m1",
        mode => ~"deathmatch",
        status => ~"finished",
        players => [~"p1", ~"p2"],
        result => #{~"winner" => ~"p1"},
        metadata => #{~"secret" => true},
        started_at => undefined,
        finished_at => undefined,
        inserted_at => {{2026, 8, 3}, {12, 0, 0}}
    },
    Projected = asobi_ops_matches:project(Record),
    ?assertNot(maps:is_key(players, Projected)),
    ?assertNot(maps:is_key(metadata, Projected)),
    ?assertEqual(#{~"winner" => ~"p1"}, maps:get(result, Projected)).

matches_sortable_fields_are_all_projected_test() ->
    Projected = maps:keys(
        asobi_ops_matches:project(#{
            id => ~"m1",
            mode => ~"m",
            status => ~"s",
            result => #{},
            started_at => undefined,
            finished_at => undefined,
            inserted_at => undefined
        })
    ),
    [
        ?assert(lists:member(Column, Projected))
     || {_Wire, Column} <- asobi_ops_matches:sortable()
    ].

%%--------------------------------------------------------------------
%% Routing
%%--------------------------------------------------------------------

%% The ops plane reuses core's bearer check rather than inventing one. If a
%% later edit moves these routes to an unsecured group, this fails.
ops_routes_are_mounted_behind_auth_test() ->
    Groups = asobi_router:routes(dev),
    [
        ?assertEqual(
            {fun asobi_auth_plugin:verify/1, [get, options]},
            route(Groups, ~"/api/v1", Path)
        )
     || Path <- [~"/ops/players", ~"/ops/matches", ~"/ops/features"]
    ].

route(Groups, Prefix, Path) ->
    [Found] = [
        {maps:get(security, Group), maps:get(methods, Opts)}
     || #{prefix := GroupPrefix, routes := Routes} = Group <- Groups,
        GroupPrefix =:= Prefix,
        {RoutePath, _Handler, Opts} <- Routes,
        RoutePath =:= Path
    ],
    Found.

%%--------------------------------------------------------------------
%% Features
%%--------------------------------------------------------------------

features_shape_test() ->
    #{data := Data} = asobi_ops_features:features(),
    ?assertEqual([core, extensions], lists:sort(maps:keys(Data))),
    #{core := Core} = Data,
    ?assertEqual([capabilities, name, version], lists:sort(maps:keys(Core))),
    ?assertEqual(~"asobi", maps:get(name, Core)),
    ?assert(is_binary(maps:get(version, Core))).

features_extensions_empty_until_registry_test() ->
    #{data := #{extensions := Extensions}} = asobi_ops_features:features(),
    ?assertEqual([], Extensions).

features_capabilities_are_name_and_boolean_only_test() ->
    Capabilities = asobi_ops_features:capabilities(),
    ?assert(Capabilities =/= []),
    [
        begin
            ?assertEqual([enabled, name], lists:sort(maps:keys(Capability))),
            ?assert(is_binary(maps:get(name, Capability))),
            ?assert(is_boolean(maps:get(enabled, Capability)))
        end
     || Capability <- Capabilities
    ].

features_capabilities_sorted_by_name_test() ->
    Names = [maps:get(name, Capability) || Capability <- asobi_ops_features:capabilities()],
    ?assertEqual(lists:sort(Names), Names).

features_capability_reflects_configuration_test() ->
    Original = application:get_env(asobi, steam_api_key),
    try
        application:unset_env(asobi, steam_api_key),
        ?assertEqual(false, capability_enabled(~"steam")),
        application:set_env(asobi, steam_api_key, ~"key"),
        ?assertEqual(true, capability_enabled(~"steam"))
    after
        case Original of
            {ok, Value} -> application:set_env(asobi, steam_api_key, Value);
            undefined -> application:unset_env(asobi, steam_api_key)
        end
    end.

capability_enabled(Name) ->
    [Enabled] = [
        E
     || #{name := N, enabled := E} <- asobi_ops_features:capabilities(), N =:= Name
    ],
    Enabled.
