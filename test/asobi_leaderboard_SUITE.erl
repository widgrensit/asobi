-module(asobi_leaderboard_SUITE).

-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1, init_per_testcase/2, end_per_testcase/2]).
-export([
    submit_and_top/1,
    rank_query/1,
    around_query/1,
    around_ranks_are_absolute/1,
    around_at_board_edges/1,
    score_update/1
]).

all() ->
    [
        submit_and_top,
        rank_query,
        around_query,
        around_ranks_are_absolute,
        around_at_board_edges,
        score_update
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(asobi),

    Config.

end_per_suite(Config) ->
    Config.

init_per_testcase(_TC, Config) ->
    BoardId = list_to_binary("board_" ++ integer_to_list(erlang:unique_integer([positive]))),
    {ok, _} = asobi_leaderboard_sup:start_board(BoardId),
    [{board_id, BoardId} | Config].

end_per_testcase(_TC, _Config) ->
    ok.

submit_and_top(Config) ->
    {board_id, BoardId} = lists:keyfind(board_id, 1, Config),
    true = is_binary(BoardId),
    asobi_leaderboard_server:submit(BoardId, ~"alice", 100),
    asobi_leaderboard_server:submit(BoardId, ~"bob", 200),
    asobi_leaderboard_server:submit(BoardId, ~"carol", 150),
    Top = asobi_leaderboard_server:top(BoardId, 3),
    ?assertMatch([{~"bob", 200, 1}, {~"carol", 150, 2}, {~"alice", 100, 3}], Top),
    Config.

rank_query(Config) ->
    {board_id, BoardId} = lists:keyfind(board_id, 1, Config),
    true = is_binary(BoardId),
    asobi_leaderboard_server:submit(BoardId, ~"alice", 100),
    asobi_leaderboard_server:submit(BoardId, ~"bob", 200),
    ?assertMatch({ok, 1}, asobi_leaderboard_server:rank(BoardId, ~"bob")),
    ?assertMatch({ok, 2}, asobi_leaderboard_server:rank(BoardId, ~"alice")),
    ?assertMatch({error, not_found}, asobi_leaderboard_server:rank(BoardId, ~"nobody")),
    Config.

around_query(Config) ->
    {board_id, BoardId} = lists:keyfind(board_id, 1, Config),
    true = is_binary(BoardId),
    lists:foreach(
        fun(I) when is_integer(I) ->
            Name = list_to_binary("player" ++ integer_to_list(I)),
            asobi_leaderboard_server:submit(BoardId, Name, I * 10)
        end,
        lists:seq(1, 10)
    ),
    Entries = asobi_leaderboard_server:around(BoardId, ~"player5", 2),
    ?assert(length(Entries) =:= 5),
    Config.

%% #334: the rank around/3 attaches was derived from a player id fed to a
%% function that walks ETS keys, so it always ran off the end of the table and
%% numbered the window from BoardSize + 1. On a 10-entry board that put
%% player5 at rank 16 while rank/2 and top/2 both said 6.
around_ranks_are_absolute(Config) ->
    {board_id, BoardId} = lists:keyfind(board_id, 1, Config),
    true = is_binary(BoardId),
    fill(BoardId, 10),
    ?assertEqual(
        [
            {~"player7", 70, 4},
            {~"player6", 60, 5},
            {~"player5", 50, 6},
            {~"player4", 40, 7},
            {~"player3", 30, 8}
        ],
        asobi_leaderboard_server:around(BoardId, ~"player5", 2)
    ),
    %% around/3 and rank/2 must agree for every player on the board.
    lists:foreach(
        fun(I) when is_integer(I) ->
            Name = list_to_binary("player" ++ integer_to_list(I)),
            {ok, Rank} = asobi_leaderboard_server:rank(BoardId, Name),
            [{Name, _, AroundRank}] = [
                E
             || {P, _, _} = E <- asobi_leaderboard_server:around(BoardId, Name, 2), P =:= Name
            ],
            ?assertEqual(Rank, AroundRank)
        end,
        lists:seq(1, 10)
    ),
    Config.

%% The window is truncated at both ends of the board, so the start rank has to
%% account for how many entries actually precede the queried player - not for
%% how many were asked for.
around_at_board_edges(Config) ->
    {board_id, BoardId} = lists:keyfind(board_id, 1, Config),
    true = is_binary(BoardId),
    fill(BoardId, 10),
    ?assertEqual(
        [{~"player10", 100, 1}, {~"player9", 90, 2}, {~"player8", 80, 3}],
        asobi_leaderboard_server:around(BoardId, ~"player10", 2)
    ),
    ?assertEqual(
        [{~"player3", 30, 8}, {~"player2", 20, 9}, {~"player1", 10, 10}],
        asobi_leaderboard_server:around(BoardId, ~"player1", 2)
    ),
    Config.

fill(BoardId, N) ->
    lists:foreach(
        fun(I) when is_integer(I) ->
            Name = list_to_binary("player" ++ integer_to_list(I)),
            asobi_leaderboard_server:submit(BoardId, Name, I * 10)
        end,
        lists:seq(1, N)
    ).

score_update(Config) ->
    {board_id, BoardId} = lists:keyfind(board_id, 1, Config),
    true = is_binary(BoardId),
    asobi_leaderboard_server:submit(BoardId, ~"alice", 100),
    asobi_leaderboard_server:submit(BoardId, ~"alice", 200),
    Top = asobi_leaderboard_server:top(BoardId, 10),
    ?assertMatch([{~"alice", 200, 1}], Top),
    Config.
