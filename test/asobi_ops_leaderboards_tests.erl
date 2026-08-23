-module(asobi_ops_leaderboards_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("kura/include/kura.hrl").

%%--------------------------------------------------------------------
%% Board enumeration
%%--------------------------------------------------------------------

boards_test_() ->
    {setup, fun setup_repo/0, fun cleanup_repo/1, [
        fun enumeration_is_grouped_and_capped/0,
        fun persisted_board_is_summarised/0,
        fun live_board_without_rows_is_listed/0,
        fun persisted_board_is_flagged_live/0,
        fun repo_error_is_reported_not_swallowed/0
    ]}.

setup_repo() ->
    meck:new(asobi_repo, [passthrough]),
    meck:new(asobi_leaderboard_server, [passthrough]),
    meck:expect(asobi_leaderboard_server, live_boards, fun() -> [] end),
    ok.

cleanup_repo(_) ->
    catch meck:unload(asobi_repo),
    catch meck:unload(asobi_leaderboard_server),
    ok.

expect_groups(Rows) ->
    meck:expect(asobi_repo, all, fun(_Query) -> {ok, Rows} end).

group_row(Id, Entries, TopScore) ->
    #{
        board_id => Id,
        entries => Entries,
        top_score => TopScore,
        updated_at => {{2026, 8, 3}, {12, 0, 0}}
    }.

%% Counting every board is one aggregate scan whatever page is asked for, so
%% the query has to group and has to be capped - an uncapped enumeration would
%% ship a row per board id ever written.
enumeration_is_grouped_and_capped() ->
    expect_groups([]),
    meck:reset(asobi_repo),
    {ok, _} = asobi_leaderboards:boards(),
    %% Exactly one call, which is what "grouped and capped" means and why
    %% meck:reset/1 is above: an added asobi_repo:one/1 must fail here.
    ?assertMatch([_], meck:history(asobi_repo)),
    [Query] = [
        Q
     || {_, {asobi_repo, all, [Q]}, _} <- meck:history(asobi_repo), is_record(Q, kura_query)
    ],
    ?assertEqual([leaderboard_id], Query#kura_query.group_bys),
    ?assertEqual([{leaderboard_id, asc}], Query#kura_query.order_bys),
    ?assertEqual(1000, Query#kura_query.limit).

persisted_board_is_summarised() ->
    expect_groups([group_row(~"arena", 12, 900)]),
    {ok, [Board]} = asobi_leaderboards:boards(),
    ?assertEqual(~"arena", maps:get(board_id, Board)),
    ?assertEqual(12, maps:get(entries, Board)),
    ?assertEqual(900, maps:get(top_score, Board)),
    ?assertEqual(false, maps:get(live, Board)).

%% A board is a process before it is a row: nothing is flushed for the first 30
%% seconds. Enumerating only the table would tell an operator a board they can
%% already read from does not exist.
live_board_without_rows_is_listed() ->
    expect_groups([]),
    meck:expect(asobi_leaderboard_server, live_boards, fun() -> [~"fresh"] end),
    {ok, [Board]} = asobi_leaderboards:boards(),
    ?assertEqual(
        #{board_id => ~"fresh", entries => 0, top_score => null, updated_at => null, live => true},
        Board
    ).

persisted_board_is_flagged_live() ->
    expect_groups([group_row(~"arena", 12, 900), group_row(~"duel", 3, 10)]),
    meck:expect(asobi_leaderboard_server, live_boards, fun() -> [~"arena"] end),
    {ok, Boards} = asobi_leaderboards:boards(),
    ?assertEqual(2, length(Boards)),
    ?assertEqual([{~"arena", true}, {~"duel", false}], [
        {Id, Live}
     || #{board_id := Id, live := Live} <- Boards
    ]).

repo_error_is_reported_not_swallowed() ->
    meck:expect(asobi_repo, all, fun(_Query) -> {error, closed} end),
    ?assertEqual({error, closed}, asobi_leaderboards:boards()),
    ?assertEqual(
        {error, {query_failed, closed}}, asobi_ops_leaderboards:boards(#{})
    ).

%%--------------------------------------------------------------------
%% Board list paging
%%--------------------------------------------------------------------

board_list_test_() ->
    {setup, fun setup_repo/0, fun cleanup_repo/1, [
        fun boards_default_order_is_deterministic/0,
        fun boards_sort_uses_allowlisted_atom/0,
        fun boards_reject_unknown_sort/0,
        fun boards_search_matches_id_case_insensitively/0
    ]}.

boards_default_order_is_deterministic() ->
    expect_groups([]),
    {ok, {_Rows, Orders}} = asobi_ops_leaderboards:boards(#{}),
    ?assertEqual([{entries, desc}, {board_id, asc}], Orders).

%% Boards have no `id` column, so the default tie-breaker would order by a
%% field that is not there and leave the window unstable.
boards_sort_uses_allowlisted_atom() ->
    expect_groups([]),
    {ok, {_Rows, Orders}} = asobi_ops_leaderboards:boards(#{~"sort" => ~"top_score"}),
    ?assertEqual([{top_score, asc}, {board_id, asc}], Orders).

boards_reject_unknown_sort() ->
    expect_groups([]),
    ?assertEqual(
        {error, {unknown_sort, ~"metadata"}},
        asobi_ops_leaderboards:boards(#{~"sort" => ~"metadata"})
    ).

boards_search_matches_id_case_insensitively() ->
    expect_groups([group_row(~"Arena_EU", 1, 1), group_row(~"duel", 1, 1)]),
    {ok, {Rows, _Orders}} = asobi_ops_leaderboards:boards(#{~"q" => ~"arena"}),
    ?assertEqual([~"Arena_EU"], [Id || #{board_id := Id} <- Rows]).

%%--------------------------------------------------------------------
%% Entries query
%%--------------------------------------------------------------------

entries_scoped_to_one_board_test() ->
    {ok, Query} = asobi_ops_leaderboards:entries_query(~"arena", #{}),
    ?assertEqual([{leaderboard_id, ~"arena"}], Query#kura_query.wheres).

entries_default_order_is_the_board_order_test() ->
    {ok, Query} = asobi_ops_leaderboards:entries_query(~"arena", #{}),
    ?assertEqual([{score, desc}, {player_id, asc}], Query#kura_query.order_bys).

%% The invariant that keeps a paged rank honest: the window the database ranks
%% in is the same total order the rows come back in, and the same one
%% `asobi_leaderboard_server` keys its ETS table on.
entries_rank_window_matches_the_board_order_test() ->
    {ok, Query} = asobi_ops_leaderboards:entries_query(~"arena", #{}),
    {exprs, Exprs} = Query#kura_query.select,
    [#{order_by := WindowOrder}] = [
        W
     || {rank, {over, row_number, W}} <- Exprs, is_map(W)
    ],
    ?assertEqual(asobi_leaderboards:board_order(), WindowOrder),
    ?assertEqual(WindowOrder, Query#kura_query.order_bys).

%% `player_id` is unique within a board, so it is what the order must end on;
%% a sort on `score` alone repeats rows across pages whenever scores tie.
entries_order_ends_on_the_unique_key_test() ->
    {ok, Query} = asobi_ops_leaderboards:entries_query(~"arena", #{~"sort" => ~"score"}),
    ?assertEqual([{score, asc}, {player_id, asc}], Query#kura_query.order_bys).

entries_reject_unknown_sort_test() ->
    ?assertEqual(
        {error, {unknown_sort, ~"metadata"}},
        asobi_ops_leaderboards:entries_query(~"arena", #{~"sort" => ~"metadata"})
    ).

entries_reject_unknown_order_test() ->
    ?assertEqual(
        {error, {unknown_order, ~"random"}},
        asobi_ops_leaderboards:entries_query(~"arena", #{
            ~"sort" => ~"score", ~"order" => ~"random"
        })
    ).

%%--------------------------------------------------------------------
%% Projections
%%--------------------------------------------------------------------

entry_projection_drops_game_authored_metadata_test() ->
    Projected = asobi_ops_leaderboards:project_entry(#{
        id => ~"e1",
        leaderboard_id => ~"arena",
        player_id => ~"p1",
        score => 900,
        sub_score => 2,
        rank => 1,
        updated_at => undefined,
        metadata => #{~"secret" => true}
    }),
    ?assertNot(maps:is_key(metadata, Projected)),
    ?assertEqual(1, maps:get(rank, Projected)).

board_projection_is_an_allowlist_test() ->
    Projected = asobi_ops_leaderboards:project_board(
        (group_row(~"arena", 1, 1))#{live => false, secret => ~"no"}
    ),
    ?assertEqual(
        [board_id, entries, live, top_score, updated_at], lists:sort(maps:keys(Projected))
    ).

boards_sortable_fields_are_all_projected_test() ->
    Projected = maps:keys(
        asobi_ops_leaderboards:project_board((group_row(~"arena", 1, 1))#{live => false})
    ),
    [
        ?assert(lists:member(Column, Projected))
     || {_Wire, Column} <- asobi_ops_leaderboards:boards_sortable()
    ].

entries_sortable_fields_are_all_projected_test() ->
    Projected = maps:keys(
        asobi_ops_leaderboards:project_entry(#{
            id => ~"e1",
            leaderboard_id => ~"arena",
            player_id => ~"p1",
            score => 1,
            sub_score => 0,
            rank => 1,
            updated_at => undefined
        })
    ),
    [
        ?assert(lists:member(Column, Projected))
     || {_Wire, Column} <- asobi_ops_leaderboards:entries_sortable()
    ].
