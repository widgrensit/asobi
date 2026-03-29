-module(asobi_leaderboard_SUITE).

-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1, init_per_testcase/2, end_per_testcase/2]).
-export([
    submit_and_top/1,
    rank_query/1,
    around_query/1,
    score_update/1
]).

all() -> [submit_and_top, rank_query, around_query, score_update].

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
    BoardId = proplists:get_value(board_id, Config),
    asobi_leaderboard_server:submit(BoardId, ~"alice", 100),
    asobi_leaderboard_server:submit(BoardId, ~"bob", 200),
    asobi_leaderboard_server:submit(BoardId, ~"carol", 150),
    Top = asobi_leaderboard_server:top(BoardId, 3),
    ?assertMatch([{~"bob", 200, 1}, {~"carol", 150, 2}, {~"alice", 100, 3}], Top),
    Config.

rank_query(Config) ->
    BoardId = proplists:get_value(board_id, Config),
    asobi_leaderboard_server:submit(BoardId, ~"alice", 100),
    asobi_leaderboard_server:submit(BoardId, ~"bob", 200),
    ?assertMatch({ok, 1}, asobi_leaderboard_server:rank(BoardId, ~"bob")),
    ?assertMatch({ok, 2}, asobi_leaderboard_server:rank(BoardId, ~"alice")),
    ?assertMatch({error, not_found}, asobi_leaderboard_server:rank(BoardId, ~"nobody")),
    Config.

around_query(Config) ->
    BoardId = proplists:get_value(board_id, Config),
    lists:foreach(
        fun(I) ->
            Name = list_to_binary("player" ++ integer_to_list(I)),
            asobi_leaderboard_server:submit(BoardId, Name, I * 10)
        end,
        lists:seq(1, 10)
    ),
    Entries = asobi_leaderboard_server:around(BoardId, ~"player5", 2),
    ?assert(length(Entries) =:= 5),
    Config.

score_update(Config) ->
    BoardId = proplists:get_value(board_id, Config),
    asobi_leaderboard_server:submit(BoardId, ~"alice", 100),
    asobi_leaderboard_server:submit(BoardId, ~"alice", 200),
    Top = asobi_leaderboard_server:top(BoardId, 10),
    ?assertMatch([{~"alice", 200, 1}], Top),
    Config.
