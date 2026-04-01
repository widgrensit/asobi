-module(asobi_leaderboard_api_SUITE).

-include_lib("nova_test/include/nova_test.hrl").

-export([all/0, groups/0, init_per_suite/1, end_per_suite/1]).
-export([
    submit_score/1,
    get_top/1,
    get_top_with_limit/1,
    get_around/1,
    get_top_empty/1
]).

all() -> [{group, leaderboard_api}].

groups() ->
    [
        {leaderboard_api, [sequence], [
            get_top_empty, submit_score, get_top, get_top_with_limit, get_around
        ]}
    ].

init_per_suite(Config) ->
    Config0 = asobi_test_helpers:start(Config),
    Players = lists:map(
        fun(I) when is_integer(I) ->
            U = asobi_test_helpers:unique_username(
                iolist_to_binary([~"lb_p", integer_to_binary(I)])
            ),
            {ok, R} = nova_test:post(
                "/api/v1/auth/register",
                #{json => #{~"username" => U, ~"password" => ~"testpass123"}},
                Config0
            ),
            #{~"player_id" := PId, ~"session_token" := PToken} = nova_test:json(R),
            {PId, PToken}
        end,
        lists:seq(1, 5)
    ),
    [{P1Id, P1Token} | _] = Players,
    BoardId = iolist_to_binary([
        ~"test_board_", integer_to_binary(erlang:unique_integer([positive]))
    ]),
    {ok, _} = asobi_leaderboard_sup:start_board(BoardId),
    [
        {board_id, BoardId},
        {player1_id, P1Id},
        {player1_token, P1Token},
        {players, Players}
        | Config0
    ].

end_per_suite(Config) ->
    Config.

auth(Token) when is_binary(Token) ->
    [{~"authorization", <<"Bearer ", Token/binary>>}].

get_top_empty(Config) ->
    {board_id, BoardId} = lists:keyfind(board_id, 1, Config),
    {player1_token, Token} = lists:keyfind(player1_token, 1, Config),
    true = is_binary(BoardId),
    true = is_binary(Token),
    {ok, Resp} = nova_test:get(
        "/api/v1/leaderboards/" ++ binary_to_list(BoardId),
        #{headers => auth(Token)},
        Config
    ),
    ?assertStatus(200, Resp),
    ?assertJson(#{~"entries" := []}, Resp),
    Config.

submit_score(Config) ->
    {board_id, BoardId} = lists:keyfind(board_id, 1, Config),
    {players, Players} = lists:keyfind(players, 1, Config),
    true = is_binary(BoardId),
    true = is_list(Players),
    Scores = [500, 300, 700, 100, 900],
    lists:foreach(
        fun({{_PId, Token}, Score}) when is_binary(Token) ->
            {ok, Resp} = nova_test:post(
                "/api/v1/leaderboards/" ++ binary_to_list(BoardId),
                #{
                    headers => auth(Token),
                    json => #{~"score" => Score}
                },
                Config
            ),
            ?assertStatus(200, Resp),
            #{~"score" := RespScore} = nova_test:json(Resp),
            ?assertEqual(Score, RespScore)
        end,
        lists:zip(Players, Scores)
    ),
    Config.

get_top(Config) ->
    {board_id, BoardId} = lists:keyfind(board_id, 1, Config),
    {player1_token, Token} = lists:keyfind(player1_token, 1, Config),
    true = is_binary(BoardId),
    true = is_binary(Token),
    {ok, Resp} = nova_test:get(
        "/api/v1/leaderboards/" ++ binary_to_list(BoardId),
        #{headers => auth(Token)},
        Config
    ),
    ?assertStatus(200, Resp),
    #{~"entries" := Entries} = nova_test:json(Resp),
    ?assert(length(Entries) =:= 5),
    [First | _] = Entries,
    ?assertMatch(#{~"score" := 900, ~"rank" := 1}, First),
    Config.

get_top_with_limit(Config) ->
    {board_id, BoardId} = lists:keyfind(board_id, 1, Config),
    {player1_token, Token} = lists:keyfind(player1_token, 1, Config),
    true = is_binary(BoardId),
    true = is_binary(Token),
    {ok, Resp} = nova_test:get(
        "/api/v1/leaderboards/" ++ binary_to_list(BoardId) ++ "?limit=3",
        #{headers => auth(Token)},
        Config
    ),
    ?assertStatus(200, Resp),
    #{~"entries" := Entries} = nova_test:json(Resp),
    ?assert(length(Entries) =:= 3),
    Config.

get_around(Config) ->
    {board_id, BoardId} = lists:keyfind(board_id, 1, Config),
    {player1_id, P1Id} = lists:keyfind(player1_id, 1, Config),
    {player1_token, Token} = lists:keyfind(player1_token, 1, Config),
    true = is_binary(BoardId),
    true = is_binary(P1Id),
    true = is_binary(Token),
    {ok, Resp} = nova_test:get(
        "/api/v1/leaderboards/" ++ binary_to_list(BoardId) ++
            "/around/" ++ binary_to_list(P1Id) ++ "?range=2",
        #{headers => auth(Token)},
        Config
    ),
    ?assertStatus(200, Resp),
    #{~"entries" := Entries} = nova_test:json(Resp),
    ?assert(length(Entries) >= 1),
    Config.
