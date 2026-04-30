-module(asobi_leaderboard_controller).

-export([top/1, around/1, submit/1]).

-spec top(cowboy_req:req()) -> {json, map()}.
top(#{bindings := #{~"id" := BoardId}, qs := Qs} = _Req) when is_binary(BoardId), is_binary(Qs) ->
    Params = cow_qs:parse_qs(Qs),
    Limit = qs_integer(~"limit", Params, 100),
    Entries = asobi_leaderboard_server:top(BoardId, Limit),
    {json, #{entries => format_entries(BoardId, Entries)}}.

-spec around(cowboy_req:req()) -> {json, map()}.
around(#{bindings := #{~"id" := BoardId, ~"player_id" := PlayerId}, qs := Qs} = _Req) when
    is_binary(BoardId), is_binary(PlayerId), is_binary(Qs)
->
    Params = cow_qs:parse_qs(Qs),
    Range = qs_integer(~"range", Params, 5),
    Entries = asobi_leaderboard_server:around(BoardId, PlayerId, Range),
    {json, #{entries => format_entries(BoardId, Entries)}}.

-spec submit(cowboy_req:req()) -> {json, integer(), map(), map()}.
submit(
    #{bindings := #{~"id" := BoardId}, json := Params, auth_data := #{player_id := PlayerId}} = _Req
) when is_binary(BoardId), is_binary(PlayerId), is_map(Params) ->
    case client_submit_allowed(BoardId) of
        false ->
            {json, 403, #{}, #{error => ~"client_submit_disabled"}};
        true ->
            Score =
                case maps:get(~"score", Params) of
                    S when is_number(S) -> S;
                    _ -> 0
                end,
            SubScore = maps:get(~"sub_score", Params, 0),
            case asobi_leaderboard_server:submit(BoardId, PlayerId, Score) of
                {error, capacity_reached} ->
                    {json, 503, #{}, #{error => ~"leaderboard_capacity_reached"}};
                _ ->
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
                    }}
            end
    end.

%% Client score submissions are off by default — server-side game logic
%% should call asobi_leaderboard_server:submit/3 directly. To opt a board
%% in for client writes (typical for casual scoreboards where cheating
%% is acceptable), set `leaderboard_client_submit` to a list of allowed
%% board ids or to `all`.
-spec client_submit_allowed(binary()) -> boolean().
client_submit_allowed(BoardId) ->
    case application:get_env(asobi, leaderboard_client_submit, []) of
        all -> true;
        L when is_list(L) -> lists:member(BoardId, L);
        _ -> false
    end.

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

qs_integer(Key, Params, Default) ->
    case proplists:get_value(Key, Params) of
        V when is_binary(V) -> binary_to_integer(V);
        _ -> Default
    end.

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
