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
%% In-memory envelope
%%--------------------------------------------------------------------

slice_rows() ->
    [
        #{mode => ~"duel", waiting => 2},
        #{mode => ~"arena", waiting => 9},
        #{mode => ~"coop", waiting => 2}
    ].

%% A console must not be able to tell a process-backed list from a
%% table-backed one.
slice_envelope_matches_the_query_envelope_test() ->
    Envelope = asobi_ops_page:slice(
        slice_rows(), [{waiting, desc}, {mode, asc}], #{limit => 50, offset => 0}, fun identity/1
    ),
    ?assertEqual([data, page], lists:sort(maps:keys(Envelope))),
    ?assertEqual(#{limit => 50, offset => 0, total => 3}, maps:get(page, Envelope)).

slice_orders_before_it_windows_test() ->
    #{data := Data} = asobi_ops_page:slice(
        slice_rows(), [{waiting, desc}, {mode, asc}], #{limit => 2, offset => 0}, fun identity/1
    ),
    ?assertEqual([~"arena", ~"coop"], [Mode || #{mode := Mode} <- Data]).

%% The tie-breaker earning its place: `coop` and `duel` are both waiting 2, and
%% the second page must continue where the first stopped rather than repeat a
%% row the map happened to yield first.
slice_offset_does_not_repeat_a_tied_row_test() ->
    Orders = [{waiting, desc}, {mode, asc}],
    #{data := First} = asobi_ops_page:slice(
        slice_rows(), Orders, #{limit => 2, offset => 0}, fun identity/1
    ),
    #{data := Second} = asobi_ops_page:slice(
        slice_rows(), Orders, #{limit => 2, offset => 2}, fun identity/1
    ),
    ?assertEqual([~"arena", ~"coop", ~"duel"], [Mode || #{mode := Mode} <- First ++ Second]).

slice_total_counts_every_row_not_the_page_test() ->
    #{page := Page} = asobi_ops_page:slice(
        slice_rows(), [{mode, asc}], #{limit => 1, offset => 0}, fun identity/1
    ),
    ?assertEqual(3, maps:get(total, Page)).

slice_offset_past_the_end_is_an_empty_page_test() ->
    Envelope = asobi_ops_page:slice(
        slice_rows(), [{mode, asc}], #{limit => 10, offset => 100}, fun identity/1
    ),
    ?assertEqual(#{data => [], page => #{limit => 10, offset => 100, total => 3}}, Envelope).

slice_applies_projection_test() ->
    #{data := [Row | _]} = asobi_ops_page:slice(
        [#{mode => ~"arena", waiting => 1, player_id => ~"p1"}],
        [{mode, asc}],
        #{limit => 10, offset => 0},
        fun asobi_ops_matchmaker:project/1
    ),
    ?assertNot(maps:is_key(player_id, Row)).

%% Sorting a row set that has gained a field must not drop the rows that
%% predate it.
slice_treats_a_missing_key_as_undefined_test() ->
    #{data := Data} = asobi_ops_page:slice(
        [#{mode => ~"arena"}, #{mode => ~"duel", waiting => 1}],
        [{waiting, asc}, {mode, asc}],
        #{limit => 10, offset => 0},
        fun identity/1
    ),
    ?assertEqual(2, length(Data)).

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

%% The ops plane has its own identity (ADR 0007). If a later edit moves these
%% routes back onto the player-scoped check - which admits any player, guest
%% included - or into an unsecured group, this fails.
%%
%% Enumerated from the group rather than listed, so a route added without a
%% thought for its security is caught here rather than merged.
ops_routes_are_mounted_behind_the_operator_check_test() ->
    #{security := Security, routes := Routes} = ops_group(),
    ?assertEqual(fun asobi_ops_auth:verify/1, Security),
    ?assert(Routes =/= []),
    [
        begin
            Methods = maps:get(methods, Opts),
            ?assert(lists:member(options, Methods)),
            ?assertEqual([], Methods -- [get, post, options])
        end
     || {_Path, _Handler, Opts} <- Routes
    ].

%% This was `ops_plane_serves_no_write_method_test/0`, which asserted the plane
%% served no write route at all - deliberately, so that opening it had to be a
%% conscious act rather than a route someone added. The write plane makes that
%% statement false and this is the narrower one it was standing in for: a
%% route's method and its capability class must agree.
%%
%% A `read`-classed route may only be a GET, so a mutation cannot ship under
%% the class every operator credential holds; and a GET may only be `read`, so
%% a listing cannot be tagged `player_data` and quietly become unreachable for
%% a viewer. Together with `ops_routes_and_capability_classes_agree_test/0`,
%% which holds the table and the router to each other, a write route added
%% without a class - or with the wrong one - fails the build.
ops_route_method_and_capability_class_agree_test() ->
    Classes = asobi_ops_caps:classes(),
    ?assertEqual([], [Route || {get, _S, Class} = Route <- Classes, Class =/= read]),
    ?assertEqual([], [Route || {Method, _S, read} = Route <- Classes, Method =/= get]),
    %% Non-vacuous: there really is a write route to have got this wrong.
    ?assert(lists:any(fun({Method, _S, _C}) -> Method =/= get end, Classes)).

%% Every write route is `player_data` or `config`, and both classes are used.
%% ADR 0007 predicted this split; until the write plane landed neither class
%% had a single route, so nothing held the table to the ADR.
ops_write_routes_use_both_mutating_classes_test() ->
    Classes = lists:usort([
        Class
     || {Method, _S, Class} <- asobi_ops_caps:classes(), Method =/= get
    ]),
    ?assertEqual([config, player_data], Classes).

ops_group() ->
    [Group] = [G || #{prefix := ~"/api/v1/ops"} = G <- asobi_router:routes(dev)],
    Group.

no_ops_route_sits_in_the_player_scoped_group_test() ->
    [
        ?assertEqual([], [Path || {Path, _Handler, _Opts} <- Routes, ops_path(Path)])
     || #{prefix := Prefix, routes := Routes} <- asobi_router:routes(dev), Prefix =/= ~"/api/v1/ops"
    ].

ops_path(<<"/ops", _/binary>>) -> true;
ops_path(_Path) -> false.

%% Every ops route carries exactly one capability class, and the class table
%% carries no route the router does not serve. An untagged route is denied at
%% runtime, so this is the check that turns that denial into a build failure.
ops_routes_and_capability_classes_agree_test() ->
    Routed = lists:sort([
        {Method, [binding_or_literal(S) || S <- binary:split(Path, ~"/", [global, trim_all])]}
     || #{prefix := ~"/api/v1/ops", routes := Routes} <- asobi_router:routes(dev),
        {Path, _Handler, Opts} <- Routes,
        Method <- maps:get(methods, Opts),
        Method =/= options
    ]),
    Tagged = lists:sort([{Method, Segments} || {Method, Segments, _} <- asobi_ops_caps:classes()]),
    ?assertEqual(Tagged, Routed).

%% The router spells a bound segment `:id`; the class table spells it `'_'`,
%% because it matches against a real request path where the binding is already
%% a value. Normalise so the two are comparable without weakening the check.
binding_or_literal(<<":", _/binary>>) -> '_';
binding_or_literal(Segment) -> Segment.

%%--------------------------------------------------------------------
%% Lookup by id
%%--------------------------------------------------------------------

lookup_test_() ->
    {setup, fun setup_repo/0, fun cleanup_repo/1, [
        fun lookup_projects_the_row/0,
        fun lookup_reports_a_miss_as_not_found/0,
        fun lookup_reports_a_failed_read_separately/0
    ]}.

setup_repo() ->
    meck:new(asobi_repo, [passthrough]),
    ok.

cleanup_repo(_) ->
    catch meck:unload(asobi_repo),
    ok.

%% The lookup must not be able to return a field the list would have
%% withheld, so it runs the same projection.
lookup_projects_the_row() ->
    meck:expect(asobi_repo, get, fun(asobi_player, _Id) -> {ok, sample_player()} end),
    {ok, Row} = asobi_ops_lookup:fetch(
        asobi_player, ~"0197f3d0-1c2b-7000-8000-000000000001", fun asobi_ops_players:project/1
    ),
    ?assertNot(maps:is_key(hashed_password, Row)),
    ?assertEqual(~"kaito", maps:get(username, Row)).

lookup_reports_a_miss_as_not_found() ->
    meck:expect(asobi_repo, get, fun(_Schema, _Id) -> {error, not_found} end),
    ?assertEqual(
        {error, not_found},
        asobi_ops_lookup:fetch(
            asobi_player, ~"0197f3d0-1c2b-7000-8000-000000000001", fun identity/1
        )
    ).

%% A dropped connection is a 500 and a miss is a 404; collapsing the two
%% would report the database being down as "no such player".
lookup_reports_a_failed_read_separately() ->
    meck:expect(asobi_repo, get, fun(_Schema, _Id) -> {error, closed} end),
    ?assertEqual(
        {error, {query_failed, closed}},
        asobi_ops_lookup:fetch(
            asobi_player, ~"0197f3d0-1c2b-7000-8000-000000000001", fun identity/1
        )
    ).

%% A binding that is not uuid-shaped must not reach Postgres: it raises
%% there, which would turn a malformed request into a 500.
lookup_rejects_a_malformed_id_without_a_query_test() ->
    ?assertEqual(
        {error, invalid_id},
        asobi_ops_lookup:fetch(asobi_player, ~"'; drop table players --", fun identity/1)
    ).

lookup_rejects_a_missing_id_test() ->
    ?assertEqual({error, invalid_id}, asobi_ops_lookup:fetch(asobi_player, ~"", fun identity/1)).

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

features_extensions_are_empty_when_none_are_installed_test() ->
    #{data := #{extensions := Extensions}} = asobi_ops_features:features(),
    ?assertEqual([], Extensions).

%% The endpoint the console reads to decide which of its built-in screens to
%% render. It reported `[]` unconditionally until the registry landed, which
%% would have left every extension screen dark with nothing to debug.
features_reports_the_resolved_extension_set_test() ->
    meck:new(asobi_extensions, [passthrough]),
    try
        meck:expect(asobi_extensions, resolve, fun() -> [fake_extension()] end),
        #{data := #{extensions := [Extension]}} = asobi_ops_features:features(),
        ?assertEqual([capabilities, name, version], lists:sort(maps:keys(Extension))),
        ?assertEqual(~"quests", maps:get(name, Extension)),
        ?assert(is_binary(maps:get(version, Extension))),
        ?assertNotEqual(~"unknown", maps:get(version, Extension)),
        ?assertEqual(
            [{~"lua", false}, {~"rpc", true}, {~"tables", true}],
            [{N, E} || #{name := N, enabled := E} <- maps:get(capabilities, Extension)]
        )
    after
        meck:unload(asobi_extensions)
    end.

%% Same shape as the `core` entry, so a console reads one row type.
features_extension_shape_matches_core_test() ->
    meck:new(asobi_extensions, [passthrough]),
    try
        meck:expect(asobi_extensions, resolve, fun() -> [fake_extension()] end),
        #{data := #{core := Core, extensions := [Extension]}} = asobi_ops_features:features(),
        ?assertEqual(lists:sort(maps:keys(Core)), lists:sort(maps:keys(Extension)))
    after
        meck:unload(asobi_extensions)
    end.

%% `kernel` so the reported version is a real application version rather than
%% the `unknown` fallback.
fake_extension() ->
    #{
        app => kernel,
        module => fake_quests_extension,
        name => ~"quests",
        extension_version => 1,
        rpc => #{~"quests.claim" => {fake_quests_rpc, claim, 2}},
        lua => #{},
        owns => #{tables => [~"quests"], rpc => [~"quests"]},
        codes => #{}
    }.

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
