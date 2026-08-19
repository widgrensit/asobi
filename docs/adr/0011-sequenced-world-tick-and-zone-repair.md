# ADR 0011: Sequence `world.tick` per zone, and repair it with a keyframe

Date: 2026-08-16

## Status

**Accepted, and shipped.** Landed in asobi v0.89.0 (`world.tick`'s `zone`,
`frame_seq` and `kf`, plus inbound `world.resync`), and running on every managed
environment from engine v0.19.1 onward. The client half shipped across five SDKs;
see decision 8.

This ADR needed no ruling from ADR 0010. Every wire change below is a new field on
an existing framework-owned payload or a new inbound frame, both of which ADR
0010's compat policy already permits
(`docs/adr/0010-wire-protocol-frozen-at-1.0.md:86-88`). It is recorded because it
changes the meaning of a shipped frame and because ADR 0000 names "wire-format
additions to public APIs" as ADR-worthy.

The `match.state` sequence number that an earlier draft proposed was **cut before
implementation** and is not part of this decision: no reorder path exists for that
frame on the TCP wire today, and it was the only item that would have required a
new reading of the wire freeze. It is absent from the shipped code by design.

## Context

`world.tick` is an op-delta stream against a single zone-wide baseline.
`compute_deltas/2` returns `Updates ++ Removed` against `broadcast_entities`
(`src/world/asobi_zone.erl:721-748`, concatenation at `:748`), and `do_tick/2` advances
that baseline unconditionally on the same tick it sends
(`asobi_zone.erl:622-628`, send at `:626`). A frame that never reaches the client is
never re-sent and never reconstructed: a lost `op:"a"` leaves the client applying diffs
to an entity it has never heard of, and a lost `op:"r"` leaves a ghost for the life of
the session. Nothing on the wire lets either side notice.

The payload carries no zone identifier. It is exactly
`#{~"tick" => TickN, ~"updates" => EncodedDeltas}` (`asobi_zone.erl:752-757`), relayed
verbatim (`src/ws/asobi_ws_handler.erl:299-300`), while a session is subscribed to a
whole interest ring at once - `subscribe_interest_zones/4`
(`src/world/asobi_world_server.erl:1343-1358`) subscribes one session pid to
`asobi_zone_grid:ring/3` (`src/world/asobi_zone_grid.erl:24-29`), nine zones at the
default `?DEFAULT_VIEW_RADIUS` 1 (`asobi_world_server.erl:42`). This is a defect today,
not only a gap in a future design: `send_leave_removals/2` sends `op:"r"` for every
entity of the zone being left (`asobi_zone.erl:558-564`), and a client holding one flat
entity table cannot distinguish those from removals in a zone it is still watching.

Three senders already produce a frame the client sees as `world.tick`, and only one of
them is shared:

1. the shared delta broadcast, one `json:encode/1` at `asobi_zone.erl:757` fanned to
   every subscriber at `:760`;
2. the join snapshot, `subscribe_new/3` (`:528-555`), to one pid at `:541`;
3. the leave removals, `send_leave_removals/2` (`:558-564`), to one pid at `:563`,
   reachable only from the `unsubscribe` cast at `:449`.

A counter stamped naively on 2 or 3 either opens a phantom gap for every other
subscriber (if it advances) or restates a value another subscriber has already seen with
different contents (if it does not). The two per-connection senders also read the wrong
map: both build from `entities` (`:531`, `:540`, and the `unsubscribe` cast's
`entities` at `:441-451`) while the next shared delta is computed against
`broadcast_entities` (`:625`). That skew is unobservable today only because a joining
client has no prior baseline to be ahead of.

Clients cannot currently detect any of this. `world.ack` and the optional inbound `seq`
on `world.input` shipped after the 1.0 freeze (`asobi_ws_handler.erl:304-307`, `:939-943`,
`asobi_zone.erl:771-783`), and a cross-repo grep for `world.ack` outside vendored fixture
directories hits `asobi-defold` only.

## Decision

Add three fields to `world.tick`'s payload, one inbound frame, and a stated rule for
which sender stamps what. No rename, no payload-shape change, no RPC protocol bump.

**1. `world.tick`'s payload gains `zone`, `frame_seq` and `kf`.**

| Field | Type | Meaning |
|---|---|---|
| `zone` | `[X, Y]`, integers `0 .. grid_size - 1` | The emitting zone's coords, already in that zone's state. Without it nothing can be keyed per zone. |
| `frame_seq` | integer, `0 .. 2^53-1` | Counts `world.tick` frames **actually sent on that zone's shared broadcast path**. Dense, so a gap is unambiguous. |
| `kf` | boolean | `true` on a keyframe: a self-contained full-state frame whose `updates` are all `op:"a"`, possibly empty. |

`tick` keeps its existing meaning and is documented for the first time: the world-wide
`TickN` cast by `asobi_world_ticker:tick_zones/2`, the ordering authority across zones.
It is not a loss detector - `broadcast_deltas/3` returns early on an empty delta list
(`asobi_zone.erl:750-751`) while the caller advances the baseline regardless, so `tick`
is a sparse, gappy subsequence per zone. Ordering authority and loss metric are two
fields, deliberately.

`frame_seq`, not `seq`: `world.ack` already ships `seq` on a `world.*` payload meaning
the client's own input counter, emitted one line after the broadcast in the same tick
step (`asobi_zone.erl:626-627`), so both frames reach one SDK handler at the same
instant. Measured cost of the longer name is 6 bytes per frame.

53-bit, and no wrap rule anywhere. At the shipped defaults (`tick_rate` 50 ms,
`asobi_world_server.erl:40`; `broadcast_interval` 3, `:617` and `asobi_zone.erl:212`) a
zone emits at most 6.67 frames/s, so a uint16 wraps in 2 h 44 min - and at
`broadcast_interval` 1, in 54.6 min. Two or three extra digits remove a class of silent
fleet-wide stall and remove any need for seven hand-written decoders to implement window
arithmetic correctly.

**2. Only the shared broadcast path advances `frame_seq`.**

Zone state gains `frame_seq :: non_neg_integer()`, init 0, meaning "the `frame_seq` of
the last shared frame this zone process has sent; 0 means none yet".

- **Shared frame:** stamp `FrameSeq + 1`, `kf => false`, store it. Dense from 1; no
  shared frame ever carries 0.
- **Keyframe** (join snapshot, resync response): stamp the last shared value, `kf => true`,
  and do **not** advance. The client sets `expected := frame_seq + 1`, which is exactly
  the next shared frame. Restating a value is unambiguous because `kf` bypasses the
  comparison entirely.
- **Leave frame:** stamp `zone` only. No `frame_seq`, no `kf`.

One private helper in `asobi_zone` builds that map and is the only place the rule lives.
No call site assembles it itself.

**3. Every per-connection frame is built from `broadcast_entities`, never from
`entities`.** Anchoring a keyframe to the shared counter is sound only if its body is the
shared baseline. Immediately after `asobi_zone.erl:622-628` the two maps are identical,
so the keyframe is exactly "the state as of `frame_seq`". This also fixes the pre-existing
skew above and the permanent ghost on the leave path.

**One line follows from that and must not be missed:** `asobi_zone` init sets
`entities => RecoveredEntities` at `:209` and `broadcast_entities => #{}` at `:211`, and
`:628` is the only writer. On the crash-recovery path a joiner arriving before the zone's
first broadcast tick would otherwise receive a keyframe with `updates: []` and, by rule 7
below, be told to empty its table. `broadcast_entities` is initialised to
`RecoveredEntities` as well.

**4. The join-side empty-zone short circuit is deleted; the leave-side one is kept.**
`subscribe_new/3`'s `case map_size(Entities) of 0 -> ok` (`:536-538`) makes a join to an
entity-less zone send nothing at all, which breaks the invariant the client's state
machine rests on. It goes; an empty zone announces an empty keyframe, measured at 92
bytes. Its mirror in `send_leave_removals/2` (`:559-560`) **stays**. The two are not
symmetric: an empty keyframe resets a client table, whereas an empty leave frame carries
no ops and announces nothing, and deleting the clause would emit a zero-content frame on
every crossing out of every empty zone in a nine-zone ring.

**5. New inbound frame `world.resync`, one zone per request.**

```json
{"type":"world.resync","payload":{
  "world_id":"0198f3aa-1b2c-7d3e-8f90-a1b2c3d4e5f6","zone":[0,0],"reason":"gap","gap":3}}
```

`reason` is one of `gap` / `decode_error` / `stale`; `gap` is the observed `frame_seq`
delta, which is the loss number nobody currently has. The requested zone must be a member
of the caller's own recorded interest set (`asobi_world_server.erl:922-926`), so a client
cannot resync a zone it never subscribed to, and the response goes only to the requesting
connection. It must **not** call `interest_zones/3` (`asobi_world_server.erl:1303-1306`):
fanning one request over the ring is what made the amplification four figures.

The response adds nothing outbound. It is the same keyframe the join path already
sends, emitted as a `world.tick` with all-`a` ops and `kf: true`. Every SDK handles that
frame today. No outbound fixture type is added, so `?FROZEN_WIRE_1_0` is untouched; a new
inbound frame is not frozen yet.

**Internal message shapes, as implemented.** Serving that keyframe from two places made
the old single `{zone_delta, TickN, Deltas}` tuple ambiguous, because the three senders of
a `world.tick` now need different metadata. It was split by carrier:

* `{zone_delta_raw, PreEncoded}` - the shared steady-state broadcast, pre-encoded once per
  zone per tick (ADR 0001). Carries `zone`, `frame_seq` and `kf: false`.
* `{zone_keyframe, Meta, Deltas}` - a per-connection baseline, from a join or a resync.
  Carries the zone's current `frame_seq` and `kf: true`, and never advances the counter.
* `{zone_removals, Coords, Deltas}` - the leave mirror. Carries `zone` so the client knows
  which table to empty, and deliberately no `frame_seq`, because it is not a position in
  the zone's stream and is applied ungated.

This is an internal contract, not the wire, so ADR 0010 does not govern it. It is recorded
because `asobi_presence:message/0` is a public exported type: it loses `{zone_delta, _, _}`
and gains the two above. A consumer matching on the old shape stops matching, which is a
compile-visible break for an Erlang consumer rather than a silent one for a game client.

**6. Two seki limiter keys, no supervision change.**

```erlang
resync => #{algorithm => sliding_window, limit => 12, window => 10_000},
resync_global => #{algorithm => sliding_window, limit => 150, window => 1000}
```

Per player on `player_id`, then global on a constant - the codebase's own doctrine, stated
verbatim at `src/asobi_sup.erl:265-268` and `:271-272`. asobi's limiters are not
supervision children: they are keys in one `Defaults` map inside a single `temporary`
child (`asobi_sup.erl:217-222`, `:241-300`, `:315`, `:322-333`), twelve groups today. This
is two map keys, two `limiter_name/1` clauses, and one plain module in the shape of
`src/asobi_rehome_limiter.erl` (63 lines, two-tier check at `:35-45`). Denial answers the
frozen `error` frame with code `rate_limited` and emits a telemetry counter; it is never a
silent drop.

12 per 10 s is derived from the legitimate worst case - a client that loses a whole
nine-zone ring on a mobile suspend and needs one retry's headroom on top. It is 4.2x
tighter per second than `rehome`, which already allows 5 full zone snapshots per second
per player for the identical work (`asobi_sup.erl:281-292`). 150 per 1000 ms is derived
from a 20 TB/month per-node egress allowance: 7.72 MB/s divided by a 50 561 B keyframe at
the pathological 400 entities/zone is 152.6 requests/s.

**7. The client contract, stated on the wire's side so seven SDKs implement one rule.**

Per subscribed zone, keyed by `zone`, the client keeps `{entity_table, expected_seq,
state}`, `state` being `live` or `resyncing`, and **renders the union of the zone tables
keyed by entity id**. The union rule is load-bearing: each zone is an independent process
sending from its own process, so a handoff emits `op:"r"` from the old zone and `op:"a"`
from the new one with no ordering relation between them; with one flat table the
`r`-after-`a` order deletes a live entity permanently.

- `op:"a"` and `op:"r"` **always apply**, never gated by any sequence guard. An unknown
  id on `r` is a no-op, not an error.
- `op:"u"` is gated. A `u` for an id absent from that zone's table is not applied, never
  creates a partial entity, and triggers the same repair as a gap.
- `kf: true` **replaces** the zone table wholesale, in **every** state including
  `resyncing`, and sets `expected := frame_seq + 1`. An empty `updates` list is
  meaningful. This is what survives a zone restart: a restarted zone restarts `frame_seq`
  while its `zone` identity is unchanged, so under any comparing rule its frames would be
  dropped for the life of the session.
- A frame with **no `frame_seq`** applies its ops and leaves `expected_seq` untouched, in
  **every** state including `resyncing`. The only such frame is the leave frame, and it is
  the one frame that empties a departed zone's table; dropping it while resyncing would
  strand exactly the entities that can never be corrected, since no keyframe is coming for
  a zone the client no longer subscribes to. When its ops empty the table, the zone entry
  is dropped and any outstanding resync for that zone is cancelled.
- `live, frame_seq > expected` -> gap: apply nothing, send `world.resync`, enter
  `resyncing`. `live, frame_seq < expected` -> stale or duplicate, drop.
- **One** retry per zone with backoff. A `rate_limited` error moves that zone straight to
  leave-and-rejoin rather than re-requesting.

**8. The reconciler ships detector-only.** Gap detection, the `world.resync` send site,
`kf` reset and per-zone `expected_seq`; the entity table stays where it already is in
userland. Only `asobi-love2d` (`asobi/realtime.lua:141-174`) and `asobi-defold`
(`asobi/realtime.lua:493-533`) apply `a`/`u`/`r` into a client entity table at all; of
the other five, two forward the payload untouched and three narrow it into a typed model
without an entity map, and one of the five has no world-mode WebSocket surface to hang it
on. Making the per-zone table SDK surface in five repositories is a different and larger
piece of work.

**DECIDED 2026-08-17: zone-keyed application plus gap detection. NOT detector-only.**

An earlier draft of this paragraph recorded "detector-only" with the reasoning that a
client keying `expected_seq` per zone is protected from the cross-zone inversion whether or
not asobi owns its entity table. **That reasoning was wrong and the decision is corrected
here.** A gap detector cannot see this bug: each zone's `frame_seq` is contiguous, so an
inverted `op:"r"` from the zone being left and `op:"a"` from the zone being entered arrive
with no gap in either sequence. Detection catches loss and reorder WITHIN a zone. It does
nothing for the defect this ADR exists to fix, which is two zones disagreeing about one
entity id in a client's single flat table.

So the scope splits by what an SDK already owns, rather than by how much new surface we are
willing to add:

* **The two SDKs that own an entity table** - `asobi-love2d` (`asobi/realtime.lua:141-174`)
  and `asobi-defold` (`asobi/realtime.lua:493-533`) - must apply ops per zone. Their table
  is the bug: `asobi-defold`'s `self.entities` is flat and is reset only on `world.joined`
  and `world.left` (`realtime.lua:672-674`), never on a zone crossing, which is exactly
  when the inversion happens. Leaving these two detector-only means knowingly shipping the
  corruption in the SDKs best placed to fix it.
* **The five that forward the payload** need no new table. `zone` is now in the payload they
  already hand to userland, so a game can key on it. That is where the choice belongs for
  an SDK that never owned the state.
* **Gap detection and the `world.resync` send site go everywhere**, on both paths. It is
  cheap and it covers the different failure - loss within one zone - that the zone keying
  does not.

This costs materially less than the ~12 person-days the full-table option was priced at,
because it adds no entity table where none exists, and unlike detector-only it actually
delivers the fix. Option (C), a per-zone entity table as new SDK surface in all seven,
stays unfunded; revisit per SDK on evidence that a game wants asobi to own its state.

## Consequences

- **Measured byte cost** (escript over `compute_deltas/2` and `encode_deltas/1` extracted
  verbatim from `asobi_zone.erl`, OTP 29 / ERTS 17.0.2; entity model is 6 fields and a
  36-character hyphenated UUID id): the three fields add **41 bytes** to a one-entity
  frame, 115 -> 156 B, constant per frame rather than per entity. At the shipped defaults
  that is at most 273 B/s per subscriber per zone, about 2.5 kB/s across a nine-zone ring.
  The empty keyframe is 92 B at `tick: 0` / `frame_seq: 0`, 98 B with two four-digit
  values.
- **A keyframe is not a cheap repair.** Measured at 400 entities/zone: keyframe 50 561 B
  (50 564 B with a four-digit anchor), today's join snapshot 50 524 B, one 10%-churn delta
  about 4 266 B. So resync is *equal* to the full re-join it replaces and about **12x more
  expensive than the deltas it repairs**; what it actually saves is the socket teardown,
  the TLS handshake, the re-auth and the reconnect grace window. That is why the retry
  backs off and why `rate_limited` falls straight through to rejoin. Delta byte figures
  move a few bytes run to run with the generated float widths; the keyframe and request
  figures are deterministic.
- **Amplification is 418x** at 400 entities/zone against a measured 121-byte request, down
  from 2 646x for the withdrawn ring-shaped form (455 076 B against a 172 B request, same
  measurement). Every figure here scales linearly with entities per zone, which is
  game-authored and unmeasured. If shipped zones run far past 400 entities the
  `resync_global` derivation breaks and the escalation is `seki:check/3`'s cost argument,
  not a smaller count.
- **The global limiter is a per-node bound.** It is derived from one node's egress
  allowance and enforced by a limiter registered per BEAM node
  (`asobi_sup.erl:217-222`, `:315`). An operator packing several asobi nodes behind one
  allowance must divide the limit by the packing density; the default assumes one node per
  allowance.
- **A joiner sees state up to `broadcast_interval - 1` ticks old**, 100 ms at the shipped
  default, because the keyframe reads the shared baseline rather than the live map. Anything
  that changed in that window arrives in the next shared frame regardless.
- **`broadcast_interval` is game-authored, not an operator knob.** It is read from the
  game's own `config.lua` globals (`src/lua/asobi_lua_config.erl:323`), forwarded through
  `src/asobi_game_modes.erl:143` and defaulted at `asobi_world_server.erl:617`. Every
  per-player fraction quoted for the limiter therefore depends on a value the tenant sets.
- **The keyframe invariant is "every subscribe that installs a new subscriber entry sends
  exactly one keyframe", not "every subscribe".** Re-affirming a subscription that already
  holds for the same pid returns without sending anything (`asobi_zone.erl:419-435`), which
  is the common path on every crossing. That is correct - the client's zone entry is still
  live - but the invariant must be written the narrow way.
- **A client may hold an empty zone entry after leaving an empty zone**, because decision 4
  keeps the leave-side short circuit. It renders nothing, is bounded by `grid_size^2` per
  world, is cleared on `world.leave`, and is reset by the keyframe on any re-subscribe.
- **ADR 0001 is untouched.** The three fields are stamped inside the one shared
  `json:encode/1` per zone per broadcast tick (`asobi_zone.erl:757`). `match.state` is not
  touched at all, so `broadcast_shared_state/3`'s single `get_state/1`, single encode and
  single pre-encoded fan-out are literally unchanged
  (`src/matches/asobi_match_server.erl:850-859`). The resync keyframe is a second trigger
  for the per-connection encode path the join snapshot already uses, not a sixth path, and
  no per-client baseline is introduced anywhere.
- **ADR 0010 is untouched and needs no new interpretation.** No RPC protocol bump, no N/N-1
  window, no rename, no `?RESERVED_EVENT_NAMES` addition. The `match.`/`world.` leaf
  carve-out fires only on *outbound* frame types; `world.resync` is inbound and the handler
  already records that inbound additions carry no such hazard
  (`asobi_ws_handler.erl:650-654`). The phrase "unconditionally safe" is deliberately not
  used: ADR 0010 reserves it for the `session` / `presence` / `module` / `rpc` namespaces.
- **The fixture pass is larger than one file.** `priv/protocol/fixtures/world.tick.json`
  gains the three fields, a keyframe fixture is added beside it, and
  `scripts/protocol-sync.sh` propagates to all seven vendored corpora - which are already
  adrift: six of the seven are 4 or 5 files behind, and only `asobi-defold` is in sync.
- **Telemetry is additive and must be sampled.** New `[asobi, wire, *]` events are a minor
  bump under ADR 0005 (`docs/adr/0005-telemetry-event-surface.md:252-256`), but any event
  emitted per zone per broadcast tick is hotter than the world-tick event
  `asobi_telemetry` already calls "too hot for a raw sink" and samples
  (`src/asobi_telemetry.erl:170-181`), and that same doc-block states that an unbounded id
  is never a metric label. Zone coordinates and `world_id` in metadata inherit that rule.
- **This does not fix the zone supervisor hole.** `asobi_zone_sup` is `simple_one_for_one`
  with `restart => transient` (`src/world/asobi_zone_sup.erl:17-26`), so a zone that exits
  abnormally is respawned with the same coords, never re-registers with
  `asobi_zone_manager`, and starts with no subscribers. Recovery in practice comes from the
  manager recreating the coords, which delivers a keyframe by the rules above. The
  respawned-and-invisible process is a separate ticket and must not be claimed as fixed
  here.
- **A zone that simply stops sending is still undetectable.** A gap is only observable on
  the *next* frame, and silence is also the normal state of an idle zone. Whether a
  periodic keyframe is worth its bytes is a measurement question, not decided here.

## Alternatives considered

- **Reuse `seq` instead of adding `frame_seq`.** Rejected: `world.ack` already ships `seq`
  on a `world.*` payload with different semantics, arriving at the same SDK handler in the
  same tick step. Six bytes is cheap insurance against a name collision across seven
  hand-written decoders.
- **Overload `tick` as the loss counter.** Rejected: `tick` is world-wide and skips
  whenever a zone's delta list is empty, so it is a sparse subsequence per zone and cannot
  carry a dense gap detector.
- **A `zones` array on `world.resync`.** Rejected: `frame_seq` is per zone and the client
  keys `expected_seq` per zone, so it already knows which zone gapped; a ring-wide request
  rebuilds eight zones that lost nothing. Measured, the ring form is a 2 646x amplifier at
  400 entities/zone against a 172 B request.
- **A 16-bit `frame_seq` with window arithmetic.** Rejected: it wraps in under three hours
  at the shipped default, and the obvious "never accept a lower value" rule then drops every
  subsequent frame forever, fleet-wide and silently.
- **Per-client baselines** (Quake 3 / Source style). Rejected: a reversal of ADR 0001
  rather than a tuning of it, and the prior art withdrew it on CPU and bandwidth grounds.
- **Sequencing `match.state`, either inside its payload or as an envelope sibling.**
  Rejected. The payload ships `Mod:get_state/1`'s return verbatim
  (`asobi_match_server.erl:850-859`), so an injected key shadows a shipped game's own key;
  and there is no reorder path to detect on today's wire - the match server is one process,
  per-sender delivery is ordered, and `asobi_match_server:reconnect/2` (`:120-122`, exported
  at `:35`) has no caller anywhere in `src/`. If a lossy carrier is ever built, this reopens
  there, where a reorder path would exist for the first time.
- **A new outbound `world.<leaf>` frame type for the keyframe.** Rejected: ADR 0010's
  carve-out makes it a break, because it forces the leaf into `?RESERVED_EVENT_NAMES`
  (`asobi_ws_handler.erl:64-81`, enforced at `:1255`) and retroactively bans a shipped
  game's own `game.broadcast` of that name. `kf` on the existing frame costs nothing.
