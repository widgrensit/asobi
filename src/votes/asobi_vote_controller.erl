-module(asobi_vote_controller).
-moduledoc "REST controller for vote history queries.".

-export([index/1, show/1]).

-spec index(cowboy_req:req()) -> {json, map()} | {status, integer()}.
index(#{bindings := #{~"id" := MatchId}, auth_data := #{player_id := PlayerId}} = _Req) when
    is_binary(MatchId), is_binary(PlayerId)
->
    %% F-20: vote history is restricted to participants of the match. Look
    %% up the match record (or live match server) and reject non-players.
    case is_match_participant(MatchId, PlayerId) of
        false ->
            {status, 403};
        true ->
            Q0 = kura_query:from(asobi_vote),
            Q1 = kura_query:where(Q0, {match_id, MatchId}),
            Q2 = kura_query:order_by(Q1, [{inserted_at, desc}]),
            Q3 = kura_query:limit(Q2, 50),
            case asobi_repo:all(Q3) of
                {ok, Votes} ->
                    {json, #{votes => [strip_hidden(V) || V <- Votes]}};
                {error, _} ->
                    {status, 500}
            end
    end.

-spec is_match_participant(binary(), binary()) -> boolean().
is_match_participant(MatchId, PlayerId) ->
    case asobi_repo:get(asobi_match_record, MatchId) of
        {ok, #{players := Players}} when is_list(Players) ->
            lists:member(PlayerId, Players);
        _ ->
            %% Match still in flight; defer to the live server. The server
            %% takes a pid, so resolve by id first.
            case asobi_match_server:whereis(MatchId) of
                {ok, Pid} when is_pid(Pid) ->
                    try asobi_match_server:get_info(Pid) of
                        #{players := Players} when is_list(Players) ->
                            lists:member(PlayerId, Players);
                        _ ->
                            false
                    catch
                        _:_ -> false
                    end;
                _ ->
                    false
            end
    end.

%% F-20: hidden-visibility votes must not leak per-voter ballots even to
%% participants until the vote has resolved.
-spec strip_hidden(map()) -> map().
strip_hidden(#{visibility := ~"hidden", status := S} = Vote) when S =/= ~"resolved" ->
    maps:remove(votes_cast, Vote);
strip_hidden(Vote) ->
    Vote.

-spec show(cowboy_req:req()) -> {json, map()} | {status, integer()}.
show(#{bindings := #{~"id" := VoteId}, auth_data := #{player_id := _PlayerId}} = _Req) ->
    case asobi_repo:get(asobi_vote, VoteId) of
        {ok, Vote} ->
            {json, Vote};
        {error, not_found} ->
            {status, 404}
    end.
