-module(asobi_vote_controller).

-export([index/1, show/1]).

-spec index(cowboy_req:req()) -> {json, map()} | {status, integer()}.
index(#{bindings := #{~"match_id" := MatchId}, auth_data := #{player_id := _PlayerId}} = _Req) ->
    Q0 = kura_query:from(asobi_vote),
    Q1 = kura_query:where(Q0, {match_id, MatchId}),
    Q2 = kura_query:order_by(Q1, [{inserted_at, desc}]),
    Q3 = kura_query:limit(Q2, 50),
    case asobi_repo:all(Q3) of
        {ok, Votes} ->
            {json, #{votes => Votes}};
        {error, _} ->
            {status, 500}
    end.

-spec show(cowboy_req:req()) -> {json, map()} | {status, integer()}.
show(#{bindings := #{~"id" := VoteId}, auth_data := #{player_id := _PlayerId}} = _Req) ->
    case asobi_repo:get(asobi_vote, VoteId) of
        {ok, Vote} ->
            {json, Vote};
        {error, not_found} ->
            {status, 404}
    end.
