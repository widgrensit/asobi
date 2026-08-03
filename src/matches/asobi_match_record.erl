-module(asobi_match_record).
-behaviour(kura_schema).

-include_lib("kura/include/kura.hrl").

-export([table/0, fields/0, associations/0, indexes/0, generate_id/0]).
-export([to_timestamp/1]).

-doc """
Convert a match server's monotonic-ish millisecond stamp into the
`utc_datetime` the `started_at` / `finished_at` columns hold.

Both servers keep their timers in `erlang:system_time(millisecond)`, and
`kura_changeset:cast/4` rejects an integer for a `utc_datetime` field with
`cannot cast to utc_datetime` - which is why every finished match failed to
persist until asobi#329.
""".
-spec to_timestamp(integer() | undefined) -> calendar:datetime() | undefined.
to_timestamp(undefined) ->
    undefined;
to_timestamp(Millis) when is_integer(Millis) ->
    calendar:system_time_to_universal_time(Millis, millisecond).

-spec table() -> binary().
table() -> ~"match_records".

-spec fields() -> [#kura_field{}].
fields() ->
    [
        #kura_field{name = id, type = uuid, primary_key = true, nullable = false},
        #kura_field{name = mode, type = string},
        #kura_field{name = status, type = string, nullable = false},
        #kura_field{name = players, type = jsonb, default = []},
        #kura_field{name = result, type = jsonb, default = #{}},
        #kura_field{name = metadata, type = jsonb, default = #{}},
        #kura_field{name = started_at, type = utc_datetime},
        #kura_field{name = finished_at, type = utc_datetime},
        #kura_field{name = inserted_at, type = utc_datetime, nullable = false}
    ].

-spec generate_id() -> binary().
generate_id() -> asobi_id:generate().

-spec associations() -> [#kura_assoc{}].
associations() -> [].

-spec indexes() -> [{[atom()], map()}].
indexes() ->
    [
        {[mode], #{}},
        {[status], #{}}
    ].
