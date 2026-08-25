# ADR 0022: `zone_tick/2` may declare what changed

Date: 2026-08-25

## Status

**Accepted, and shipped.** Closes widgrensit/asobi#557. Additive and opt-in:
the two- and three-tuple returns keep today's semantics exactly, in both VM
modes, and no existing game changes behaviour.

Recorded because `zone_tick/2` is a public behaviour callback and this adds a
way for a game to make asobi believe something false about its own state. ADR
0000 names that class.

## Context

ADR 0015 removed the O(state) copy from every budgeted callback, and its own
measurements name what it did not remove:

> The win is much smaller when the per-tick work grows with the state - a zone
> holding 8,000 entities and encoding all of them every tick measured 1.4x,
> because there the encode is genuine work and the copy is a minority of it.
> `owned` removes a term that is O(state); it does not make encoding cheaper.

A populated zone paid O(all entities x fields) three times per tick to discover
a usually-small changed set:

- `asobi_lua_world:zone_tick/2` encoded every entity in and decoded and
  atomised every one of them back out, on a tick where the script moved one NPC
  or nothing at all.
- Because the decode rebuilt every entity map, structural sharing with the
  previous tick was destroyed, so `compute_deltas/2` deep-compared every field
  of every entity at each broadcast to find out that most had not changed.
- `sync_spatial_grid/3` walked all entities for the same reason: nothing told
  it which ones moved.

Measured here on one machine, a zone with an inert script that moves three
entities, under `owned`:

| entities | us/tick before | us/tick after | reductions in the zone before | after |
|---|---|---|---|---|
| 100 | 280 | 224 | 10,944 | 528 |
| 500 | 1,773 | 1,152 | 53,289 | 692 |
| 2,000 | 10,509 | 5,929 | 200,659 | 1,208 |

Under `copy` at 2,000 entities: 13.1ms to 9.4ms.

The reduction column is the one that matters for scheduling: the decode ran on
the zone `gen_server` itself, so a 2,000-entity zone spent 200k reductions per
tick marshalling before the game did anything.

## Decision

**A game may return a fourth value saying what it changed, and asobi merges it
onto the map it handed in.**

1. `{Entities, ZoneState, Busy, #{changed => #{Id => Entity}, removed => [Id]}}`.
   `Entities` is the base; `changed` is merged over it and `removed` deleted
   from it. Lua returns the same shape as a table.
2. **The bridge stops decoding.** When a Lua script declares, `asobi_lua_world`
   decodes only `changed` and passes the input map straight back as the base.
   That is where most of the win is, and it is also what makes the sharing
   real: the untouched entities are not merely equal, they are the same terms.
3. **The declaration is the truth.** An entity the script mutated and did not
   name is not changed, and the next tick re-encodes asobi's map over the top
   of it - so the mutation is undone, not merely invisible. This is inherent to
   any dirty contract and it is why this is opt-in per game rather than a mode.
4. **Fail towards merging.** A malformed declaration is narrowed - non-binary
   ids and non-map entities are dropped, a non-map declaration is ignored
   entirely - and logged through the bounded formatter with a
   `bad_zone_dirty` game error. Ignoring a declaration is always safe: it costs
   the sharing and nothing else. Refusing the tick would not be.
5. `sync_spatial_grid/3` matches the previous tick's entity term first, so an
   entity nobody touched costs one pointer comparison rather than two position
   extractions. `compute_deltas/2` already did this - it just never got a
   shared term to do it on.

## Consequences

- A Lua zone's marshalling cost stops scaling with resident entity count and
  starts scaling with activity. A zone of 500 NPCs of which 3 move pays for 3.
- **The encode IN is unchanged and still O(N).** Removing it needs the VM to
  hold the entities table across ticks and asobi to push only its own
  mutations, which means tracking dirtiness across `handle_input`,
  `handle_effects`, the timer wheel, the spawner, the crossing resolver and
  five entity-bearing casts. That is a separate decision with a real hazard - a
  missed mark is an entity that silently stops replicating - and it is not this
  one. The tables above are with the encode still in.
- Nothing in `asobi_zone` accumulates a dirty set across ticks, and no mutation
  site outside `zone_tick_result/2` has to know this exists. That is deliberate:
  it is what keeps the change unable to lose an entity.
- Declined: a `game.mark_dirty(id)` API. It would put the bridge's per-call
  cost on every marked entity and give a script a way to mark from outside
  `zone_tick`, where asobi has no base map to merge onto.
- Declined: making the declaration mandatory under `owned`. `owned` is a
  deployment choice about where the state lives; this is a contract about what
  the game promises. Coupling them would change a game's semantics when an
  operator flipped a flag.

## Prior art

Standard in C++ MMO emulators - AzerothCore's `UpdateData`, where objects
accumulate per-field dirty flags and replication packets are built from marked
blocks only. Nothing there scans full state to derive deltas.
