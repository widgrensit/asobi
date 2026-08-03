-module(asobi_router_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("nova/include/nova_router.hrl").

dispatch() ->
    nova_router:compile([asobi]).

resolve(Dispatch, Path) ->
    case routing_tree:lookup('_', Path, ~"GET", Dispatch) of
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
