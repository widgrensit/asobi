-module(asobi_ops_tournaments).
-moduledoc """
Tournament reads for the ops plane: the list, and one tournament.

The public route answers a player's question - what can I enter - and returns
a bare list with a fixed order and no total. An operator's question is
whether a tournament that says it is running actually is, which is the `live`
flag: a row can be `status => "active"` with no process behind it after a
node restart, and that difference is invisible to every other read.

`live` is read from the global registry, never by calling the tournament
process. A list of forty tournaments must not be forty `gen_server:call`s,
and a lookup must not be able to hang on one busy tournament.
""".

-include_lib("kura/include/kura.hrl").

-export([query/1, project/1, sortable/0]).

-define(SORTABLE, [
    {~"id", id},
    {~"name", name},
    {~"leaderboard_id", leaderboard_id},
    {~"status", status},
    {~"start_at", start_at},
    {~"end_at", end_at},
    {~"inserted_at", inserted_at}
]).

-define(FILTERS, [
    {~"status", status, equals},
    {~"leaderboard_id", leaderboard_id, equals},
    {~"q", name, ilike}
]).

-doc "Wire-name to column mapping this endpoint accepts in `?sort=`.".
-spec sortable() -> asobi_ops_params:sort_allowlist().
sortable() -> ?SORTABLE.

-spec query(asobi_ops_params:params()) ->
    {ok, #kura_query{}}
    | {error, {unknown_sort, binary()} | {unknown_order, binary()} | {invalid_filter, binary()}}.
query(Params) ->
    case asobi_ops_params:sort(Params, ?SORTABLE, [{start_at, desc}]) of
        {ok, Orders} ->
            case asobi_ops_filters:build(kura_query:from(asobi_tournament), Params, ?FILTERS) of
                {ok, Query} -> {ok, kura_query:order_by(Query, Orders)};
                {error, _} = Error -> Error
            end;
        {error, _} = Error ->
            Error
    end.

-doc """
Positive allowlist of the fields a tournament may carry off this endpoint,
plus the `live` flag.

Narrower than the public `asobi_tournament_controller:show/1`, which returns
the whole row: `metadata` is game-authored and does not leave. `entry_fee`
and `rewards` do - they are the operator's own configuration and the point of
the screen.
""".
-spec project(map()) -> map().
project(Tournament) ->
    Projected = maps:with(
        [
            id,
            name,
            leaderboard_id,
            max_entries,
            entry_fee,
            rewards,
            status,
            start_at,
            end_at,
            inserted_at
        ],
        Tournament
    ),
    Projected#{live => live(maps:get(id, Tournament, undefined))}.

-spec live(binary() | undefined) -> boolean().
live(undefined) -> false;
live(Id) -> is_pid(global:whereis_name({asobi_tournament_server, Id})).
