# ADR 0018: A game may veto its own zone's demotion

Date: 2026-08-22

## Status

**Accepted, and shipped.** Takes the decision
`docs/adr/0016-idle-zones-tick-at-the-cold-divisor.md` names as "a later
decision, deliberately not taken here". ADR 0016 stands: this closes the gap its
Consequences record, it does not reverse it.

Recorded because it adds an optional behaviour callback, which ADR 0000 names as
ADR-worthy.

## Context

ADR 0016 demotes a zone with no entities, no queued input, no live entity timer
and no pending respawn to `cold_tick_divisor`. That test reads asobi's own
bookkeeping, and asobi's bookkeeping cannot see work a script keeps in its zone
state: a wave spawner counting down between waves, weather, a zone-level phase
timer. Such a zone holds nothing by design, so it is demoted, and the countdown
then runs at a tenth of the rate it was written for - silently, because nothing
about it looks like a failure.

The escape hatch ADR 0016 shipped is `cold_tick_divisor = 1`, which turns the
feature off for the whole world to protect one zone shape. Both reviewers on
asobi#545 asked for something narrower.

The obvious answer - an optional `zone_busy/1` callback - has a cost problem
that is easy to miss. asobi consults it whenever it believes a zone is idle, and
for a zone that keeps answering "busy" that is **every tick**. On a Lua world a
callback is exactly the marshalled crossing asobi#543 is about, so the naive
shape puts one extra callback per tick on precisely the zones the feature exists
to make cheaper, in order to decide whether to skip a callback.

## Decision

**An optional `zone_busy/1` on the behaviour, consulted only after asobi's own
test has already said idle - and for Lua, a field rather than a callback.**

1. `asobi_zone:zone_idle/1` splits: `asobi_idle/1` is everything asobi can see
   for itself, and only if that is true is `script_busy/3` consulted. A zone
   holding entities never reaches the callback, so the common case pays nothing.
2. **Fail-safe is "keep the zone hot".** A raising or non-boolean answer is
   treated as `true` and logged rate-limited. Demoting a zone that has work is
   the harmful direction; the cost of erring the other way is one zone ticking
   at full rate.
3. **Lua scripts set `_keep_hot` on their zone state**, read with one
   `get_table_key`. It joins `_finished`, `_result` and `_vote` as fields a
   script sets to tell asobi something, and it costs a table read rather than a
   marshalled call - which is the whole reason the Lua half is not a function.
4. A script that never sets it demotes exactly as it did before ADR 0018, so
   this is additive.

## Consequences

- The zone shape ADR 0016 silently slowed can opt out without disabling the
  feature for every other zone in the world.
- One more magic field on the Lua side. `_keep_hot` is discoverable only from
  the guides, like the three that precede it - a real cost, and the reason the
  Erlang half is an ordinary declared callback.
- A zone that answers "busy" forever never demotes. That is the game's decision
  to make and asobi does not second-guess it, but it means a buggy veto is
  indistinguishable from a busy zone. The telemetry from ADR 0016 is what makes
  it visible: such a zone simply never emits `[asobi, zone, cold]`.
- The split in `zone_idle/1` fixes the order of evaluation as load-bearing
  rather than incidental. Consulting the script first would work and would cost
  a callback on every busy zone.

## Alternatives considered

- **`zone_busy/1` as a Lua callback too**, for symmetry with every other hook.
  Rejected on cost: one extra marshalled callback per idle tick, on the zones
  asobi#543 is about, to decide whether to skip a callback.
- **Infer it from `zone_state` changing between ticks.** Rejected: it makes any
  script that stamps a tick counter permanently busy, which is most of them, and
  the failure is invisible.
- **Leave it at `cold_tick_divisor = 1`.** Rejected: it protects one zone by
  turning the feature off for a whole grid, which is the trade ADR 0016 exists
  to avoid.
- **Demote anyway and let the script notice.** Rejected: a script cannot notice.
  It sees `zone_tick` called, with no indication that it is being called a tenth
  as often as it asked for.
