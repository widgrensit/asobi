-module(asobi_ops_audit_entry).
-moduledoc """
The durable ops audit row: who acted, what they did, what to, and how it ended.

Structured logs cannot answer "who banned this player" six months later - they
are shipped somewhere else, rotated on someone else's schedule and not
joinable against the players table. ADR 0007 makes the audit a row for that
reason, so this schema is written for the queries an incident actually asks.

## Shape

The actor is flattened into four columns rather than a foreign key. There is
no actors table and, per ADR 0007, there will not be one for self-host; more
importantly a row must keep saying what it said at the time even after the
actor's capabilities change or its token source is retired. The audit is a
statement about the past, not a view of the present.

`actor_attested` carries the honesty of the name. A `static_secret` actor
labelled only by the `x-asobi-operator` header is self-declared and
spoofable, so the row records `false` and a reader can tell an asserted name
from a verified one. Dropping the flag would make every row imply a
confidence the plane does not have.

`outcome` is one of `ok`, `partial` or `error`, with `succeeded_count` and
`failed_count` beside it, because the interesting query is "show me
everything that did not fully succeed" and that must not require parsing
`details`. `details` holds the per-subject failure reasons, which are
diagnostic rather than queryable.

## Indexes

Three, each answering one question and no more:

- `(actor_id, occurred_at)` - "what did this operator do, most recent first".
- `(action, occurred_at)` - "who has banned anyone lately", the audit's
  reason to exist.
- `(target_id)` - "who has acted on this player", the support-ticket query.

`occurred_at` is the second column of two composites rather than an index of
its own: a bare time index would only serve retention pruning, and either
composite already answers a bounded time range.

## Retention

Rows are append-only - never updated, never deleted by application code. An
audit row that a later operation can rewrite is not evidence. Pruning is an
operator policy decision (jurisdiction and incident-response window differ
per deployment), so core ships no reaper; the leading `occurred_at` ordering
in both composites makes a prune a single ranged delete when one is added.

`target_id` deliberately carries no foreign key. A player deletion - GDPR
erasure included - must not cascade away the record that someone banned them.
Erasing the subject of an audit row is a separate, deliberate operation.
""".
-behaviour(kura_schema).

-include_lib("kura/include/kura.hrl").

-export([table/0, fields/0, indexes/0, generate_id/0]).

-spec table() -> binary().
table() -> ~"ops_audit_entries".

-spec generate_id() -> binary().
generate_id() -> asobi_id:generate().

-spec fields() -> [#kura_field{}].
fields() ->
    [
        #kura_field{name = id, type = uuid, primary_key = true, nullable = false},
        #kura_field{name = actor_id, type = string, nullable = false},
        #kura_field{name = actor_display, type = string, nullable = false},
        #kura_field{name = actor_source, type = string, nullable = false},
        #kura_field{name = actor_attested, type = boolean, default = false, nullable = false},
        #kura_field{name = action, type = string, nullable = false},
        #kura_field{name = target_type, type = string},
        #kura_field{name = target_id, type = string},
        #kura_field{name = outcome, type = string, nullable = false},
        #kura_field{name = succeeded_count, type = integer, default = 0, nullable = false},
        #kura_field{name = failed_count, type = integer, default = 0, nullable = false},
        #kura_field{name = details, type = jsonb, default = #{}},
        #kura_field{name = occurred_at, type = utc_datetime, nullable = false}
    ].

-spec indexes() -> [{[atom()], map()}].
indexes() ->
    [
        {[actor_id, occurred_at], #{}},
        {[action, occurred_at], #{}},
        {[target_id], #{}}
    ].
