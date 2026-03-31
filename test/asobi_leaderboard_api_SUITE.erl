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
    %% Register multiple players for leaderboard tests
    Players = lists:map(
        fun(I) ->
            U = asobi_test_helpers:unique_username(
                iolist_to_binary([~"lb_p", integer_to_binary(I)])
            ),
            {ok, R} = nova_test:post(
                ~"/api/v1/auth/register",
                #{json => #{~"username" => U, ~"password" => ~"testpass123"}},
                Config0
            ),
            B = nova_test:json(R),
            {maps:get(~"player_id", B), maps:get(~"session_token", B)}
        end,
        lists:seq(1, 5)
    ),
    [{P1Id, P1Token} | _] = Players,
    %% Start a leaderboard for testing
    BoardId = iolist_to_binary([~"test_board_", integer_to_binary(erlang:unique_integer([positive]))]),
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

auth(Token) ->
    [{~"authorization", iolist_to_binary([~"Bearer ", Token])}].

get_top_empty(Config) ->
    BoardId = proplists:get_value(board_id, Config),
    Token = proplists:get_value(player1_token, Config),
    {ok, Resp} = nova_test:get(
        iolist_to_binary([~"/api/v1/leaderboards/", BoardId]),
        #{headers => auth(Token)},
        Config
    ),
    ?assertStatus(200, Resp),
    ?assertJson(#{~"entries" := []}, Resp),
    Config.

submit_score(Config) ->
    BoardId = proplists:get_value(board_id, Config),
    Players = proplists:get_value(players, Config),
    %% Submit scores for all players
    Scores = [500, 300, 700, 100, 900],
    lists:foreach(
        fun({{_PId, Token}, Score}) ->
            {ok, Resp} = nova_test:post(
                iolist_to_binary([~"/api/v1/leaderboards/", BoardId]),
                #{
                    headers => auth(Token),
                    json => #{~"score" => Score}
                },
                Config
            ),
            ?assertStatus(200, Resp),
            Body = nova_test:json(Resp),
            ?assertEqual(Score, maps:get(~"score", Body))
        end,
        lists:zip(Players, Scores)
    ),
    Config.

get_top(Config) ->
    BoardId = proplists:get_value(board_id, Config),
    Token = proplists:get_value(player1_token, Config),
    {ok, Resp} = nova_test:get(
        iolist_to_binary([~"/api/v1/leaderboards/", BoardId]),
        #{headers => auth(Token)},
        Config
    ),
    ?assertStatus(200, Resp),
    #{~"entries" := Entries} = nova_test:json(Resp),
    ?assert(length(Entries) =:= 5),
    %% First entry should have highest score
    [First | _] = Entries,
    ?assertEqual(900, maps:get(~"score", First)),
    ?assertEqual(1, maps:get(~"rank", First)),
    Config.

get_top_with_limit(Config) ->
    BoardId = proplists:get_value(board_id, Config),
    Token = proplists:get_value(player1_token, Config),
    {ok, Resp} = nova_test:get(
        iolist_to_binary([~"/api/v1/leaderboards/", BoardId, ~"?limit=3"]),
        #{headers => auth(Token)},
        Config
    ),
    ?assertStatus(200, Resp),
    #{~"entries" := Entries} = nova_test:json(Resp),
    ?assert(length(Entries) =:= 3),
    Config.

get_around(Config) ->
    BoardId = proplists:get_value(board_id, Config),
    P1Id = proplists:get_value(player1_id, Config),
    Token = proplists:get_value(player1_token, Config),
    {ok, Resp} = nova_test:get(
        iolist_to_binary([~"/api/v1/leaderboards/", BoardId, ~"/around/", P1Id, ~"?range=2"]),
        #{headers => auth(Token)},
        Config
    ),
    ?assertStatus(200, Resp),
    #{~"entries" := Entries} = nova_test:json(Resp),
    ?assert(length(Entries) >= 1),
    Config.
