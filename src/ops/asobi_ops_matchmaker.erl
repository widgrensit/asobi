-module(asobi_ops_matchmaker).
-moduledoc """
The matchmaking queue for the ops plane: one row per mode.

The rows come from `asobi_matchmaker:snapshot/0`, an ETS read that never
touches the matchmaker's mailbox - the reason is on that function, and it is
the whole design of this endpoint.

No ticket, player or property ever appears here. An operator asking about the
queue is asking whether a mode is filling, which is a count and two waits;
who is waiting is player data and belongs behind a capability, not behind the
same bearer token the game client already holds.
""".

-export([rows/2, summary/1, project/1, sortable/0]).

-define(SORTABLE, [
    {~"mode", mode},
    {~"waiting", waiting},
    {~"oldest_wait_ms", oldest_wait_ms},
    {~"average_wait_ms", average_wait_ms}
]).

-doc "Wire-name to column mapping this endpoint accepts in `?sort=`.".
-spec sortable() -> asobi_ops_params:sort_allowlist().
sortable() -> ?SORTABLE.

-doc """
The per-mode rows and the order to page them in.

Deepest queue first, since that is the mode in trouble. `mode` is unique
across the rows and ends the order, so the offset window cannot repeat a row.
""".
-spec rows(asobi_matchmaker:snapshot(), asobi_ops_params:params()) ->
    {ok, {[map()], asobi_ops_params:sort_spec()}}
    | {error, {unknown_sort, binary()} | {unknown_order, binary()}}.
rows(#{modes := Modes}, Params) ->
    case asobi_ops_params:sort(Params, ?SORTABLE, [{waiting, desc}], {mode, asc}) of
        {ok, Orders} -> {ok, {Modes, Orders}};
        {error, _} = Error -> Error
    end.

-doc """
Queue-wide totals, reported alongside the page.

`sampled_at` and `age_ms` are part of the answer, not decoration: the counts
are as old as the last matchmaker tick, and a console that renders them as
live would show a queue that never quite settles.
""".
-spec summary(asobi_matchmaker:snapshot()) -> map().
summary(#{sampled_at := SampledAt, age_ms := AgeMs, waiting := Waiting, modes := Modes}) ->
    #{
        waiting => Waiting,
        modes => length(Modes),
        sampled_at => SampledAt,
        age_ms => AgeMs
    }.

-doc "Positive allowlist of the fields a queue row may carry off this endpoint.".
-spec project(map()) -> map().
project(Row) ->
    maps:with([mode, waiting, oldest_wait_ms, average_wait_ms], Row).
