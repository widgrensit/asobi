# ADR 0017: Zones publish an edge band, and address effects at its owner

Date: 2026-08-22

## Status

**Accepted, and shipped.** Landed in asobi#545, closing asobi#544. **Off by
default** (`border_band = 0`).

Recorded because it adds a behaviour callback (`handle_effects/2`) and two
`game.*` namespaces' worth of surface, both of which ADR 0000 names as
ADR-worthy.

## Context

`game.spatial.query_radius/rect` search the calling zone's own entity map and
nothing else. Combined with the rehome margin - an entity may sit up to
`rehome_margin * zone_size` outside the rectangle of the zone that still owns it
- an area geometrically inside zone A can be occupied by an entity zone B owns,
and a query from A misses it. `guides/world-server.md` has documented this since
the margin shipped.

The gap is not transient. A reporter running a space shooter (asobi#544) hit
both halves: a hostile parks on the line and never chases, because
`nearest_player` cannot see a pilot two units past the seam; and a player
shooting across a boundary sees their client predict damage the server never
applies, because the projectile is resolved in the shooter's zone and the target
belongs to the neighbour. The second reads to players as a bug and took them a
while to trace to the zone model rather than to their own hit tests.

They built the read half themselves - each zone publishing its pilots' positions
into a small ETS table on the occupancy cadence, neighbours reading the eight
touching entries. It works, it duplicates data the engine already holds, it
answers only "where are the players", and it does nothing for damage. Every game
that puts an NPC near a boundary writes some version of it.

Zone size is also a CPU knob, and the two constraints pull against each other:
smaller zones are cheaper per tick and worse for anything near an edge.

## Decision

**Each zone publishes the entities inside `border_band` of its own edges into a
per-world mirror. Neighbours read copies. To act on one, address its owner.**

1. `asobi_zone_border` holds one ETS table per world. Each zone writes its band
   once per tick, after crossings resolve (`asobi_zone:publish_border/1`,
   `src/world/asobi_zone.erl:2444`), and skips the write when the band is empty
   and no row exists - which is most zones most of the time.
2. `game.spatial.neighbours_radius/rect` read the eight touching zones and never
   the caller's own, which it already holds. What comes back is a **copy**;
   ownership never moves.
3. `game.zone.apply(entity_id, event)` resolves the owner out of the mirror and
   casts to that zone, which applies it in its own tick through a new optional
   `handle_effects/2` (`src/world/asobi_world.erl:196`), batched, after inputs,
   already filtered to entities the zone still owns.
4. **The band, not whole neighbour maps.** It is bounded by the zone's perimeter
   rather than its area, and it is exactly the set the guide names as invisible.
5. **Off by default.** Publishing costs a filter plus a copy of the band every
   tick whether or not anything reads it: measured 10,998 reductions/tick against
   8,231 with it off, on a zone holding 200 entities all inside the band.
6. **The table is owned by the world's instance supervisor**
   (`src/world/asobi_world_instance.erl:43`), so it dies exactly when the world
   does. No asobi process traps exits except where it must, so cleanup hung off a
   `terminate/2` would strand a grid of rows on every teardown.

## Consequences

- An NPC can chase across a seam and a shot can land across one, without a game
  reimplementing either.
- `zone_size` becomes a CPU knob again rather than a trade against correctness at
  the edges.
- **"What I may affect" is "what I can see"**, because both read the same rows.
  The sender-side check is a convenience gate: the mirror is a public table, so
  anything in the BEAM can write a row and authorise itself to address an entity.
  The check that cannot be forged is the receiver's - a zone applies an effect
  only to an entity it currently owns - so a forged row buys the ability to
  address an entity, never to invent one.
- Effects are bounded on the sender (4 KB per event, 64 sends per tick,
  `src/lua/asobi_lua_api.erl:1253-1254`) and on the receiver (256 entries, 1 MB,
  `asobi_zone.erl:57-58`). The sender-side bound is the load-bearing one: past it
  the term is already on another process's heap and in its mailbox, and
  `handle_input` - the one callback with no wall-clock, heap or reduction budget -
  can call `apply` in a loop.
- A reader can see an entity under two owners for at most one tick, because the
  old owner's row is refreshed on its own next tick. The receiver's ownership
  filter is what makes that harmless.
- One more thing a game can get wrong: a `handle_effects` that raises on a `nil`
  field drops the whole tick's batch, not one effect.

## Alternatives considered

- **A neighbour-aware query over whole neighbouring entity maps** (the
  reporter's first preference). Rejected: cost scales with area rather than
  perimeter, and it is paid every tick whether or not anything reads it.
  Widening the band later is a config change; narrowing it once games depend on
  it is not.
- **Visibility only, no effect path.** Rejected: it closes the chase case and
  leaves the damage case exactly where it was. Without it a game either forbids
  cross-boundary interaction or reimplements ownership.
- **Let a zone write a neighbour's entity directly.** Rejected: single-writer
  ownership is what makes the zone model work at all, and a second writer
  reintroduces every race the model exists to avoid.
- **Synchronous fan-out to eight zones per query.** Rejected: a `gen_server:call`
  from a callback into a neighbour mid-tick is a deadlock hazard and serialises
  the grid; the reporter explicitly did not ask for it.
- **One global table keyed by `{WorldId, Coords}`.** Rejected after review: it
  makes teardown a sweep that must be remembered rather than a lifetime that
  cannot be forgotten, and it leaves cross-world isolation resting on a key
  convention instead of on there being no shared table at all.
- **On by default.** Rejected on the measurement above: a third more per tick on
  an occupied zone, to serve a query most games never make.
