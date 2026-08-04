-module(asobi_leaderboards).
-moduledoc """
Board-set reads: which boards exist, and one page of a board.

`asobi_leaderboard_server` answers questions about *one* board it already
holds in ETS - top N, a player's rank, the window around a player. Neither
question here can be answered that way. A board only becomes a process when
someone writes to it, so the process set is not the board set; and the ETS
reads are deliberately capped at 100 rows so that a caller cannot walk a
board, which is exactly what paging through one means.

Both reads therefore go to Postgres, where the scores are already persisted,
and the process layer contributes only the `live` flag. That flag is the
interesting half for an operator: a board is live-but-absent for its first 30
seconds (the flush interval), and present-but-not-live once nobody has
written to it since the node started.

Rank is computed by the database over the same total order the ETS table is
keyed on - `score` descending, then `player_id` - so a rank read here and a
rank from `asobi_leaderboard_server:rank/2` agree on any flushed score.
""".

-include_lib("kura/include/kura.hrl").

-export([boards/0, entries_query/1, board_order/0]).

%% Enumeration groups the whole entries table, so it is one aggregate scan
%% whatever the paging - there is no window that makes it cheaper. The cap
%% bounds the rows shipped back rather than the scan, and sits an order of
%% magnitude above `leaderboard_max_boards`, the ceiling on live boards.
-define(MAX_BOARDS, 1000).

-doc """
Every board with a persisted score, plus every board that is live without
one yet.

Each row is `#{board_id, entries, top_score, updated_at, live}`. Boards known
only as a running process report `entries => 0` and null aggregates: they
exist, they have simply not flushed.

Capped at 1000 boards, ordered by id so the cut is stable between calls.
""".
-spec boards() -> {ok, [map()]} | {error, term()}.
boards() ->
    case asobi_repo:all(persisted_query()) of
        {ok, Rows} -> {ok, merge_live(Rows)};
        {error, _} = Error -> Error
    end.

-spec persisted_query() -> #kura_query{}.
persisted_query() ->
    Selected = kura_query:select_expr(kura_query:from(asobi_leaderboard_entry), [
        {board_id, leaderboard_id},
        {entries, {fragment, ~"count(*)", []}},
        {top_score, {fragment, ~"max(score)", []}},
        {updated_at, {fragment, ~"max(updated_at)", []}}
    ]),
    Grouped = kura_query:group_by(Selected, [leaderboard_id]),
    kura_query:limit(kura_query:order_by(Grouped, [{leaderboard_id, asc}]), ?MAX_BOARDS).

-spec merge_live([map()]) -> [map()].
merge_live(Rows) ->
    Live = maps:from_keys(asobi_leaderboard_server:live_boards(), true),
    Persisted = [persisted_board(Row, Live) || Row <- Rows],
    Seen = maps:from_keys([Id || #{board_id := Id} <- Persisted], true),
    Persisted ++ [unflushed_board(Id) || Id <- maps:keys(Live), not maps:is_key(Id, Seen)].

-spec persisted_board(map(), #{binary() => true}) -> map().
persisted_board(Row, Live) ->
    Id = maps:get(board_id, Row),
    #{
        board_id => Id,
        entries => maps:get(entries, Row, 0),
        top_score => maps:get(top_score, Row, null),
        updated_at => maps:get(updated_at, Row, null),
        live => maps:is_key(Id, Live)
    }.

-spec unflushed_board(binary()) -> map().
unflushed_board(Id) ->
    #{board_id => Id, entries => 0, top_score => null, updated_at => null, live => true}.

-doc """
One board's entries, ranked, as a query for the shared paginator.

Returns a query rather than rows because the count and the page have to run
as one unit against the same filter - `asobi_ops_page` owns that - and
because the caller supplies the ordering. Rank is not the caller's to order
by: it is a window over `board_order/0` computed before `LIMIT` applies, so
row 501 reports rank 501 however the page itself is sorted. No partition is
needed, the `WHERE` already narrows the window to one board.
""".
-spec entries_query(binary()) -> #kura_query{}.
entries_query(BoardId) ->
    Scoped = kura_query:where(
        kura_query:from(asobi_leaderboard_entry), {leaderboard_id, BoardId}
    ),
    kura_query:select_expr(Scoped, [
        {id, id},
        {leaderboard_id, leaderboard_id},
        {player_id, player_id},
        {score, score},
        {sub_score, sub_score},
        {updated_at, updated_at},
        {rank, kura_query:over(row_number, #{order_by => board_order()})}
    ]).

-doc """
The total order a board is ranked in, shared by the rank window and the
default listing order so the two cannot drift apart.

`player_id` is unique within a board, so this is total, which is also what
makes offset paging safe.
""".
-spec board_order() -> [{atom(), asc | desc}].
board_order() -> [{score, desc}, {player_id, asc}].
