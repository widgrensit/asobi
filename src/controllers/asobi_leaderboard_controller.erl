-module(asobi_leaderboard_controller).

-export([top/1, around/1, submit/1]).

-spec top(cowboy_req:req()) -> {json, map()}.
top(#{bindings := #{~"id" := BoardId}, qs := Qs} = _Req) ->
    Params = cow_qs:parse_qs(Qs),
    Limit = binary_to_integer(proplists:get_value(~"limit", Params, ~"100")),
    Entries = asobi_leaderboard_server:top(BoardId, Limit),
    {json, #{entries => format_entries(BoardId, Entries)}}.

-spec around(cowboy_req:req()) -> {json, map()}.
around(#{bindings := #{~"id" := BoardId, ~"player_id" := PlayerId}, qs := Qs} = _Req) ->
    Params = cow_qs:parse_qs(Qs),
    Range = binary_to_integer(proplists:get_value(~"range", Params, ~"5")),
    Entries = asobi_leaderboard_server:around(BoardId, PlayerId, Range),
    {json, #{entries => format_entries(BoardId, Entries)}}.

-spec submit(cowboy_req:req()) -> {json, integer(), map(), map()}.
submit(
    #{bindings := #{~"id" := BoardId}, json := Params, auth_data := #{player_id := PlayerId}} = _Req
) ->
    Score = maps:get(~"score", Params),
    SubScore = maps:get(~"sub_score", Params, 0),
    asobi_leaderboard_server:submit(BoardId, PlayerId, Score),
    Rank =
        case asobi_leaderboard_server:rank(BoardId, PlayerId) of
            {ok, R} -> R;
            {error, not_found} -> null
        end,
    {json, 200, #{}, #{
        leaderboard_id => BoardId,
        player_id => PlayerId,
        score => Score,
        sub_score => SubScore,
        rank => Rank,
        updated_at => format_timestamp(erlang:system_time(millisecond))
    }}.


%% --- Internal ---

-spec format_entries(binary(), [{binary(), integer(), pos_integer()}]) -> [map()].
format_entries(BoardId, Entries) ->
    [
        #{
            leaderboard_id => BoardId,
            player_id => P,
            score => S,
            sub_score => 0,
            rank => R,
            updated_at => null
        }
     || {P, S, R} <- Entries
    ].

-spec format_timestamp(integer()) -> binary().
format_timestamp(Ms) ->
    Seconds = Ms div 1000,
    {{Y, Mo, D}, {H, Mi, S}} = calendar:system_time_to_universal_time(Seconds, second),
    iolist_to_binary(
        io_lib:format(
            ~"~4..0B-~2..0B-~2..0BT~2..0B:~2..0B:~2..0BZ",
            [Y, Mo, D, H, Mi, S]
        )
    ).
