-module(asobi_leaderboard_controller).

-export([top/1, around/1, submit/1]).

-spec top(cowboy_req:req()) -> {json, map()}.
top(#{bindings := #{~"id" := BoardId}, qs := Qs} = _Req) ->
    Params = cow_qs:parse_qs(Qs),
    Limit = binary_to_integer(proplists:get_value(~"limit", Params, ~"100")),
    Entries = asobi_leaderboard_server:top(BoardId, Limit),
    {json, #{leaderboard_id => BoardId, entries => format_entries(Entries)}}.

-spec around(cowboy_req:req()) -> {json, map()}.
around(#{bindings := #{~"id" := BoardId, ~"player_id" := PlayerId}, qs := Qs} = _Req) ->
    Params = cow_qs:parse_qs(Qs),
    Range = binary_to_integer(proplists:get_value(~"range", Params, ~"5")),
    Entries = asobi_leaderboard_server:around(BoardId, PlayerId, Range),
    {json, #{leaderboard_id => BoardId, entries => format_entries(Entries)}}.

-spec submit(cowboy_req:req()) -> {json, map()}.
submit(
    #{bindings := #{~"id" := BoardId}, json := Params, auth_data := #{player_id := PlayerId}} = _Req
) ->
    Score = maps:get(~"score", Params),
    asobi_leaderboard_server:submit(BoardId, PlayerId, Score),
    case asobi_leaderboard_server:rank(BoardId, PlayerId) of
        {ok, Rank} ->
            {json, #{leaderboard_id => BoardId, rank => Rank, score => Score}};
        {error, not_found} ->
            {json, #{leaderboard_id => BoardId, score => Score}}
    end.

%% --- Internal ---

-spec format_entries([{binary(), integer(), pos_integer()}]) -> [map()].
format_entries(Entries) ->
    [#{player_id => P, score => S, rank => R} || {P, S, R} <- Entries].
