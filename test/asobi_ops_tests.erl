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

%% The list an operator reads before purging that cohort has to agree with the
%% purge itself, so it narrows on the purge's own predicate rather than a
%% second reading of "is this a guest".
players_guest_filter_uses_the_purge_predicate_test() ->
    {ok, #kura_query{wheres = Wheres}} = asobi_ops_players:query(#{~"guest" => ~"true"}),
    ?assertEqual([asobi_guest_purge:clause(undefined)], Wheres).

players_guest_false_negates_the_same_predicate_test() ->
    {ok, #kura_query{wheres = Wheres}} = asobi_ops_players:query(#{~"guest" => ~"false"}),
    ?assertEqual([{'not', asobi_guest_purge:clause(undefined)}], Wheres).

%% An absent or unparseable value narrows nothing, the same as every other
%% filter on this plane: a caller gets a superset and the rows to prove it.
players_guest_filter_absent_narrows_nothing_test() ->
    {ok, #kura_query{wheres = None}} = asobi_ops_players:query(#{}),
    {ok, #kura_query{wheres = Junk}} = asobi_ops_players:query(#{~"guest" => ~"maybe"}),
    ?assertEqual([], None),
    ?assertEqual([], Junk).

%% The list filter must not carry a cutoff. A purge deletes only guests older
%% than one; a list that quietly applied the same cutoff would hide the guests
%% an operator is about to be told are in the set.
players_guest_filter_has_no_cutoff_test() ->
    {ok, #kura_query{wheres = [Clause]}} = asobi_ops_players:query(#{~"guest" => ~"true"}),
    ?assertEqual(asobi_guest_purge:clause(undefined), Clause),
    ?assertNotEqual(asobi_guest_purge:clause({{2026, 1, 1}, {0, 0, 0}}), Clause).

players_guest_filter_composes_with_search_test() ->
    {ok, #kura_query{wheres = Wheres}} = asobi_ops_players:query(
        #{~"q" => ~"kai", ~"guest" => ~"true"}
    ),
    ?assertEqual(
        [
            {'or', [{username, ilike, ~"%kai%"}, {display_name, ilike, ~"%kai%"}]},
            asobi_guest_purge:clause(undefined)
        ],
        Wheres
    ).

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
        ?assertEqual(expected_methods(Path), maps:get(methods, Opts))
     || {Path, _Handler, Opts} <- Routes, not extension_route(Path)
    ].

%% The two routes on core's plane that answer a write method, stated here so a
%% third cannot appear without editing these lines.
expected_methods(~"/players/:id/erase") -> [post, options];
expected_methods(~"/players/guests/purge") -> [post, options];
expected_methods(_Path) -> [get, options].

%% Core's plane is a read plane plus account-lifecycle routes, and
%% `asobi_ops_notifications:broadcast/5` is still deliberately not a route at
%% all. Anything else non-read is a write surface that grew by accident.
%%
%% `erasure` is its own class rather than `player_data` because it is the only
%% irreversible action here; `export` is `player_data` rather than `read`
%% because it returns everything about one identified person. The guest purge
%% shares `erasure` with the single erase on purpose: same action, wider
%% fan-out, and a capability that separated them would read as "may erase, but
%% only slowly".
core_ops_non_read_classes_are_only_account_lifecycle_test() ->
    ?assertEqual(
        [
            {get, [~"players", '_', ~"export"], player_data},
            {post, [~"players", '_', ~"erase"], erasure},
            {post, [~"players", ~"guests", ~"purge"], erasure}
        ],
        [Route || {_M, _S, Class} = Route <- asobi_ops_caps:classes(), Class =/= read]
    ).

%% Stated once so it cannot widen quietly: three routes carry a write method,
%% the two erasures and the extension dispatch. None is an exception to the
%% audit - the extension dispatch runs inside `asobi_ops_audit:mutation/4`, the
%% single erasure writes its row inside its own transaction, and the guest
%% purge writes one row for the batch once the deletes have committed.
ops_routes_carrying_a_write_method_test() ->
    #{routes := Routes} = ops_group(),
    Writing = [
        Path
     || {Path, _Handler, Opts} <- Routes,
        [] =/= [M || M <- maps:get(methods, Opts), M =/= get, M =/= options]
    ],
    ?assertEqual(
        [~"/players/:id/erase", ~"/players/guests/purge", ~"/ext/:extension/:action"], Writing
    ).

%% asobi#326: routing_tree returns on the first matching sibling and a binding
%% matches any segment, so `/players/:id` declared first would not swallow a
%% deeper path - but the ordering is load-bearing enough elsewhere in this
%% table that it is pinned rather than assumed.
erase_and_export_are_declared_before_the_player_binding_test() ->
    #{routes := Routes} = ops_group(),
    Paths = [Path || {Path, _Handler, _Opts} <- Routes],
    ?assert(index_of(~"/players/:id/erase", Paths) < index_of(~"/players/:id", Paths)),
    ?assert(index_of(~"/players/:id/export", Paths) < index_of(~"/players/:id", Paths)).

%% The other half of asobi#326, and the direction that actually bites: a
%% *literal* segment where a sibling route has a binding must be declared
%% AFTER it, because prepend-on-insert then puts the literal in front and it is
%% tried first. Declared before, `:id` matches "guests", the lookup commits to
%% that subtree, finds no "purge" under it and 404s a route that exists.
guest_purge_is_declared_after_the_player_binding_test() ->
    #{routes := Routes} = ops_group(),
    Paths = [Path || {Path, _Handler, _Opts} <- Routes],
    ?assert(index_of(~"/players/guests/purge", Paths) > index_of(~"/players/:id", Paths)),
    ?assert(index_of(~"/players/guests/purge", Paths) > index_of(~"/players/:id/erase", Paths)).

index_of(Needle, List) ->
    length(lists:takewhile(fun(Item) -> Item =/= Needle end, List)).

ops_group() ->
    [Group] = [G || #{prefix := ~"/api/v1/ops"} = G <- asobi_router:routes(dev)],
    Group.

no_ops_route_sits_in_the_player_scoped_group_test() ->
    [
        ?assertEqual([], [Path || {Path, _Handler, _Opts} <- Routes, ops_path(Path)])
     || #{prefix := Prefix, routes := Routes} <- asobi_router:routes(dev), Prefix =/= ~"/api/v1/ops"
    ].

extension_route(~"/ext/:extension/:action") -> true;
extension_route(_Path) -> false.

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
        not extension_route(Path),
        Method <- maps:get(methods, Opts),
        Method =/= options
    ]),
    Tagged = lists:sort([{Method, Segments} || {Method, Segments, _} <- asobi_ops_caps:classes()]),
    ?assertEqual(Tagged, Routed).

%% The extension dispatch is the one route with no entry in `classes/0`,
%% because its class is per action and lives in the manifest that also declares
%% the handler. Excluded above, so it is checked here instead: an action nobody
%% declared has no class, which is what denies it.
extension_route_is_classed_by_the_manifest_test() ->
    asobi_extensions:reset(),
    ?assertEqual(
        undefined,
        asobi_ops_caps:class(~"POST", ~"/api/v1/ops/ext/quests/define")
    ),
    ?assertEqual(
        undefined,
        asobi_ops_caps:class(~"GET", ~"/api/v1/ops/ext/nothing/at-all")
    ).

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
            [
                {~"console", false},
                {~"lua", false},
                {~"ops", false},
                {~"rpc", true},
                {~"tables", true}
            ],
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
        ops => #{},
        lua => #{},
        owns => #{tables => [~"quests"], rpc => [~"quests"]},
        codes => #{}
    }.

%% `ops` says the extension has an operator surface at all; `console` says it
%% ships the screens that drive it. They are separate because they fail
%% separately, and the pair is the only thing that distinguishes an extension
%% whose console bundle was never recomposed from one that has no UI.
features_reports_the_ops_and_console_seams_test() ->
    meck:new(asobi_extensions, [passthrough]),
    try
        WithOps = (fake_extension())#{
            ops => #{~"define" => #{method => post, mfa => {m, f, 2}, class => config}}
        },
        meck:expect(asobi_extensions, resolve, fun() -> [WithOps] end),
        #{data := #{extensions := [Extension]}} = asobi_ops_features:features(),
        ?assertEqual(
            [
                {~"console", false},
                {~"lua", false},
                {~"ops", true},
                {~"rpc", true},
                {~"tables", true}
            ],
            [{N, E} || #{name := N, enabled := E} <- maps:get(capabilities, Extension)]
        )
    after
        meck:unload(asobi_extensions)
    end.

%% asobi ships priv/console, but the console *bundle*, not console source at
%% priv/console/index.jsx, so core is not mistaken for an extension with
%% screens by the file check that answers this.
features_console_capability_is_the_extensions_own_source_test() ->
    meck:new(asobi_extensions, [passthrough]),
    try
        meck:expect(asobi_extensions, resolve, fun() -> [(fake_extension())#{app => asobi}] end),
        #{data := #{extensions := [Extension]}} = asobi_ops_features:features(),
        ?assertEqual(
            [false],
            [E || #{name := ~"console", enabled := E} <- maps:get(capabilities, Extension)]
        )
    after
        meck:unload(asobi_extensions)
    end.

%% The other side of the check above. Without this, `index.jsx` could be
%% misspelt in the join and every extension would report `false` for ever -
%% which is exactly the diagnosis the capability exists to give.
features_console_capability_is_true_for_an_extension_that_ships_screens_test() ->
    App = console_fixture_app(),
    meck:new(asobi_extensions, [passthrough]),
    try
        meck:expect(asobi_extensions, resolve, fun() -> [(fake_extension())#{app => App}] end),
        #{data := #{extensions := [Extension]}} = asobi_ops_features:features(),
        ?assertEqual(
            [true],
            [E || #{name := ~"console", enabled := E} <- maps:get(capabilities, Extension)]
        )
    after
        meck:unload(asobi_extensions)
    end.

%% An application on the code path whose priv/console/index.jsx exists, which
%% is the whole of what the capability answers.
console_fixture_app() ->
    App = list_to_atom(
        "asobi_fixture_console_" ++ integer_to_list(erlang:unique_integer([positive]))
    ),
    Root = filename:join(["/tmp", "asobi_ops_tests", atom_to_list(App)]),
    Console = filename:join([Root, "priv", "console"]),
    ok = filelib:ensure_path(Console),
    ok = filelib:ensure_path(filename:join(Root, "ebin")),
    ok = file:write_file(filename:join(Console, "index.jsx"), ~"export default {};"),
    true = code:add_pathz(filename:join(Root, "ebin")),
    App.

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

%% guest_auth is a two-layer flag, so the capability goes through
%% asobi_game_config:guest_auth/0 rather than "is the key set" - which reported
%% `true` for a key set to `false`, and the boot-time config load set exactly
%% that on every node without a Lua bundle (ADR 0011).
features_guest_auth_capability_reads_both_layers_test() ->
    Saved = [{K, application:get_env(asobi, K)} || K <- [guest_auth, script_guest_auth]],
    try
        [application:unset_env(asobi, K) || K <- [guest_auth, script_guest_auth]],
        ?assertEqual(false, capability_enabled(~"guest_auth")),

        %% The game's own declaration is enough.
        application:set_env(asobi, script_guest_auth, true),
        ?assertEqual(true, capability_enabled(~"guest_auth")),

        %% An operator that pinned it off is reported off, not "configured".
        application:set_env(asobi, guest_auth, false),
        ?assertEqual(false, capability_enabled(~"guest_auth")),

        %% And an operator with no bundle at all is reported on.
        application:unset_env(asobi, script_guest_auth),
        application:set_env(asobi, guest_auth, true),
        ?assertEqual(true, capability_enabled(~"guest_auth"))
    after
        [
            case V of
                {ok, Value} -> application:set_env(asobi, K, Value);
                undefined -> application:unset_env(asobi, K)
            end
         || {K, V} <- Saved
        ]
    end.

%% Storage is on by default (asobi_storage:enabled/0), unlike the configured
%% capabilities above which are off until set. `false` is the only value that
%% reports it disabled.
features_reports_the_storage_switch_test() ->
    Original = application:get_env(asobi, storage),
    try
        application:unset_env(asobi, storage),
        ?assertEqual(true, capability_enabled(~"storage")),
        application:set_env(asobi, storage, false),
        ?assertEqual(false, capability_enabled(~"storage"))
    after
        case Original of
            {ok, Value} -> application:set_env(asobi, storage, Value);
            undefined -> application:unset_env(asobi, storage)
        end
    end.

capability_enabled(Name) ->
    [Enabled] = [
        E
     || #{name := N, enabled := E} <- asobi_ops_features:capabilities(), N =:= Name
    ],
    Enabled.

%%--------------------------------------------------------------------
%% Erasure and export handlers
%%--------------------------------------------------------------------

erase_handler_test_() ->
    {foreach, fun setup_erase/0, fun cleanup_erase/1, [
        {"a body echoing the username erases", fun erase_confirmed/0},
        {"no body at all is refused", fun erase_without_a_confirmation/0},
        {"the wrong username is refused", fun erase_with_the_wrong_username/0},
        {"a malformed id never reaches the database", fun erase_with_a_malformed_id/0},
        {"an unknown player is not_found", fun erase_unknown_player/0},
        {"a refused capability answers forbidden", fun erase_forbidden/0},
        {"a rolled-back erasure is a 500 code", fun erase_failed/0},
        {"export projects and never 404s a live player", fun export_ok/0},
        {"export of an unknown player is not_found", fun export_unknown/0},
        {"a failed extension export is export_incomplete", fun export_incomplete/0}
    ]}.

-define(ERASE_ID, ~"01960000-0000-7000-8000-000000000009").

setup_erase() ->
    meck:new(asobi_repo, [no_link]),
    meck:expect(asobi_repo, get, fun(asobi_player, ?ERASE_ID) ->
        {ok, #{id => ?ERASE_ID, username => ~"kaito"}}
    end),
    meck:new(asobi_player_erase, [no_link]),
    meck:expect(asobi_player_erase, run, fun(?ERASE_ID, _Actor) ->
        {ok, #{player_id => ?ERASE_ID, erased => true}}
    end),
    meck:new(asobi_player_export, [no_link]),
    meck:expect(asobi_player_export, run, fun(?ERASE_ID) -> {ok, #{player => #{}}} end),
    ok.

cleanup_erase(_) ->
    meck:unload(asobi_player_export),
    meck:unload(asobi_player_erase),
    meck:unload(asobi_repo),
    ok.

erase_req(Body) ->
    #{
        bindings => #{~"id" => ?ERASE_ID},
        auth_data => #{ops_actor => erase_actor()},
        json => Body
    }.

erase_actor() ->
    #{
        id => ~"static_secret",
        display => ~"operator",
        source => static_secret,
        caps => [read, player_data, config, erasure],
        attested => false
    }.

erase_confirmed() ->
    ?assertMatch(
        {json, #{data := #{erased := true}}},
        asobi_ops_controller:erase_player(erase_req(#{~"username" => ~"kaito"}))
    ),
    ?assertEqual(1, meck:num_calls(asobi_player_erase, run, '_')).

%% The echo is the guard that makes an unattended POST insufficient - a
%% clickjacked console page can send the request but cannot know the username
%% the server will compare against.
erase_without_a_confirmation() ->
    ?assertEqual(
        {asobi_error, ~"ops.confirmation_required"},
        asobi_ops_controller:erase_player(erase_req(#{}))
    ),
    ?assertEqual(0, meck:num_calls(asobi_player_erase, run, '_')).

erase_with_the_wrong_username() ->
    ?assertEqual(
        {asobi_error, ~"ops.confirmation_mismatch"},
        asobi_ops_controller:erase_player(erase_req(#{~"username" => ~"yuki"}))
    ),
    ?assertEqual(0, meck:num_calls(asobi_player_erase, run, '_')).

erase_with_a_malformed_id() ->
    Req = (erase_req(#{~"username" => ~"kaito"}))#{bindings => #{~"id" => ~"not-a-uuid"}},
    ?assertEqual({asobi_error, ~"ops.invalid_id"}, asobi_ops_controller:erase_player(Req)),
    ?assertEqual(0, meck:num_calls(asobi_repo, get, '_')).

erase_unknown_player() ->
    meck:expect(asobi_repo, get, fun(asobi_player, ?ERASE_ID) -> {error, not_found} end),
    ?assertEqual(
        {asobi_error, ~"ops.not_found"},
        asobi_ops_controller:erase_player(erase_req(#{~"username" => ~"kaito"}))
    ).

erase_forbidden() ->
    meck:expect(asobi_player_erase, run, fun(?ERASE_ID, _Actor) -> {error, forbidden} end),
    ?assertEqual(
        {asobi_error, ~"forbidden"},
        asobi_ops_controller:erase_player(erase_req(#{~"username" => ~"kaito"}))
    ).

erase_failed() ->
    meck:expect(asobi_player_erase, run, fun(?ERASE_ID, _Actor) -> {error, {error, boom}} end),
    ?assertEqual(
        {asobi_error, ~"ops.erase_failed"},
        asobi_ops_controller:erase_player(erase_req(#{~"username" => ~"kaito"}))
    ).

export_ok() ->
    ?assertMatch(
        {json, #{data := #{player := #{}}}},
        asobi_ops_controller:export_player(#{bindings => #{~"id" => ?ERASE_ID}})
    ).

export_unknown() ->
    meck:expect(asobi_player_export, run, fun(?ERASE_ID) -> {error, not_found} end),
    ?assertEqual(
        {asobi_error, ~"ops.not_found"},
        asobi_ops_controller:export_player(#{bindings => #{~"id" => ?ERASE_ID}})
    ).

%% Fail loudly and retry beats a partial export presented as complete: an
%% extension failure is a 500 code, never a payload missing a section.
export_incomplete() ->
    meck:expect(asobi_player_export, run, fun(?ERASE_ID) ->
        {error, {extension_export, quests, db_down}}
    end),
    ?assertEqual(
        {asobi_error, ~"ops.export_incomplete"},
        asobi_ops_controller:export_player(#{bindings => #{~"id" => ?ERASE_ID}})
    ).
