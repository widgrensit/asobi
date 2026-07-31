-module(asobi_jsonb).
-moduledoc """
Size-bound checks for values headed into an unbounded `jsonb` column.

A `jsonb` column has no server-side size limit of its own, so any field a
client can populate through a changeset cast is a lever for an oversized
payload unless something checks it first (asobi#169, asobi#216). This is
the one place that idiom lives, shared by every schema and controller that
needs it rather than a per-call-site copy.
""".

-export([within_limit/2, check/2, default_metadata_bytes/0]).

-spec within_limit(dynamic(), non_neg_integer()) -> boolean().
within_limit(Value, MaxBytes) ->
    check(Value, MaxBytes) =:= ok.

%% A caller that reports a specific reason to a client or a log wants
%% "too big" and "not valid JSON at all" told apart - shrinking a payload
%% doesn't fix the latter. within_limit/2 collapses both into `false` for
%% callers (a size-only gate ahead of an insert) that don't need the
%% distinction.
-spec check(dynamic(), non_neg_integer()) -> ok | too_large | not_encodable.
check(Value, MaxBytes) ->
    try iolist_size(json:encode(Value)) of
        Size when Size =< MaxBytes -> ok;
        _ -> too_large
    catch
        _:_ -> not_encodable
    end.

%% The shared ceiling for a "metadata annotation" field (as opposed to a
%% bulk-data field like cloud-save/storage values, which set their own,
%% larger limit) - one place so every schema that adopts this idiom agrees
%% by default rather than each declaring its own copy of the same number.
-spec default_metadata_bytes() -> non_neg_integer().
default_metadata_bytes() -> 16384.
