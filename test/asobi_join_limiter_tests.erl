-module(asobi_join_limiter_tests).
-include_lib("eunit/include/eunit.hrl").

%% asobi#193: the join bucket is what bounds a roster sweep. These pin that
%% the limiter exists, is keyed per player, and actually refuses - a
%% misconfigured or absent bucket would silently restore the unbounded join
%% rate with nothing failing.

-define(LIMITER, asobi_join_limiter).

setup() ->
    application:ensure_all_started(seki),
    catch seki:new_limiter(?LIMITER, #{algorithm => sliding_window, limit => 3, window => 60000}),
    ok.

cleanup(_) ->
    ok.

join_limiter_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        {"allows up to the limit then denies", fun denies_past_limit/0},
        {"buckets are per player", fun per_player_buckets/0}
    ]}.

denies_past_limit() ->
    P = unique_player(),
    [?assertMatch({allow, _}, seki:check(?LIMITER, P)) || _ <- lists:seq(1, 3)],
    ?assertMatch(
        {deny, _},
        seki:check(?LIMITER, P),
        "an unbounded join rate is what makes a roster sweep cheap"
    ).

per_player_buckets() ->
    A = unique_player(),
    B = unique_player(),
    [?assertMatch({allow, _}, seki:check(?LIMITER, A)) || _ <- lists:seq(1, 3)],
    ?assertMatch({deny, _}, seki:check(?LIMITER, A)),
    ?assertMatch(
        {allow, _},
        seki:check(?LIMITER, B),
        "one player exhausting the bucket must not lock everyone out"
    ).

unique_player() ->
    integer_to_binary(erlang:unique_integer([positive])).
