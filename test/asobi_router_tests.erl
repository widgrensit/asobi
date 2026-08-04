-module(asobi_router_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("nova/include/nova_router.hrl").

-import(asobi_test_helpers, [http_routes/1, routes_missing_options/1, sample_path/1]).

dispatch() ->
    nova_router:compile([asobi]).

resolve(Dispatch, Path) ->
    resolve(Dispatch, Path, ~"GET").

resolve(Dispatch, Path, Method) ->
    case routing_tree:lookup('_', Path, Method, Dispatch) of
        {ok, Bindings, #nova_handler_value{callback = Callback}} -> {ok, Bindings, Callback};
        Other -> Other
    end.

matches_live_test() ->
    ?assertEqual(
        {ok, #{}, fun asobi_match_controller:live/1},
        resolve(dispatch(), ~"/api/v1/matches/live")
    ).

matches_show_test() ->
    ?assertEqual(
        {ok, #{~"id" => ~"0198c0de-0000-7000-8000-000000000001"},
            fun asobi_match_controller:show/1},
        resolve(dispatch(), ~"/api/v1/matches/0198c0de-0000-7000-8000-000000000001")
    ).

matches_index_test() ->
    ?assertEqual(
        {ok, #{}, fun asobi_match_controller:index/1},
        resolve(dispatch(), ~"/api/v1/matches")
    ).

match_votes_test() ->
    ?assertEqual(
        {ok, #{~"id" => ~"0198c0de-0000-7000-8000-000000000002"},
            fun asobi_vote_controller:index/1},
        resolve(dispatch(), ~"/api/v1/matches/0198c0de-0000-7000-8000-000000000002/votes")
    ).

%%--------------------------------------------------------------------
%% Meta-tests over every declared route group
%%
%% These enumerate `asobi_router:routes/1` rather than a hand-kept list, so a
%% route group added later is covered the moment it is declared. The pure
%% helpers take the group list as an argument; `*_reports_*_test/0` below feed
%% them a synthetic group to prove the checks actually fail on a bad one.
%%--------------------------------------------------------------------

every_route_group_is_well_formed_test() ->
    Groups = asobi_router:routes(dev),
    ?assert(Groups =/= []),
    [
        begin
            ?assertMatch(#{prefix := _, security := _, routes := _}, Group),
            ?assert(is_binary(maps:get(prefix, Group))),
            ?assert(maps:get(routes, Group) =/= [])
        end
     || Group <- Groups
    ].

%% Nova runs `nova_router` before `nova_cors_plugin`, so a route that omits
%% `options` answers 405 to a preflight before the plugin ever sees it. The
%% live preflight assertions are in asobi_cors_SUITE; this is the cheap
%% router-level precondition, checked on every group.
every_http_route_accepts_options_test() ->
    ?assertEqual([], routes_missing_options(asobi_router:routes(dev))).

routes_missing_options_reports_a_bad_group_test() ->
    Synthetic = #{
        prefix => ~"/api/v1/extensions",
        security => false,
        routes => [
            {~"/probe", fun asobi_match_controller:index/1, #{methods => [get]}},
            {~"/fine", fun asobi_match_controller:index/1, #{methods => [get, options]}}
        ]
    },
    Missing = routes_missing_options(asobi_router:routes(dev) ++ [Synthetic]),
    ?assert(lists:member({~"/api/v1/extensions", ~"/probe"}, Missing)),
    ?assertNot(lists:member({~"/api/v1/extensions", ~"/fine"}, Missing)).

%% Every declared route must be reachable at its declared method. Declaration
%% order decides this (asobi #326: `/matches/live` sat behind `/matches/:id`),
%% and the trap is invisible until someone requests the shadowed path.
every_http_route_resolves_to_its_handler_test() ->
    Dispatch = dispatch(),
    Routes = http_routes(asobi_router:routes(dev)),
    ?assert(length(Routes) > 40),
    [
        ?assertEqual(
            {ok, Handler},
            resolved_handler(Dispatch, <<Prefix/binary, (sample_path(Path))/binary>>, Method)
        )
     || {Prefix, Path, Handler, Methods} <- Routes,
        Method <- Methods,
        Method =/= options
    ].

sample_path_substitutes_every_binding_test() ->
    ?assertEqual(
        ~"/groups/g-1/members/g-1/role", sample_path(~"/groups/:id/members/:player_id/role")
    ),
    ?assertEqual(~"/matches/live", sample_path(~"/matches/live")).

%%--------------------------------------------------------------------
%% Helpers
%%--------------------------------------------------------------------

-spec resolved_handler(term(), binary(), atom()) -> {ok, fun()} | term().
resolved_handler(Dispatch, Path, Method) ->
    case resolve(Dispatch, Path, string:uppercase(atom_to_binary(Method))) of
        {ok, _Bindings, Callback} -> {ok, Callback};
        Other -> Other
    end.
