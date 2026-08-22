# ADR 0016: A zone with nothing to simulate ticks at `cold_tick_divisor`

Date: 2026-08-22

## Status

**Accepted, and shipped.** Landed in asobi#545, closing asobi#543. On by
default at a divisor of 10, which is the value `cold_tick_divisor` has
documented since it was written.

Recorded because it changes when a documented callback fires. `zone_tick/2` is
a public behaviour callback and this makes it run 1-in-N ticks for some zones,
which ADR 0000 names as "optimisations that change observable semantics".

## Context

A reporter measured an empty zone - zero entities, an inert `zone_tick`, no
client in it - at roughly 5,300 reductions per tick on a 225-zone grid at
`tick_rate = 80` (asobi#543). Reproduced here at ~2,200, of which ~90% is the
Lua bridge rather than anything the game asked for, and most of that is the
per-callback state copy ADR 0015 addresses. The floor is paid per zone, and a
world is the scaling unit, so it sets what one world can hold.

`cold_tick_divisor` was supposed to be the answer and did nothing. Three
independent breaks, none of which produced an error:

- `asobi_game_modes:world_config_1/2` forwarded a whitelist from the mode
  config to the world and `lazy_zones`, `zone_idle_timeout`,
  `max_active_zones`, `spatial_grid_cell_size`, `cold_tick_divisor` and
  `rehome_margin` were all absent from it. A world declaring
  `lazy_zones = true` pre-spawned its whole grid anyway.
- `asobi_world_instance` built the ticker's config without
  `cold_tick_divisor`, so the ticker read its own default.
- Nothing in `src/` ever called `asobi_world_ticker:promote_zone/2` or
  `demote_zone/2`, and `set_zones/3` - the only path that fills the static
  lists - has no caller either. No zone in any world was ever cold. Under a
  zone manager the tick handler also overwrote its own split with "every active
  zone is hot", which would have kept it inert for lazy worlds even once
  something did classify.

## Decision

**A zone classifies itself, and the ticker honours it.**

1. `asobi_zone:zone_idle/1` (`src/world/asobi_zone.erl:2535`) is true when the
   zone has no entities, no queued input, no queued cross-zone effect, no live
   entity timer and no pending respawn. **Subscribers deliberately do not
   count**: a player watching an empty neighbouring zone creates no work in it,
   and that is the "watched but empty" case asobi#543 asks about.
2. Demotion is decided on the tick, where the cost is (`reclassify/1`, `:2561`).
   **Promotion is not**: `warm_up/1` (`:2578`) fires on the message that creates
   the work - an input, an entity arriving, a spawn, a timer, an effect - so
   entering a zone costs no extra latency. Waiting for a cold zone's own next
   tick would put the whole divisor on the first frame of every zone entry.
3. The ticker partitions the zone manager's active list against its own cold set
   (`src/world/asobi_world_ticker.erl:182`), which also prunes reaped pids
   without needing a `remove_zone` cast to arrive.
4. Both transitions emit telemetry (`[asobi, zone, cold]` / `[asobi, zone, hot]`,
   `announce/2` at `asobi_zone.erl:2594`), on the transition rather than per
   tick.
5. The six dropped config keys are forwarded (`asobi_game_modes.erl:157-163`).

## Consequences

- An empty zone costs a tenth of what it did. On the reporter's grid that is the
  difference between a world spending most of a core on empty space and a tenth
  of it.
- **A script that drives spawning from `zone_tick` on a zone holding nothing now
  runs at a tenth of the rate.** `zone_idle/1` reads asobi's own bookkeeping and
  cannot see work a script keeps in `zone_state` - a wave spawner counting down,
  weather, a zone-level timer. The escape hatch is `cold_tick_divisor = 1`, and
  it is world-wide rather than per-zone. Both reviewers on asobi#545 asked for an
  optional `zone_busy/1` veto instead; that is a later decision, deliberately not
  taken here. **Taken since, in
  `docs/adr/0019-zone-tick-returns-whether-it-is-busy.md`** (via
  `docs/adr/0018-zone-busy-vetoes-demotion.md`, superseded). Note that 0019 does
  redefine `zone_idle/1`, which decision item 1 above names: what is described
  there is now `asobi_idle/1`, and `zone_idle/1` is that plus the game's own
  answer. The line references above are from before those changes.
- Fixing the forwarding turns on five other knobs that games have been declaring
  and not getting, `lazy_zones` most consequentially. A world that has been
  pre-spawning its whole grid will start loading zones on demand.
- A cold zone touches the zone manager 1-in-N ticks rather than every tick.
  `zone_idle_timeout` defaults to 30s against a worst case of ten ticks, so the
  reaper is unaffected.
- This does not make an *occupied* zone cheaper. Only ADR 0015 does.

## Alternatives considered

- **Leave `cold_tick_divisor` inert and document the floor.** Rejected: the knob
  is already documented as working, so the honest options were to delete it or
  make it true.
- **Count subscribers as work.** Rejected: it inverts the result. The reporter's
  zones are empty *and* watched, because `view_radius` keeps a ring loaded around
  every player, so counting subscribers would leave exactly the zones this is for
  running at full rate.
- **Promote on the zone's own next tick** rather than on the arriving message.
  Rejected: simpler, and it puts `cold_tick_divisor` ticks of latency on entering
  any zone - a regression a player feels, to save a cast.
- **Skip the Lua callback rather than the whole tick.** Rejected: the skip
  condition is asobi's (input queue, timers, spawner) and lives in `asobi_zone`,
  while the callback is the bridge's. Ticking at a divisor keeps one mechanism
  and leaves hot reload landing within N ticks rather than never.
