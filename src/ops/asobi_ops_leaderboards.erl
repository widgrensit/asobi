-module(asobi_ops_leaderboards).
-moduledoc """
Leaderboard reads for the ops plane: the board list, and one board's entries.

The public leaderboard routes answer a player's question - my rank, the top
100, who is near me. Neither of them can tell an operator which boards exist,
and neither can reach past row 100 of one. Both of those are
`asobi_leaderboards`; this module is the allowlist and the paging in front of
it.

The board list is sorted and paged in memory because its source is one
grouped aggregate that has to run whole whatever page is asked for - see
`asobi_leaderboards:boards/0`. The entries list is a query, paged by the
database like every other list here.
""".

-include_lib("kura/include/kura.hrl").

-export([boards/1, entries_query/2, project_board/1, project_entry/1]).
-export([boards_sortable/0, entries_sortable/0]).

-define(BOARDS_SORTABLE, [
    {~"board_id", board_id},
    {~"entries", entries},
    {~"top_score", top_score},
    {~"updated_at", updated_at}
]).

%% `rank` is deliberately absent: it is a window over the board's own order,
%% so sorting by it can only reproduce the default, and ordering by a window
%% alias would tie the endpoint to that being legal SQL.
-define(ENTRIES_SORTABLE, [
    {~"id", id},
    {~"player_id", player_id},
    {~"score", score},
    {~"sub_score", sub_score},
    {~"updated_at", updated_at}
]).

-doc "Wire-name to column mapping the board list accepts in `?sort=`.".
-spec boards_sortable() -> asobi_ops_params:sort_allowlist().
boards_sortable() -> ?BOARDS_SORTABLE.

-doc "Wire-name to column mapping the entries list accepts in `?sort=`.".
-spec entries_sortable() -> asobi_ops_params:sort_allowlist().
entries_sortable() -> ?ENTRIES_SORTABLE.

-doc """
The board list, filtered and ordered, ready to page.

Ordered by size first, because the operator question behind this endpoint is
usually which board is being written to. The order ends on `board_id`, which
is what makes the offset window stable.
""".
-spec boards(asobi_ops_params:params()) ->
    {ok, {[map()], asobi_ops_params:sort_spec()}}
    | {error, {unknown_sort, binary()} | {unknown_order, binary()} | {query_failed, term()}}.
boards(Params) ->
    case asobi_ops_params:sort(Params, ?BOARDS_SORTABLE, [{entries, desc}], {board_id, asc}) of
        {ok, Orders} ->
            case asobi_leaderboards:boards() of
                {ok, Rows} -> {ok, {search(Rows, Params), Orders}};
                {error, Reason} -> {error, {query_failed, Reason}}
            end;
        {error, _} = Error ->
            Error
    end.

%% `q` matches the board id case-insensitively, the in-memory equivalent of
%% the `ilike` the other list endpoints run.
-spec search([map()], asobi_ops_params:params()) -> [map()].
search(Rows, Params) ->
    case asobi_ops_params:search(Params, ~"q") of
        none ->
            Rows;
        {ok, Term} ->
            Needle = string:lowercase(Term),
            [Row || #{board_id := Id} = Row <- Rows, contains(string:lowercase(Id), Needle)]
    end.

-spec contains(binary() | string(), binary() | string()) -> boolean().
contains(Haystack, Needle) -> string:find(Haystack, Needle) =/= nomatch.

-doc "One board's entries as an ordered query for the shared paginator.".
-spec entries_query(binary(), asobi_ops_params:params()) ->
    {ok, #kura_query{}} | {error, {unknown_sort, binary()} | {unknown_order, binary()}}.
entries_query(BoardId, Params) ->
    Default = asobi_leaderboards:board_order(),
    case asobi_ops_params:sort(Params, ?ENTRIES_SORTABLE, Default, {player_id, asc}) of
        {ok, Orders} ->
            {ok, kura_query:order_by(asobi_leaderboards:entries_query(BoardId), Orders)};
        {error, _} = Error ->
            Error
    end.

-doc "Positive allowlist of the fields a board summary may carry off this endpoint.".
-spec project_board(map()) -> map().
project_board(Board) ->
    maps:with([board_id, entries, top_score, updated_at, live], Board).

-doc """
Positive allowlist of the fields a board entry may carry off this endpoint.

The same fields `asobi_leaderboard_controller` already returns to any player,
plus the row id. `metadata` is game-authored and does not leave.
""".
-spec project_entry(map()) -> map().
project_entry(Entry) ->
    maps:with([id, leaderboard_id, player_id, score, sub_score, rank, updated_at], Entry).
