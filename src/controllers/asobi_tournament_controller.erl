-module(asobi_tournament_controller).

-export([index/1, show/1, join/1]).

-spec index(cowboy_req:req()) -> {json, map()}.
index(#{qs := Qs} = _Req) when is_binary(Qs) ->
    Params = cow_qs:parse_qs(Qs),
    Q0 = kura_query:from(asobi_tournament),
    Q1 =
        case proplists:get_value(~"status", Params) of
            undefined -> Q0;
            Status -> kura_query:where(Q0, {status, Status})
        end,
    Limit = asobi_qs:integer(~"limit", Params, 50, 1, 200),
    Q2 = kura_query:limit(kura_query:order_by(Q1, [{start_at, asc}]), Limit),
    {ok, Tournaments} = asobi_repo:all(Q2),
    {json, #{tournaments => Tournaments}}.

-spec show(cowboy_req:req()) -> {json, map()} | {status, integer()}.
show(#{bindings := #{~"id" := TournamentId}} = _Req) ->
    case asobi_repo:get(asobi_tournament, TournamentId) of
        {ok, Tournament} -> {json, Tournament};
        {error, not_found} -> {status, 404}
    end.

-spec join(cowboy_req:req()) ->
    {json, integer(), map(), map()} | {status, integer()}.
join(#{bindings := #{~"id" := TournamentId}, auth_data := #{player_id := PlayerId}} = _Req) when
    is_binary(TournamentId), is_binary(PlayerId)
->
    case asobi_tournament_server:join(TournamentId, PlayerId) of
        ok ->
            {json, 200, #{}, #{success => true, tournament_id => TournamentId}};
        {error, tournament_full} ->
            {json, 409, #{}, #{error => ~"tournament_full"}};
        {error, already_joined} ->
            {json, 409, #{}, #{error => ~"already_joined"}};
        {error, not_found} ->
            {status, 404}
    end.
