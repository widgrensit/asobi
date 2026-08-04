-module(asobi_ops_lookup).
-moduledoc """
Fetch one row by primary key for the ops read plane.

The list endpoints answer what exists; a console that renders a list then
needs the row behind a click, and until now nothing in the plane could serve
one - there was no `/ops/players/:id` and no `/ops/matches/:id` anywhere.

The id is checked for uuid shape before it reaches the database
(`asobi_ops_params:uuid/1`) and the row is passed through the endpoint's own
projection on the way out, so a lookup can never return a field its list
would have withheld.
""".

-export([fetch/3]).

-doc """
The row `Id` names in `Schema`, projected.

`invalid_id` is a malformed binding, `not_found` a real miss, and
`{query_failed, Reason}` anything else - three outcomes the caller answers
with 400, 404 and 500 respectively, so a bad request is never reported as a
server fault.
""".
-spec fetch(module(), term(), fun((map()) -> map())) ->
    {ok, map()} | {error, invalid_id | not_found | {query_failed, term()}}.
fetch(Schema, Id, Project) ->
    case asobi_ops_params:uuid(Id) of
        true -> project(asobi_repo:get(Schema, Id), Project);
        false -> {error, invalid_id}
    end.

-spec project({ok, map()} | {error, term()}, fun((map()) -> map())) ->
    {ok, map()} | {error, not_found | {query_failed, term()}}.
project({ok, Row}, Project) -> {ok, Project(Row)};
project({error, not_found}, _Project) -> {error, not_found};
project({error, Reason}, _Project) -> {error, {query_failed, Reason}}.
