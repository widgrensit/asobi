# ADR 0021: `cold_tick_divisor = 0` stops ticking an idle zone entirely

Date: 2026-08-25

## Status

**Accepted, and shipped.** Extends
`docs/adr/0016-idle-zones-tick-at-the-cold-divisor.md`, whose decision 3 is
superseded by widgrensit/asobi#560 and whose decision 1 is amended by decision
4 below; both are recorded in that file's own "Amended by later work". Closes
widgrensit/asobi#561. **Off by default**: the divisor is still 10, and a world
has to ask for 0.

Recorded for the same reason ADR 0016 was: `zone_tick/2` is a public behaviour
callback, and this makes it stop firing for some zones rather than merely fire
less often. ADR 0000 names that as an observable-semantics change.

## Context

ADR 0016 removed 90% of the idle floor by ticking a zone with nothing to
simulate 1-in-10. The remaining 10% is not free:

- A cold tick is a full `do_tick` - the `zone_tick` bridge call with its
  encode/decode round trip, the crossing scan, reclassification.
- A zone that hibernates between cold ticks pays a full-sweep GC of the whole
  process on every hibernate/wake cycle. At divisor 10 and `tick_rate = 50`
  that is 2 Hz of whole-heap collection on a zone doing nothing.

The aggregate of "loaded but idle" scales with map size rather than with player
activity, so on a 2000x2000-capable lazy world where an operator keeps
`max_active_zones` high it is a per-world cost nobody asked for.

The correctness machinery for "safe to skip" already exists. `zone_idle/1` is
precise about what "nothing to simulate" means - no entities, no queued input,
no queued cross-zone effect, no live entity timer, no pending respawn - and ADR
0019 lets a script veto with `busy`.

## Decision

**`cold_tick_divisor = 0` means an idle zone is not ticked, and `warm_up/1` is
the only transition back.**

1. `asobi_world_ticker` folds a divisor of 0 - and any non-positive or
   non-integer value - into "never tick the cold set" (`tick_cold/2`). Hot
   zones are unaffected: this is not a world-wide off switch.
2. **Nothing has to be caught up on warm-up, and that is a property of
   `zone_idle/1` rather than an omission.** A zone is only demoted when its
   entity-timer wheel is empty and its respawn queue is empty, so a dormant
   zone holds no elapsed deadline. What it can acquire while dormant - a spawn,
   a timer, an entity, an input, an effect - arrives as a message, and every
   one of those messages already runs `warm_up/1`. `asobi_zone_spawner:tick/2`
   and `asobi_entity_timer:tick/2` are both driven by the `Now` the resumed
   tick passes them, so a window that opened during the silence fires on the
   first tick after warm-up rather than a divisor later.
3. A zone at divisor 0 never runs `reclassify/1`, so no demotion decision is
   lost: it demoted before it went silent, and message-driven promotion is the
   only transition left. That is ADR 0016's decision 2, load-bearing rather
   than an optimisation.
4. **A zone with subscribers declines `reap` and re-stamps itself.** Mostly a
   statement of emergent behaviour - an empty watched zone re-stamped itself on
   the `map_size(Subs) > 0` branch of every tick, so the reap cast never
   arrived - made necessary because a zone that stops ticking stops stamping.
   Without the guard, turning the knob on would tear a watched zone out from
   under subscribers who are not re-subscribed until they next move, and they
   would silently stop seeing anything that happens there.

   **It also closes a race that existed at every divisor.** `release_zone/2`
   backdates the stamp the moment a zone empties, and the sweep runs every
   `?REAP_INTERVAL`. A sweep landing between that backdate and the zone's next
   tick re-stamping it - a 20ms window when hot, 200ms when cold - fell through
   to the `map_size(Entities) =:= 0` clause and stopped a *watched* zone. Small,
   but real, and the same shape as the widgrensit/asobi#283 nightly flake. So
   this is not purely a restatement.
5. A `busy` zone is never idle, so a script driving wave logic from `zone_tick`
   keeps its full rate at 0 exactly as it does at 10 (ADR 0019).

## Consequences

- A world that turns this on pays nothing for a loaded-but-idle zone. The
  residual cost of a large lazy world scales with player activity rather than
  with map size.
- `zone_tick/2` can go arbitrarily long without firing for such a zone. A game
  that keeps state in `zone_state` and advances it from the tick must either
  return `busy` (ADR 0019) or not use this knob. The guides say so at both
  ends.
- The reap guard changes behaviour at every divisor, not only at 0. It makes an
  existing emergent behaviour explicit; no zone that used to be reaped is
  reaped less often, because a watched zone was never reachable by the sweep.
- A dormant zone does not run `maybe_apply_spawn_templates_hint/5`, so it does
  not pick up a hot-reloaded spawn template until it next warms. Self-corrects
  on the first warm tick, and hot reload is a stated differentiator, so it is
  worth knowing rather than a defect.
- **The escape hatch is all-or-nothing.** A script with zone-level time - a
  wave countdown, weather, a capture timer - must return `busy = true`
  continuously, which pins the zone at full rate. There is no "wake me in N
  ms". The missing primitive is a zone-level timer wheel, the zone equivalent
  of `asobi_entity_timer`, which `zone_idle/1` already consults. That is what
  would make this knob broadly safe, and it is a follow-up.
- Declined: making 0 the default. The failure mode of a game that quietly needs
  the cold tick is silent and slow to attribute, and there is no way for asobi
  to detect it. An operator turning a knob on a large lazy world has the
  context; a default does not.

## Prior art

Grid-based C++ emulators behave this way: a grid with no players near it gets
no object updates at all, and respawns come from a time-ordered queue consulted
at a coarse interval (AzerothCore's `ProcessRespawns`, every 5s) rather than
from ticking dormant creatures slowly.
