-module(asobi_ops_filters).
-moduledoc """
The `WHERE` clauses an ops list endpoint builds from its query string.

Each endpoint declares a spec list and this builds the query, so the rules
below hold everywhere rather than once per module:

* An absent or empty filter narrows nothing. A caller can see that: it gets a
  superset and the rows to prove it.
* A filter whose value cannot be the shape its column holds - a `player_id`
  that is not a uuid - is a **400**, not a dropped clause. Dropping it would
  answer a request scoped to one player with every player's rows, and that is
  the failure a caller cannot see.
* An oversized exact-match value is dropped rather than rejected, which is
  what these endpoints did before this module existed.
* `ilike` patterns come from `asobi_ops_params:like_pattern/2`, so `%` and `_`
  inside a search term match literally instead of turning the search into a
  scan of the whole table.

Compare `asobi_ops_params:sort/3`, which *rejects* an unknown field: a wrong
sort returns a page silently ordered by something else, which no response
body reveals.
""".

-include_lib("kura/include/kura.hrl").

-export([build/3]).

-export_type([spec/0]).

-type kind() :: equals | boolean | uuid | ilike.
-type spec() :: {binary(), atom() | [atom()], kind()}.

-doc """
Apply `Specs` to `Query` in order, resolving each against `Params`.

Named `build` rather than `apply` so it cannot be read as the BIF.
""".
-spec build(#kura_query{}, asobi_ops_params:params(), [spec()]) ->
    {ok, #kura_query{}} | {error, {invalid_filter, binary()}}.
build(Query, _Params, []) ->
    {ok, Query};
build(Query, Params, [Spec | Rest]) ->
    case clause(Params, Spec) of
        {ok, Where} -> build(kura_query:where(Query, Where), Params, Rest);
        none -> build(Query, Params, Rest);
        {error, _} = Error -> Error
    end.

-spec clause(asobi_ops_params:params(), spec()) ->
    {ok, term()} | none | {error, {invalid_filter, binary()}}.
clause(Params, {Key, Column, equals}) ->
    case asobi_ops_params:filter(Params, Key) of
        {ok, Value} -> {ok, {Column, Value}};
        none -> none
    end;
clause(Params, {Key, Column, boolean}) ->
    case asobi_ops_params:boolean(Params, Key) of
        {ok, Value} -> {ok, {Column, Value}};
        none -> none
    end;
clause(Params, {Key, Column, uuid}) ->
    case asobi_ops_params:filter(Params, Key) of
        {ok, Value} ->
            case asobi_ops_params:uuid(Value) of
                true -> {ok, {Column, Value}};
                false -> {error, {invalid_filter, Key}}
            end;
        none ->
            none
    end;
clause(Params, {Key, Columns, ilike}) ->
    case asobi_ops_params:like_pattern(Params, Key) of
        {ok, Pattern} -> {ok, ilike(Columns, Pattern)};
        none -> none
    end.

-spec ilike(atom() | [atom()], binary()) -> term().
ilike(Column, Pattern) when is_atom(Column) -> {Column, ilike, Pattern};
ilike([Column], Pattern) -> {Column, ilike, Pattern};
ilike(Columns, Pattern) -> {'or', [{Column, ilike, Pattern} || Column <- Columns]}.
