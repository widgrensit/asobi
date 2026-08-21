# ADR 0005: Telemetry event surface is a locked public contract

Date: 2026-08-01

## Status

Accepted.

## Context

`asobi_telemetry` (`src/asobi_telemetry.erl`) has emitted `m:telemetry` events
since before this ADR existed. Three independent consumers already attach to
it: the in-repo debug logger (`asobi_telemetry:setup/0`), the
`opentelemetry_asobi` span exporter, and `asobi_engine_metrics` (which pushes
a subset to the SaaS control plane). A community proposal for a Prometheus
exporter (`asobi_metrics`, modelled on `Taure/shigoto_metrics` and
`Taure/gakudan_metrics`) surfaced that this event surface was never written
down: names, measurement keys, and metadata keys existed only as the
implementation, with no stability guarantee and no guidance on which metadata
fields are safe to use as a metric label versus which carry unbounded,
per-entity identifiers.

A companion metrics package amplifies both problems at once. Prometheus
label sets are a second, harder-to-change contract stacked on top of event
names - reshaping either after a dashboard or alert rule pins against it is
disruptive. And a label built from an unbounded field (a `player_id`, a
`match_id`) is a cardinality DoS on the exporter and the scraping Prometheus,
not just an inconvenience.

Recording the surface now, exactly as it exists, is the prerequisite for
building an exporter safely - not a step to defer until after one is built.

## Decision

`asobi` core depends on `telemetry` (already an `applications` entry in
`asobi.app.src`) and emits the events below via `asobi_telemetry`.

### Conventions

- All events use `telemetry:execute/3`, never `telemetry:span/3`. Every
  event's measurements include `count => 1`; duration-bearing events add
  `duration_ms` (wall-clock milliseconds) as an integer.
- **Label-safe metadata** - bounded enums, either fixed by asobi core or
  validated at the edge before they reach an emitter. Safe to use as a
  Prometheus label. This is a per-key, per-event classification, not a
  blanket claim on a key name:
  - `mode` (`match/started`, `world/started`, `matchmaker/*`). Bounded
    because every shipped entry point rejects an unknown mode before it can
    be queued, via `asobi_matchmaker:known_mode/1`
    (`asobi_ws_handler:handle_message/2`, `asobi_matchmaker_controller:add/1`
    - referenced by function, not line, so the citation cannot rot), which
    caps it at 64 bytes and requires it to resolve to a configured game
    module. The gate is at those ingresses rather than in
    `asobi_matchmaker:add/2` itself, so this bound is a property of the
    shipped edges, not of the API: an embedder writing its own controller
    over `add/2` must call `known_mode/1` or it re-opens the cardinality
    hole for every `matchmaker/*` event.
  - `reason` on `matchmaker/removed` - an `atom()` chosen by core
    (`cancelled | expired`).
  - `type` on `anticheat/violation` - an `atom()` chosen by core, never
    derived from client input. This does **not** extend to the `ws` `type`,
    which is a different key on a different event; see below.
  - `kind` on `auth_cache/hit` and `auth_cache/miss` - `positive | negative`.
  - `kind` on `error` - the fixed `asobi_telemetry:game_error_kind()`
    literal type.
- **Game-author-controlled metadata** - `from_phase` and `to_phase` (world
  phases), `method` (vote), `currency` and `reason` (economy), `item_id`
  (store). Free-form binaries with no core-side allowlist: bounded in
  practice by the game's own config and catalogue, but their size is
  controlled by the game author, not asobi. A consumer must not assume they
  stay small - use one as a label only behind an explicit per-deployment
  cardinality cap.
- **Unbounded metadata** - per-entity identifiers, client-controlled values,
  or free-form data: `match_id`, `world_id`, `player_id`, `sender_id`,
  `vote_id`, `peer_ip`, `channel_id`, `coords`, `details`, `result`, and `type` on
  `ws/message_in` and `ws/message_out`. **Never** route these into a metric
  label. They stay on the raw event for tracing/audit sinks (e.g.
  `opentelemetry_asobi` spans) that can afford per-entity cardinality.

### Events

#### Match - `[asobi, match, started | finished | player_joined | player_left]`

- `started`: metadata `#{match_id, mode}`
- `finished`: measurements add `duration_ms`; metadata `#{match_id, result :: map()}`
- `player_joined` / `player_left`: metadata `#{match_id, player_id}`

#### World - `[asobi, world, started | finished | player_joined | player_left | phase_changed | tick]`

- `started`: metadata `#{world_id, mode}`
- `finished`: measurements add `duration_ms`; metadata `#{world_id, result :: map()}`
- `player_joined` / `player_left`: metadata `#{world_id, player_id}`
- `phase_changed`: metadata `#{world_id, from_phase, to_phase}`
- `tick`: measurements `#{duration_ms, max_duration_ms, zone_count, count}`;
  metadata `#{world_id}`. A world tick is the fan-out from
  `asobi_world_ticker` to every zone plus the fan-in of their `tick_done`
  replies, so `duration_ms` is the saturation signal that degrades first
  under entity load. **Sampled, not per tick**: at the default 50 ms tick
  rate a raw per-tick event is 20/s per world, so the ticker emits roughly
  once a second (`tick_sample_interval_ms`, default 1000, divided by the
  tick rate) and carries `max_duration_ms` - the worst tick in the sampled
  window - alongside the sampled tick's own `duration_ms`. Alert on the max;
  a sampled duration alone hides exactly the spikes worth paging on. A tick
  that never fans in (a zone died mid-tick) is not sampled at all rather
  than being reported with a fabricated duration.

#### Zone - `[asobi, zone, opened | closed | tick_skipped]`

- `opened` / `closed`: metadata `#{world_id, coords :: {integer(), integer()}}`, both
  unbounded (one per live world, one per grid cell) - never a label. Zones
  are lazy, so a live-zone count is not derivable from world count; subtract
  the two counters for a gauge. `closed` is gated on the zone still being in
  the manager's table, so it fires exactly once per `opened` even though
  `cleanup_zone/2` is reachable more than once for the same coords - a gauge
  built from the pair does not drift negative. It **can** drift upward: a
  world teardown emits no `closed` at all, because `asobi_zone_manager` does
  not trap exits (so a supervisor shutdown never runs its `terminate/2`) and
  `asobi_world_instance` stops the manager before the zone supervisor (so it
  never processes the zones' `DOWN`s). Key the gauge on `world_id` and drop a
  world's counters when `[asobi, world, finished]` arrives, rather than
  keeping one global counter pair. Making the manager trap exits to close the
  difference is a supervision-tree change with its own shutdown-latency cost
  and was deliberately not made here.
- `tick_skipped`: measurements `#{count}` - how many zones one world tick
  skipped because they had not retired the previous tick; metadata
  `#{world_id}`, unbounded, never a label. Added by asobi#426 alongside the
  ticker's back-pressure. Unlike `[asobi, world, tick]` this is not sampled,
  because it is emitted only on a tick that actually skipped: a healthy world
  is silent, and an unsampled counter is what makes the onset visible. Alert
  on a sustained non-zero rate, not on a single event - one skipped tick is a
  zone that ran long once, which is normal.

#### Lua - `[asobi, lua, state]`

- measurements `#{words, bytes}` - the size of the Luerl state behind one Lua
  bridge; metadata `#{script, kind, world_id | match_id, coords}`. `script`
  (one per loaded game script, fixed at deploy) and `kind`
  (`zone | world | match`, a fixed enum) are label-safe; `world_id`,
  `match_id` and `coords` are unbounded on the same grounds as
  `[asobi, zone, opened]`'s and are never a label. Added by asobi#536.
- Emitted per bridge **process**, so a world with a hundred live zones is a
  hundred series. Key them on `coords`; a `last_value` over `script` alone is
  one flapping gauge showing whichever zone reported most recently, which is
  worse than no metric. The identity is stamped at
  `asobi_lua_world:init_zone_state/2` and its two siblings rather than derived
  by the collector, which runs inside the bridge process and knows nothing
  about the grid.
- Sampled on **wall clock**, roughly once a second per bridge, overridable with
  `asobi_lua.state_sample_interval_ms`. A per-tick counter would be a rate that
  varies with the world's tick rate and multiplies by live zone count, which is
  the same reasoning that sampled `[asobi, world, tick]` above.
- This is the number that decides what a Lua tick costs - asobi copies the
  state into the callback's eval worker on every bounded callback, at roughly
  7 ms per MB - and before #536 it was not observable at all short of walking
  the term by hand in a remote shell. Alert on the trend, not a threshold.

#### Matchmaker - `[asobi, matchmaker, queued | deduped | removed | formed | failed]`

- `queued`: metadata `#{player_id, mode}`
- `deduped`: metadata `#{player_id, mode}`. An `add` answered with the
  caller's existing ticket instead of a new one, per the one-live-ticket-per
  (player, mode) guard. `mode` is label-safe on the same grounds as `queued`
  (rejected at the edge by `asobi_matchmaker:known_mode/1`); `player_id` is
  unbounded and must never be a label.
- `removed`: metadata `#{player_id, reason}`
- `formed`: measurements `#{player_count, wait_ms, count}`; metadata `#{mode}`
- `failed`: measurements `#{player_count, count}`; metadata `#{mode}`

#### Session - `[asobi, session, connected | disconnected]`

- `connected`: metadata `#{player_id}`
- `disconnected`: measurements add `duration_ms`; metadata `#{player_id}`.
  No in-tree emitter today; see Known gaps.

#### WebSocket - `[asobi, ws, connected | disconnected | message_in | message_out | connect_rate_limited | idle_auth_timeout | origin_rejected]`

- `connected` / `disconnected` / `idle_auth_timeout` / `origin_rejected`: no metadata
- `message_in` / `message_out`: metadata `#{type}` - unbounded
  (client-controlled); never a label. `message_in` is emitted in
  `src/ws/asobi_ws_handler.erl` immediately after `json:decode/1`, before
  dispatch and before authentication, guarded only by `is_binary/1`: the
  value is whatever the client put in the JSON `type` field. With the
  handler's 60 messages/second cap (`?WS_MSG_LIMIT`) and 64 KiB payload
  ceiling (`?WS_MAX_PAYLOAD_BYTES`), a single unauthenticated socket can
  mint on the order of 200k distinct multi-KiB values per hour - the exact
  cardinality DoS this ADR exists to prevent. Count the event; never key a
  label on `type`. `message_out` has no in-tree emitter today; see Known
  gaps.
- `connect_rate_limited`: metadata `#{peer_ip}` - unbounded (network-controlled); never a label

#### Rate limits outside the `ws` namespace - `[asobi, join, rate_limited]`, `[asobi, rehome, rate_limited]`

- Both: metadata `#{player_id}`

#### Anticheat - `[asobi, anticheat, violation]`

- Metadata `#{player_id, type :: atom(), details :: map()}`. `type` here is
  an atom chosen by core and is label-safe; `player_id` and `details` are
  not. No in-tree emitter today; see Known gaps.

#### Error - `[asobi, error]`

- Metadata `#{kind :: asobi_telemetry:game_error_kind(), details :: map()}`.
  Both keys are always present: `game_error/1` supplies `details => #{}`
  when the caller gives none, so a consumer never has to handle a missing
  key. `kind` is a fixed literal type by design (never derived from
  untrusted input, to avoid atom-table exhaustion) and is label-safe.
  `details` must stay bounded and free of sensitive data per the existing
  moduledoc, but is not itself an enum - do not use as a label.

#### Economy - `[asobi, economy, transaction]`

- Measurements `#{amount, count}`; metadata `#{player_id, currency, reason}`

#### Store - `[asobi, store, purchase]`

- Measurements `#{cost, count}`; metadata `#{player_id, item_id}`. No
  in-tree emitter today; see Known gaps.

#### Chat - `[asobi, chat, message_sent]`

- Metadata `#{channel_id, sender_id}` - both unbounded; never a label.
  `channel_id` is not a game-author catalogue value: it is a structured
  per-entity address. `asobi_chat_acl:validate_channel_id/1` accepts only
  these prefixes, and `classify/1` gives each its meaning:
  - `dm:<PlayerA>:<PlayerB>` - a direct-message pair. Cardinality grows with
    the square of the known-player count; #305 bounds minting to real player
    ids, which is a bound on abuse, not a bound useful to a label.
  - `world:<WorldId>` - one channel per live world.
  - `zone:<WorldId>:<X>,<Y>` and `prox:<WorldId>:<X>,<Y>` - one channel per
    zone or proximity cell, so cardinality is world count times grid size.
  - `room:<GroupUuid>` - one channel per group, keyed by a canonical uuid.
  - `global:<Name>` - game-wide channels above the world tier. This one
    scheme IS bounded: `<Name>` must appear in a configured mode's
    `chat => #{global => [...]}`, enforced via
    `asobi_game_modes:global_chat_channels/0`, so it is operator-declared
    like `mode`. It does not make `channel_id` as a whole label-safe - the
    per-entity schemes above dominate.

  A bare unprefixed id is also treated as a group id by `classify/1`, but
  `validate_channel_id/1` rejects it on both the WS and HTTP paths, so it is
  not reachable in practice. `?MAX_CHANNEL_ID_BYTES` caps each value at 256
  bytes; that caps the size of one label value, not how many distinct ones
  exist. Every scheme above except `global:` is keyed by a runtime entity - a
  player pair, a world, a zone coordinate, a group uuid - so the set grows
  with the running game, not with a fixed catalogue. Count the event and, if a breakdown is
  needed, derive the bounded prefix (`dm` / `world` / `zone` / `prox` /
  `room` / `global`) in the consumer rather than labelling on the full id.

#### Vote - `[asobi, vote, started | cast | resolved]`

- `started`: metadata `#{vote_id, method}`
- `cast`: metadata `#{vote_id, player_id}`
- `resolved`: measurements add `duration_ms`; metadata `#{vote_id, result :: map()}`

#### Auth cache - `[asobi, auth_cache, hit | miss | sweep]`

- `hit` / `miss`: metadata `#{kind :: positive | negative}`
- `sweep`: no metadata

That is 40 events across 14 domains (match, world, zone, matchmaker, session,
ws, join, rehome, anticheat, error, economy, store, chat, vote, auth_cache -
15 domains if `join`/`rehome` are counted separately from `ws`, as they are
distinct top-level event-name prefixes).

`asobi_telemetry:events/0` returns the list, so a consumer attaches to the
whole surface without restating it. Restating it is what let the built-in
debug logger and `opentelemetry_asobi` drift to the same stale 24-name
subset; `opentelemetry_asobi` should switch to `events/0` rather than keep
its own copy. `asobi_telemetry_tests` asserts `events/0` against the event
names actually passed to `telemetry:execute/3` in the module's compiled
abstract code, so an emitter added without a matching entry fails the build.

### Stability

Event names, and the keys present in measurements and metadata, are stable
and follow semver from this ADR onward: removing or renaming an event, or a
measurement/metadata key, is a breaking change requiring a major-version
bump. Adding new measurement keys, metadata keys, or new events is a minor
bump. The classification above is part of the contract: loosening a key
(unbounded to game-author-controlled to label-safe) is fine, since it only
widens a downstream consumer's options; tightening it in the other direction
is breaking, because a consumer may already have keyed a label on it. That
asymmetry is why the classification is stated per key and per event rather
than per key name - a blanket claim that is too generous is not fixable in a
minor release.

### Known gaps (documented, not fixed by this ADR)

- ~~`asobi_telemetry:setup/0` (the built-in debug logger) attaches to only 24
  of the 35 events.~~ Closed by asobi#312: `setup/0` attaches
  `asobi_telemetry:events/0`, the whole surface, and a test pins that list
  against the emitters. `opentelemetry_asobi` still carries its own copy of
  the stale list and should move to `events/0`.
- ~~No event exists for world-tick duration or live zone/world count.~~
  Closed by asobi#313, which added `[asobi, world, tick]` and the
  `[asobi, zone, opened | closed]` pair above. This was the one genuine
  instrumentation gap identified against the
  "world/ECS/network/RPC/DB/queue/scheduler" scope proposed alongside
  `asobi_metrics`; ECS and RPC don't exist in asobi, and DB/queue are kura's
  and shigoto's telemetry surfaces respectively, not asobi's.
  `asobi_zone_spawner` is a pure entity-template registry, not a zone
  lifecycle owner, and still emits nothing by design.
- Four of the 40 events are declared API with no in-tree emitter today -
  the `asobi_telemetry` function exists and is exported, but nothing in
  `src/` or `test/` calls it: `session_disconnected/2`
  (`[asobi, session, disconnected]`), `ws_message_out/1`
  (`[asobi, ws, message_out]`), `store_purchase/3`
  (`[asobi, store, purchase]`) and `anticheat_violation/3`
  (`[asobi, anticheat, violation]`). They stay part of the locked contract -
  an embedder can call them, and core may start to - but a consumer must not
  read silence on them as a measurement. `[asobi, anticheat, violation]` is
  the one to be careful with: an alert built on it never fires, and reads as
  "no cheating detected" when it actually means "no detector is wired up".
  Do not build a cheating alert on this event until core emits it. Wiring
  emitters (or dropping the unused functions) is still a follow-up to this
  ADR. Note that they are now attached by `setup/0` along with everything
  else, so "attached" is not evidence that anything emits them.

## Consequences

**Positive.**

- Users get observability via their existing stack (logs, OpenTelemetry
  traces, or a future Prometheus exporter) with no asobi-specific glue.
- A companion `asobi_metrics` package (or any future consumer) can subscribe
  to these events and expose metrics without core taking a dependency back,
  the same shape as `Taure/shigoto_metrics` and `Taure/gakudan_metrics`.
- The label-safe / game-author-controlled / unbounded split, written down
  once, is the answer every future consumer needs instead of re-deriving it
  from source.

**Negative.**

- The event surface is now locked. Future refactors of match, world,
  matchmaker, session, ws, economy, or vote code must preserve these names
  and keys or follow semver.
- The three known gaps above are real and now visibly incomplete rather than
  silently incomplete - they need separate follow-up PRs.

## Alternatives considered

- **Leave the surface undocumented and let each consumer infer it from
  source.** Rejected - this is exactly what let `opentelemetry_asobi` and
  `setup/0` drift to the same stale 24-event list without anyone noticing.
- **Have the Prometheus exporter map every metadata key straight to a
  label.** Rejected - the majority of metadata keys here are unbounded
  per-entity identifiers; doing this naively is a cardinality DoS.
