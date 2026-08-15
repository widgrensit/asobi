-module(asobi_ops_players).
-moduledoc """
Player list for the ops read plane: filter, search, sort, paginate.

Search is `ILIKE` across `username` and `display_name`. The endpoints this
replaces searched by exact equality on a single column, which meant an
operator had to already know the username to find it.

`?guest=true` narrows to unclaimed guests, and `?guest=false` to everyone
else. The predicate is `asobi_guest_purge:clause/1`'s, not a second reading
of it: this list is what an operator looks at before purging that cohort, and a
list that disagrees with the purge is a list that promises the wrong deletion.
""".

-include_lib("kura/include/kura.hrl").

-export([query/1, project/1, sortable/0]).

%% Sortable fields are a subset of the projection below. A column that is
%% sorted on but not returned leaks its ordering to a caller who is not
%% allowed to read it.
-define(SORTABLE, [
    {~"id", id},
    {~"username", username},
    {~"display_name", display_name},
    {~"inserted_at", inserted_at},
    {~"updated_at", updated_at}
]).

-doc "Wire-name to column mapping this endpoint accepts in `?sort=`.".
-spec sortable() -> asobi_ops_params:sort_allowlist().
sortable() -> ?SORTABLE.

-define(FILTERS, [
    {~"q", [username, display_name], ilike}
]).

-spec query(asobi_ops_params:params()) ->
    {ok, #kura_query{}}
    | {error, {unknown_sort, binary()} | {unknown_order, binary()} | {invalid_filter, binary()}}.
query(Params) ->
    case asobi_ops_params:sort(Params, ?SORTABLE, [{inserted_at, desc}]) of
        {ok, Orders} ->
            case asobi_ops_filters:build(kura_query:from(asobi_player), Params, ?FILTERS) of
                {ok, Query} -> {ok, kura_query:order_by(guest(Query, Params), Orders)};
                {error, _} = Error -> Error
            end;
        {error, _} = Error ->
            Error
    end.

%% Not an `asobi_ops_filters` spec: those build one clause over one column of
%% the table being listed, and "is an unclaimed guest" is a statement about two
%% correlated subqueries and a column this endpoint refuses to project. An
%% unparseable value narrows nothing, the same as every other absent filter.
-spec guest(#kura_query{}, asobi_ops_params:params()) -> #kura_query{}.
guest(Query, Params) ->
    case asobi_ops_params:boolean(Params, ~"guest") of
        {ok, true} -> kura_query:where(Query, asobi_guest_purge:clause(undefined));
        {ok, false} -> kura_query:where(Query, {'not', asobi_guest_purge:clause(undefined)});
        none -> Query
    end.

-doc """
Positive allowlist of the fields a player row may carry off this endpoint.

Deliberately identical to `asobi_player_controller`'s projection: these routes
sit behind the same player-scoped auth plugin, so they must not widen what an
authenticated caller can already read. `hashed_password` must never appear
here. Widening the projection waits on the capability model (ADR 0007).
""".
-spec project(map()) -> map().
project(Player) ->
    maps:with(
        [id, username, display_name, avatar_url, metadata, inserted_at, updated_at],
        Player
    ).
