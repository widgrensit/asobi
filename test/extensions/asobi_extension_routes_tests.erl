-module(asobi_extension_routes_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("nova/include/nova_router.hrl").

-define(QUESTS, asobi_fixture_quests).
-define(TUNABLE, asobi_fixture_tunable).

routes_test_() ->
    {foreach, fun setup/0, fun cleanup/1, [
        fun a_declared_route_is_derived_as_an_http_claim/0,
        fun a_route_outside_the_owned_set_is_refused/0,
        fun a_reservation_without_a_route_is_legal/0,
        fun two_extensions_one_path/0,
        fun two_extensions_overlapping_bindings/0,
        fun a_reservation_collides_like_a_route/0,
        fun a_core_path_is_refused/0,
        fun a_binding_over_a_core_binding_is_refused/0,
        fun a_literal_under_a_core_binding_is_refused/0,
        fun the_ws_and_console_paths_are_core_owned/0,
        fun resolve_raises_on_a_route_collision/0,
        fun resolve_raises_on_a_core_path_claim/0,
        fun a_route_handler_must_have_arity_one/0,
        fun a_route_must_carry_a_real_method/0,
        fun a_route_must_carry_a_real_security/0,
        fun a_path_must_be_rooted/0,
        fun a_path_must_have_no_empty_segments/0,
        fun a_path_segment_must_be_clean/0,
        fun a_binding_must_be_an_identifier/0,
        fun one_path_may_carry_several_methods/0,
        fun the_same_path_and_method_twice_is_refused/0,
        fun overlapping_paths_in_one_manifest_are_refused/0,
        fun routes_must_be_a_list/0,
        fun a_player_route_mounts_under_the_player_chain/0,
        fun a_webhook_route_mounts_without_the_player_chain/0,
        fun an_absent_extensions_routes_are_not_in_the_table/0
    ]}.

setup() ->
    asobi_extensions:reset(),
    asobi_fixture_tunable_extension:clear(),
    ok.

cleanup(_) ->
    _ = [asobi_fixture_app:uninstall(A) || A <- [?QUESTS, ?TUNABLE]],
    asobi_fixture_tunable_extension:clear(),
    asobi_extensions:reset(),
    ok.

%% --- Claims and the owned set ---

a_declared_route_is_derived_as_an_http_claim() ->
    install_quests(),
    {ok, [Extension]} = asobi_extensions:check(),
    ?assertMatch(#{routes := [_, _]}, Extension).

%% owns().http is the closed-set assertion, exactly as owns().queues is: name
%% the kind and anything declared outside it is a typo or a land grab.
a_route_outside_the_owned_set_is_refused() ->
    tunable(#{
        owns => #{http => [~"/api/v1/tunable/a"]},
        routes => [route(~"/api/v1/tunable/b")]
    }),
    ?assert(
        lists:member({undeclared_claim, http, ~"/api/v1/tunable/b", ?TUNABLE}, check_problems())
    ).

a_reservation_without_a_route_is_legal() ->
    tunable(#{owns => #{http => [~"/api/v1/tunable/coming_soon"]}}),
    ?assertMatch({ok, [_]}, asobi_extensions:check()).

%% --- Collisions between extensions ---

two_extensions_one_path() ->
    install_quests(),
    tunable(#{routes => [route(~"/api/v1/quests/board")]}),
    assert_route_conflict(~"/api/v1/quests/board", ~"/api/v1/quests/board").

%% The comparison is structural: a binding and a literal are different tokens
%% and one claim, so token equality can never be the mechanism here.
two_extensions_overlapping_bindings() ->
    install_quests(),
    tunable(#{routes => [route(~"/api/v1/quests/:anything")]}),
    assert_route_conflict(~"/api/v1/quests/board", ~"/api/v1/quests/:anything").

%% A path in owns().http with no route behind it still reserves: exclusivity
%% is the point of a reservation.
a_reservation_collides_like_a_route() ->
    install_quests(),
    tunable(#{owns => #{http => [~"/api/v1/quests/webhook"]}}),
    assert_route_conflict(~"/api/v1/quests/webhook", ~"/api/v1/quests/webhook").

%% --- Core's own table ---

a_core_path_is_refused() ->
    tunable(#{routes => [route(~"/api/v1/matches")]}),
    ?assert(
        lists:member(
            {reserved_route, ~"/api/v1/matches", ~"/api/v1/matches", ?TUNABLE}, check_problems()
        )
    ).

a_binding_over_a_core_binding_is_refused() ->
    tunable(#{routes => [route(~"/api/v1/matches/:anything")]}),
    ?assert(
        lists:member(
            {reserved_route, ~"/api/v1/matches/:anything", ~"/api/v1/matches/:id", ?TUNABLE},
            check_problems()
        )
    ).

%% The shadowing case token equality can never see: a literal that some
%% request to a core binding would have reached.
a_literal_under_a_core_binding_is_refused() ->
    tunable(#{routes => [route(~"/api/v1/matches/anything")]}),
    Problems = check_problems(),
    ?assert(
        lists:member(
            {reserved_route, ~"/api/v1/matches/anything", ~"/api/v1/matches/:id", ?TUNABLE},
            Problems
        )
    ),
    Text = describe_text(Problems),
    ?assertNotEqual(nomatch, binary:match(Text, ~"/api/v1/matches/:id")).

the_ws_and_console_paths_are_core_owned() ->
    tunable(#{routes => [route(~"/ws"), route(~"/console")]}),
    Problems = check_problems(),
    ?assert(lists:member({reserved_route, ~"/ws", ~"/ws", ?TUNABLE}, Problems)),
    ?assert(lists:member({reserved_route, ~"/console", ~"/console", ?TUNABLE}, Problems)).

%% --- Boot refusal: the backstop raises exactly as the other kinds do ---

resolve_raises_on_a_route_collision() ->
    install_quests(),
    tunable(#{routes => [route(~"/api/v1/quests/board")]}),
    ?assertError({asobi_extensions, _}, asobi_extensions:resolve()).

resolve_raises_on_a_core_path_claim() ->
    tunable(#{routes => [route(~"/api/v1/players/:someone")]}),
    ?assertError({asobi_extensions, _}, asobi_extensions:resolve()).

%% --- Manifest shape ---

%% A route handler is a Nova controller, applied as Module:Function(Req) -
%% arity 1, unlike the rpc/ops seams' 2.
a_route_handler_must_have_arity_one() ->
    tunable(#{routes => [route(~"/api/v1/tunable/a", #{mfa => {tunable_controller, a, 2}})]}),
    ?assertMatch(
        [
            {bad_manifest, ?TUNABLE, _,
                {routes, ~"a route handler is a Nova controller: mfa must be {Module, Function, 1}",
                    ~"/api/v1/tunable/a"}}
        ],
        check_problems()
    ).

a_route_must_carry_a_real_method() ->
    tunable(#{routes => [route(~"/api/v1/tunable/a", #{method => patch})]}),
    ?assertMatch(
        [{bad_manifest, ?TUNABLE, _, {routes, _, ~"/api/v1/tunable/a"}}],
        check_problems()
    ).

a_route_must_carry_a_real_security() ->
    tunable(#{routes => [route(~"/api/v1/tunable/a", #{security => admin})]}),
    ?assertMatch(
        [{bad_manifest, ?TUNABLE, _, {routes, _, ~"/api/v1/tunable/a"}}],
        check_problems()
    ),
    retune(#{routes => [route(~"/api/v1/tunable/a", #{security => webhook})]}),
    ?assertMatch({ok, [_]}, asobi_extensions:check()).

a_path_must_be_rooted() ->
    tunable(#{}),
    [
        begin
            retune(#{routes => [route(Path)]}),
            ?assertMatch(
                [
                    {bad_manifest, ?TUNABLE, _,
                        {routes,
                            ~"path must be /-rooted with non-empty literal or :binding segments",
                            Path}}
                ],
                check_problems()
            )
        end
     || Path <- [~"api/v1/tunable", ~"", ~"/"]
    ],
    retune(#{routes => [route(~"/api/v1/tunable/a")]}),
    ?assertMatch({ok, [_]}, asobi_extensions:check()).

a_path_must_have_no_empty_segments() ->
    tunable(#{}),
    [
        begin
            retune(#{routes => [route(Path)]}),
            ?assertMatch(
                [{bad_manifest, ?TUNABLE, _, {routes, _, Path}}],
                check_problems()
            )
        end
     || Path <- [~"/api//tunable", ~"/api/v1/tunable/"]
    ].

%% routing_tree does no dot-segment normalisation, so this table declares no
%% route form that could carry one - the console group's own rule, held here
%% for every extension.
a_path_segment_must_be_clean() ->
    tunable(#{}),
    [
        begin
            retune(#{routes => [route(Path)]}),
            ?assertMatch(
                [{bad_manifest, ?TUNABLE, _, {routes, _, Path}}],
                check_problems()
            )
        end
     || Path <- [~"/api/v1/../tunable", ~"/api/v1/tun?able", ~"/api/v1/tun#able", ~"/a/b%20c"]
    ].

a_binding_must_be_an_identifier() ->
    tunable(#{}),
    [
        begin
            retune(#{routes => [route(Path)]}),
            ?assertMatch(
                [{bad_manifest, ?TUNABLE, _, {routes, _, Path}}],
                check_problems()
            )
        end
     || Path <- [~"/api/v1/tunable/:", ~"/api/v1/tunable/:1st", ~"/api/v1/tunable/x:y"]
    ].

one_path_may_carry_several_methods() ->
    tunable(#{
        routes => [
            route(~"/api/v1/tunable/a", #{method => get}),
            route(~"/api/v1/tunable/a", #{method => put})
        ]
    }),
    ?assertMatch({ok, [_]}, asobi_extensions:check()).

the_same_path_and_method_twice_is_refused() ->
    tunable(#{
        routes => [
            route(~"/api/v1/tunable/a", #{mfa => {tunable_controller, a, 1}}),
            route(~"/api/v1/tunable/a", #{mfa => {tunable_controller, b, 1}})
        ]
    }),
    ?assertMatch(
        [
            {bad_manifest, ?TUNABLE, _,
                {routes, ~"two entries serve the same path and method", ~"/api/v1/tunable/a"}}
        ],
        check_problems()
    ).

%% Refusing in-manifest overlap is what makes declaration order irrelevant:
%% the asobi#326 literal-behind-binding trap cannot be declared at all.
overlapping_paths_in_one_manifest_are_refused() ->
    tunable(#{
        routes => [
            route(~"/api/v1/tunable/:key"),
            route(~"/api/v1/tunable/live")
        ]
    }),
    ?assertMatch(
        [
            {bad_manifest, ?TUNABLE, _,
                {routes, ~"two entries declare paths that match the same requests", {
                    ~"/api/v1/tunable/:key", ~"/api/v1/tunable/live"
                }}}
        ],
        check_problems()
    ).

routes_must_be_a_list() ->
    tunable(#{routes => #{~"/api/v1/tunable" => get}}),
    ?assertMatch(
        [{bad_manifest, ?TUNABLE, _, {routes, ~"must be a list of route entries", _}}],
        check_problems()
    ).

%% --- Mounting ---

a_player_route_mounts_under_the_player_chain() ->
    install_quests(),
    _ = asobi_extensions:resolve(),
    Dispatch = nova_router:compile([asobi]),
    ?assertEqual(
        {ok, #{}, fun asobi_fixture_quests_controller:board/1},
        resolve_route(Dispatch, ~"/api/v1/quests/board", ~"GET")
    ),
    [Group] = groups_serving(~"/api/v1/quests/board"),
    ?assertEqual(fun asobi_auth_plugin:verify/1, maps:get(security, Group)),
    ?assertNot(is_map_key(plugins, Group)).

a_webhook_route_mounts_without_the_player_chain() ->
    install_quests(),
    _ = asobi_extensions:resolve(),
    Dispatch = nova_router:compile([asobi]),
    ?assertEqual(
        {ok, #{}, fun asobi_fixture_quests_controller:webhook/1},
        resolve_route(Dispatch, ~"/api/v1/quests/webhook", ~"POST")
    ),
    [Group] = groups_serving(~"/api/v1/quests/webhook"),
    ?assertEqual(false, maps:get(security, Group)),
    ?assertNot(is_map_key(plugins, Group)).

%% The 404 discipline: an uninstalled extension's paths are simply not in the
%% table, indistinguishable from paths that never meant anything.
an_absent_extensions_routes_are_not_in_the_table() ->
    _ = asobi_extensions:resolve(),
    Dispatch = nova_router:compile([asobi]),
    ?assertNotMatch(
        {ok, _, _},
        resolve_route(Dispatch, ~"/api/v1/quests/board", ~"GET")
    ).

%% --- Helpers ---

install_quests() ->
    ok = asobi_fixture_app:install(?QUESTS, asobi_fixture_quests_extension, []).

tunable(Manifest) ->
    ok = asobi_fixture_tunable_extension:set(Manifest),
    ok = asobi_fixture_app:install(?TUNABLE, [asobi_fixture_tunable_extension], []).

retune(Manifest) ->
    ok = asobi_fixture_tunable_extension:set(Manifest).

route(Path) ->
    route(Path, #{}).

route(Path, Overrides) ->
    maps:merge(
        #{path => Path, method => get, mfa => {tunable_controller, a, 1}, security => player},
        Overrides
    ).

check_problems() ->
    case asobi_extensions:check() of
        {error, Problems} -> Problems;
        {ok, Resolved} -> erlang:error({expected_problems, [N || #{name := N} <- Resolved]})
    end.

%% Both claimants and both paths, in the message a human reads. Which side
%% comes first is claim sort order, which no test should care about.
assert_route_conflict(QuestsPath, TunablePath) ->
    Problems = check_problems(),
    ?assert(
        lists:member(
            {route_conflict, {QuestsPath, ?QUESTS}, {TunablePath, ?TUNABLE}}, Problems
        ) orelse
            lists:member(
                {route_conflict, {TunablePath, ?TUNABLE}, {QuestsPath, ?QUESTS}}, Problems
            )
    ),
    Text = describe_text(Problems),
    ?assertNotEqual(nomatch, binary:match(Text, atom_to_binary(?QUESTS, utf8))),
    ?assertNotEqual(nomatch, binary:match(Text, atom_to_binary(?TUNABLE, utf8))),
    ?assertNotEqual(nomatch, binary:match(Text, TunablePath)).

describe_text(Problems) ->
    iolist_to_binary([[~" ", Line] || Line <- asobi_extensions:describe(Problems)]).

resolve_route(Dispatch, Path, Method) ->
    case routing_tree:lookup('_', Path, Method, Dispatch) of
        {ok, Bindings, #nova_handler_value{callback = Callback}} -> {ok, Bindings, Callback};
        Other -> Other
    end.

groups_serving(Path) ->
    [
        Group
     || #{routes := Routes} = Group <- asobi_router:routes(dev),
        lists:any(fun({RoutePath, _, _}) -> RoutePath =:= Path end, Routes)
    ].
