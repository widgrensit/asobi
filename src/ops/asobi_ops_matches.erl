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

-define(MAX_FILTER_BYTES, 64).

-doc "Wire-name to column mapping this endpoint accepts in `?sort=`.".
-spec sortable() -> asobi_ops_params:sort_allowlist().
sortable() -> ?SORTABLE.

-spec query(asobi_ops_params:params()) ->
    {ok, #kura_query{}} | {error, {unknown_sort, binary()} | {unknown_order, binary()}}.
query(Params) ->
    case asobi_ops_params:sort(Params, ?SORTABLE, [{inserted_at, desc}]) of
        {ok, Orders} ->
            Query0 = kura_query:from(asobi_match_record),
            Query1 = equals(Query0, Params, ~"mode", mode),
            Query2 = equals(Query1, Params, ~"status", status),
            {ok, kura_query:order_by(search(Query2, Params), Orders)};
        {error, _} = Error ->
            Error
    end.

-spec equals(#kura_query{}, asobi_ops_params:params(), binary(), atom()) -> #kura_query{}.
equals(Query, Params, Key, Column) ->
    case maps:get(Key, Params, undefined) of
        Value when is_binary(Value), Value =/= ~"", byte_size(Value) =< ?MAX_FILTER_BYTES ->
            kura_query:where(Query, {Column, Value});
        _ ->
            Query
    end.

-spec search(#kura_query{}, asobi_ops_params:params()) -> #kura_query{}.
search(Query, Params) ->
    case asobi_ops_params:like_pattern(Params, ~"q") of
        none -> Query;
        {ok, Pattern} -> kura_query:where(Query, {mode, ilike, Pattern})
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
