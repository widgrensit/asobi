-module(asobi_jsonb).
-moduledoc """
Size-bound checks for values headed into an unbounded `jsonb` column.

A `jsonb` column has no server-side size limit of its own, so any field a
client can populate through a changeset cast is a lever for an oversized
payload unless something checks it first (asobi#169, asobi#216). This is
the one place that idiom lives, shared by every schema and controller that
needs it rather than a per-call-site copy.
""".

-export([within_limit/2]).

-spec within_limit(dynamic(), non_neg_integer()) -> boolean().
within_limit(Value, MaxBytes) ->
    try iolist_size(json:encode(Value)) =< MaxBytes of
        Result -> Result
    catch
        _:_ -> false
    end.
