# ADR 0007: Ops mutations are audited as durable rows, with a partial-failure outcome

Date: 2026-08-04

## Status

Accepted. Implements the audit half of the ecosystem's
`0007-ops-identity-and-capabilities`, which introduced the actor record.

## Context

The actor record `#{id, display, source, caps, attested}` ships and resolves
on every ops request, but nothing writes it anywhere durable. Attribution
that lives only in the request is gone the moment the response is sent.

The console's audit is structured logs, through one function:

```erlang
log_action(Action, Fields, {ok, term()} | {error, term()}) -> ok
```

Two defects, and they compound.

**Logs cannot answer the question the audit exists for.** "Who banned this
player six months ago" needs a query against something joinable to the
players table, on a retention schedule the deployment controls. Shipped logs
are neither.

**The outcome type cannot express partial failure**, and there is a live
instance. `asobi_admin_notifications_controller:broadcast/1` calls
`log_action(~"broadcast", #{recipient_count => length(SentTo)}, {ok, SentTo})`
where `SentTo` came from `do_broadcast/4` - a copy of
`asobi_notify:send_many/4`, which dropped every failed insert on the floor
and returned only the survivors. A broadcast that reached three of ten
players was audited as a success with a count of three. Nothing recorded the
seven.

There is exactly one such call site today. There will be more as the write
plane lands, and each one built against a binary outcome is a call site to
rewrite.

## Decision

**Three things, together: a row, a widened outcome, and core doing the
wrapping.**

### 1. `ops_audit_entries`, a row per mutation

Schema `asobi_ops_audit_entry`. The actor is four flattened columns -
`actor_id`, `actor_display`, `actor_source`, `actor_attested` - not a foreign
key. There is no actors table, and more importantly a row must keep saying
what it said at the time after the actor's capabilities change or its token
source is retired.

`actor_attested` is load-bearing. A `static_secret` actor named by the
`x-asobi-operator` header is self-declared and spoofable; the column is what
stops every stored name from implying a verification that never happened.

Indexes: `(actor_id, occurred_at)`, `(action, occurred_at)`, `(target_id)`.
One per question - what did this operator do, who has performed this action,
who has acted on this subject. No bare `occurred_at` index; both composites
already answer a bounded time range.

`target_id` carries no foreign key. A player deletion, GDPR erasure
included, must not cascade away the record that someone banned them.

Rows are append-only. Core never updates or deletes one, and ships no
reaper: retention is a jurisdiction-dependent operator policy, and the
leading `occurred_at` ordering makes a prune a single ranged delete.

### 2. `{ok, Succeeded, Failed}`

The outcome contract, adopted **before** the first bulk endpoint rather than
after. `Failed` entries carry their reason. A single-subject mutation is the
one-element case, not a second contract.

Stored as an `outcome` column of `ok`, `partial` or `error` plus two counts,
so "everything that did not fully succeed" is an index scan and not a jsonb
parse. A bulk call where every subject failed is `error`, not `partial`.

`asobi_notify:send_many/4` is widened to return it, which is where the
survivors-only shape originated.

### 3. Core wraps the mutation

`asobi_ops_audit:mutation/4` runs the operation and builds the row from the
operation's own return value. A call site cannot forget to audit, and cannot
hand the audit an outcome the operation did not produce - which is precisely
what the broadcast handler did.

A core-wrapped mutation has no route in front of it, so it performs the
capability check itself, through the same `asobi_ops_caps:authorised/2` the
router's security callback calls. One function still authorises; it is called
from whichever entry point the caller actually reaches. A refusal is audited
as an `error` outcome, because a denied attempt is worth a row.

**The audit never fails the operation.** It runs after the change has
happened, so refusing the response cannot undo a ban; it would only invite a
retry that applies the change twice. A write-ahead row could fail closed, but
it would record intent, and outcome is the thing being asked for. When the
insert fails - or raises - the row is emitted at error level with the same
field names, so the record degrades from queryable to greppable rather than
disappearing.

## Consequences

- **Attribution survives the request.** Every mutation is answerable months
  later, and the answer carries whether the name was attested.
- **The one existing lie is fixable in one call.**
  `asobi_ops_notifications:broadcast/5` is the core-wrapped entry point the
  console's mutation moves onto (widgrensit/asobi_admin#6). Until it does,
  the console keeps its own copy and keeps lying; core cannot fix that from
  here.
- **No ops write routes were added.** The plane stays read-only. This is the
  mechanism plus the one mutation that already existed, not a write surface.
- **An audit row is a new failure mode with a documented outcome.** A
  deployment whose database is degraded loses queryable audit rows and keeps
  error-level log lines. That is a stated trade, not a silent one.
- **`details` is diagnostic, not queryable.** Per-subject reasons are capped
  at 50 entries and 200 bytes each; the counts are the queryable surface.
  Anything a future consumer needs to filter on becomes a column.
