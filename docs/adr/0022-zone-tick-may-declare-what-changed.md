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
| 100 | 299 | 181 | 10,945 | 526 |
| 500 | 1,784 | 898 | 53,314 | 672 |
| 2,000 | 9,292 | 4,569 | 200,466 | 1,209 |

Median of three runs each; the wall-clock column moves by 10-20% between runs
on this machine and the reduction column does not, which is why both are here.

Under `copy` at 2,000 entities: 14.6ms to 8.8ms, and 778k reductions to 452k.
The reduction floor is higher there because the encode still runs on the zone
process rather than in the VM.

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
   of it - so the mutation is undone, not merely invisible.

   The first draft of this ADR called that "inherent to any dirty contract".
   **It is not, and the prior art cited below contradicts it.** AzerothCore's
   dirty flags govern *replication*: a missed flag means the client does not
   see the change, the server's state still holds it, and the next marked write
   carries it. Here a missed declaration REVERTS the mutation, because the
   consumer of the declaration also owns the base state and re-encodes it over
   the top. That is a strictly more destructive failure mode than the
   precedent.

   The honest claim is narrower: inherent to a dirty contract *where the base
   state is re-pushed by the consumer* - a design choice made in decision 2,
   not a law. And it has a consequence that decision 4 has to carry: because
   the failure is worse than the prior art's, the reporting has to be better
   than the prior art's, not equal.
4. **Fail towards merging, and say so every time.** A malformed declaration is
   narrowed - non-binary ids and non-map entities dropped, a non-map
   declaration ignored - and *every* way of being malformed emits
   `bad_zone_dirty` and a log line. Ignoring a declaration is always safe: it
   costs the sharing and nothing else. Refusing the tick would not be.

   Four ways of being malformed reported nothing in the first implementation,
   and the review of widgrensit/asobi#557 found all four. They are recorded
   because each one produces the same symptom - every entity in the zone stops
   moving, forever, with no error - and because three of them are one line away
   from an idiom the guide itself shows:

   - a typo'd key (`#{chnaged => ...}`) read as an empty declaration;
   - `changed` built as a Lua array (`changed[#changed + 1] = e`) was
     normalised to `#{}` in the bridge, *before* core could complain;
   - a table that declares neither half became a well-formed empty declaration,
     because `decode_to_map/2` coerces an array-shaped decode to `#{}`;
   - `narrow_ids/1` dropped bad ids silently while its sibling logged.

   What is logged is a **count and the first offending key clipped to 64
   bytes**, never the declaration. `changed` is script-controlled and
   arbitrarily large, and the module's bounded formatter renders its whole
   argument before truncating it - measured at ~10 seconds on the zone process
   for a 32MB script binary, outside `bounded_eval`'s wall clock and invisible
   to `max_heap_size` because a refc binary is. Three of those per limiter
   window is a zone that never ticks again, with no crash to attribute it to.
   The bound has to be on the way IN.
5. **Only a table reference is a declaration.** Luerl represents every
   non-scalar as a record, so `is_tuple/1` admits `#funref{}`, `#erl_func{}`,
   `#erl_mfa{}` and `#usdref{}` as well as `#tref{}` - and each of those raises
   out of the decode, on a callback `asobi_zone:do_tick/2` invokes with no
   try/catch. The tag is checked, and the decode is wrapped anyway because a
   `#tref{}` can be recursive.
6. **`sync_spatial_grid/3` deliberately does NOT test entity identity.**
   Matching the previous tick's term would settle an untouched entity in one
   pointer comparison where sharing holds - but where it does not, `=:=` on two
   maps is a structural walk *that can only fail*, and that is the common case:
   every game that does not declare, plus every Lua game on a tick carrying
   input. Two position lookups are O(1) whatever the entity holds.
   `compute_deltas/2` is where the sharing pays, and it already tested
   identity - it just never got a shared term to do it on.
7. An id in both `changed` and `removed` is removed: the merge happens first.

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
- **The downstream half of the win is cancelled by input.** `handle_input/3`
  and `handle_input_batch/2` encode the entity map and decode it back, so any
  tick carrying at least one input rebuilds every entity and destroys the
  sharing this preserved. The upstream half - not decoding the whole table in
  `zone_tick` - survives, and decision 2 says that is the bigger half. But the
  measurements in this ADR are taken with an inert script and no input, which
  excludes the workload that holds the most entities: a populated zone with
  players in it. Extending the declaration to `handle_input_batch/2` is where
  it composes; that is a follow-up, not this ADR.
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
