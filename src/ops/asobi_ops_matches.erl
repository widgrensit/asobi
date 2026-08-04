-module(asobi_ops_matches).
-moduledoc """
Match-record list for the ops read plane: filter, search, sort, paginate.

`asobi_match_controller:index/1` reads the same table but returns a bare list
with no total and a fixed order. This returns the standard envelope, so a
console can page through match history and know how much of it there is.
""".

-include_lib("kura/include/kura.hrl").

-export([query/1, project/1, sortable/0]).

-define(SORTABLE, [
    {~"id", id},
    {~"mode", mode},
    {~"status", status},
    {~"started_at", started_at},
    {~"finished_at", finished_at},
    {~"inserted_at", inserted_at}
]).

-define(FILTERS, [
    {~"mode", mode, equals},
    {~"status", status, equals},
    {~"q", mode, ilike}
]).

-doc "Wire-name to column mapping this endpoint accepts in `?sort=`.".
-spec sortable() -> asobi_ops_params:sort_allowlist().
sortable() -> ?SORTABLE.

-spec query(asobi_ops_params:params()) ->
    {ok, #kura_query{}}
    | {error, {unknown_sort, binary()} | {unknown_order, binary()} | {invalid_filter, binary()}}.
query(Params) ->
    case asobi_ops_params:sort(Params, ?SORTABLE, [{inserted_at, desc}]) of
        {ok, Orders} ->
            case asobi_ops_filters:build(kura_query:from(asobi_match_record), Params, ?FILTERS) of
                {ok, Query} -> {ok, kura_query:order_by(Query, Orders)};
                {error, _} = Error -> Error
            end;
        {error, _} = Error ->
            Error
    end.

-doc """
Positive allowlist of the fields a match row may carry off this endpoint.

Identical to `asobi_match_controller`'s public projection, and for the same
reason: `players` holds the full roster of a match the caller may not have
been in, so it never leaves. `result` is game-authored and stays.
""".
-spec project(map()) -> map().
project(Record) ->
    maps:with([id, mode, status, result, started_at, finished_at, inserted_at], Record).
