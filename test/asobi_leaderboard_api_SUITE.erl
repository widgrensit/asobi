-module(asobi_leaderboard_api_SUITE).

-include_lib("nova_test/include/nova_test.hrl").

-define(OPS_SECRET, ~"8e3a5d17c94b60f2ae81d3705c6f9b24d0a7e158b3c92f46071dab5e8c249f30").

-export([all/0, groups/0, init_per_suite/1, end_per_suite/1]).
-export([
    submit_score/1,
    submit_score_disabled/1,
    get_top/1,
    get_top_with_limit/1,
    get_around/1,
    get_top_empty/1,
    ops_board_listing/1,
    ops_board_entries_are_ranked_across_pages/1,
    ops_board_entries_reject_unknown_sort/1
]).

all() -> [{group, leaderboard_api}].

groups() ->
    [
        {leaderboard_api, [sequence], [
            get_top_empty,
            submit_score_disabled,
            submit_score,
            get_top,
            get_top_with_limit,
            get_around,
            ops_board_listing,
            ops_board_entries_are_ranked_across_pages,
            ops_board_entries_reject_unknown_sort
        ]}
    ].

init_per_suite(Config) ->
    Config0 = asobi_test_helpers:start(Config),
    %% The ops plane authenticates as an operator, not as a player (ADR 0007).
    %% Without this the reads below get a correct 403 rather than their data.
    OpsSecretWas = application:get_env(asobi, ops_secret),
    application:set_env(asobi, ops_secret, ?OPS_SECRET),
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
            #{~"player_id" := PId, ~"access_token" := PToken} = nova_test:json(R),
            {PId, PToken}
        end,
        lists:seq(1, 5)
    ),
    [{P1Id, P1Token} | _] = Players,
    BoardId = iolist_to_binary([
        ~"test_board_", integer_to_binary(erlang:unique_integer([positive]))
    ]),
    DisabledBoardId = iolist_to_binary([
        ~"test_board_disabled_", integer_to_binary(erlang:unique_integer([positive]))
    ]),
    {ok, _} = asobi_leaderboard_sup:start_board(BoardId),
    %% Whitelist this board for client submits — submit_score_disabled
    %% deliberately uses an un-whitelisted board to confirm the gate.
    application:set_env(asobi, leaderboard_client_submit, [BoardId]),
    %% The ops reads are database reads. Seed rows straight into the table
    %% rather than waiting out the 30s flush, and out of rank order so the
    %% ranking is proven rather than inherited from the insert order.
    OpsBoardId = iolist_to_binary([
        ~"ops_board_", integer_to_binary(erlang:unique_integer([positive]))
    ]),
    [{Pa, _}, {Pb, _}, {Pc, _} | _] = Players,
    ok = seed_entry(OpsBoardId, Pb, 100),
    ok = seed_entry(OpsBoardId, Pa, 300),
    ok = seed_entry(OpsBoardId, Pc, 200),
    [
        {board_id, BoardId},
        {disabled_board_id, DisabledBoardId},
        {ops_board_id, OpsBoardId},
        {player1_id, P1Id},
        {player1_token, P1Token},
        {players, Players},
        {ops_secret_was, OpsSecretWas}
        | Config0
    ].

end_per_suite(Config) ->
    application:unset_env(asobi, leaderboard_client_submit),
    restore_ops_secret(Config),
    Config.

restore_ops_secret(Config) ->
    case lists:keyfind(ops_secret_was, 1, Config) of
        {ops_secret_was, {ok, Value}} -> application:set_env(asobi, ops_secret, Value);
        _ -> application:unset_env(asobi, ops_secret)
    end.

auth(Token) when is_binary(Token) ->
    [{~"authorization", <<"Bearer ", Token/binary>>}].

%% The ops plane takes the operator credential, never a player token - a player
%% token is a correct 403 here (ADR 0007), which is asserted in asobi_api_SUITE.
ops_auth() ->
    [{~"authorization", <<"Bearer ", (?OPS_SECRET)/binary>>}].

seed_entry(BoardId, PlayerId, Score) ->
    Changeset = kura_changeset:cast(
        asobi_leaderboard_entry,
        #{},
        #{leaderboard_id => BoardId, player_id => PlayerId, score => Score, sub_score => 0},
        [leaderboard_id, player_id, score, sub_score]
    ),
    {ok, _} = asobi_repo:insert(Changeset),
    ok.

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

submit_score_disabled(Config) ->
    %% A board not on the whitelist must reject client submits with 403,
    %% even from an authenticated player.
    {disabled_board_id, BoardId} = lists:keyfind(disabled_board_id, 1, Config),
    {player1_token, Token} = lists:keyfind(player1_token, 1, Config),
    true = is_binary(BoardId),
    true = is_binary(Token),
    {ok, Resp} = nova_test:post(
        "/api/v1/leaderboards/" ++ binary_to_list(BoardId),
        #{headers => auth(Token), json => #{~"score" => 9001}},
        Config
    ),
    ?assertStatus(403, Resp),
    ?assertJson(#{~"error" := #{~"code" := ~"leaderboard.client_submit_disabled"}}, Resp),
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
    true = is_list(Entries),
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
    true = is_list(Entries),
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
    true = is_list(Entries),
    ?assert(length(Entries) >= 1),
    Config.

%% Enumerating boards is the read core had no way to answer: the grouped
%% aggregate has to compile and run, not just build.
ops_board_listing(Config) ->
    {ops_board_id, BoardId} = lists:keyfind(ops_board_id, 1, Config),
    {player1_token, Token} = lists:keyfind(player1_token, 1, Config),
    true = is_binary(BoardId),
    true = is_binary(Token),
    {ok, Resp} = nova_test:get(
        "/api/v1/ops/leaderboards?q=" ++ binary_to_list(BoardId),
        #{headers => ops_auth()},
        Config
    ),
    ?assertStatus(200, Resp),
    #{~"data" := [Board], ~"page" := Page} = nova_test:json(Resp),
    ?assertEqual(BoardId, maps:get(~"board_id", Board)),
    ?assertEqual(3, maps:get(~"entries", Board)),
    ?assertEqual(300, maps:get(~"top_score", Board)),
    ?assertEqual(false, maps:get(~"live", Board)),
    ?assertEqual(1, maps:get(~"total", Page)),
    Config.

%% Rank is a window over the whole board, so page two carries rank 3 - not
%% rank 1 restarted. That is the difference between a paged leaderboard and
%% three unrelated pages of rows.
ops_board_entries_are_ranked_across_pages(Config) ->
    {ops_board_id, BoardId} = lists:keyfind(ops_board_id, 1, Config),
    {player1_token, Token} = lists:keyfind(player1_token, 1, Config),
    true = is_binary(BoardId),
    true = is_binary(Token),
    Path = "/api/v1/ops/leaderboards/" ++ binary_to_list(BoardId) ++ "/entries",
    {ok, First} = nova_test:get(Path ++ "?limit=2", #{headers => ops_auth()}, Config),
    ?assertStatus(200, First),
    #{~"data" := FirstRows, ~"page" := FirstPage} = nova_test:json(First),
    ?assertEqual(3, maps:get(~"total", FirstPage)),
    ?assertEqual([{300, 1}, {200, 2}], [
        {maps:get(~"score", R), maps:get(~"rank", R)}
     || R <- FirstRows
    ]),
    {ok, Second} = nova_test:get(
        Path ++ "?limit=2&offset=2", #{headers => ops_auth()}, Config
    ),
    ?assertStatus(200, Second),
    #{~"data" := SecondRows} = nova_test:json(Second),
    ?assertEqual([{100, 3}], [
        {maps:get(~"score", R), maps:get(~"rank", R)}
     || R <- SecondRows
    ]),
    Config.

ops_board_entries_reject_unknown_sort(Config) ->
    {ops_board_id, BoardId} = lists:keyfind(ops_board_id, 1, Config),
    {player1_token, Token} = lists:keyfind(player1_token, 1, Config),
    true = is_binary(BoardId),
    true = is_binary(Token),
    {ok, Resp} = nova_test:get(
        "/api/v1/ops/leaderboards/" ++ binary_to_list(BoardId) ++ "/entries?sort=metadata",
        #{headers => ops_auth()},
        Config
    ),
    ?assertStatus(400, Resp),
    %% `field` keeps its top-level place and is repeated in `details`.
    ?assertJson(
        #{
            ~"error" := #{
                ~"code" := ~"ops.unknown_sort_field",
                ~"details" := #{~"field" := ~"metadata"}
            },
            ~"field" := ~"metadata"
        },
        Resp
    ),
    Config.
