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
    because every entry point rejects an unknown mode before it can be
    queued, via `asobi_matchmaker:known_mode/1`
    (`src/ws/asobi_ws_handler.erl:450`,
    `src/controllers/asobi_matchmaker_controller.erl:10`), which caps it at
    64 bytes and requires it to resolve to a configured game module.
  - `reason` on `matchmaker/removed` - an `atom()` chosen by core.
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
  `vote_id`, `peer_ip`, `channel_id`, `details`, `result`, and `type` on
  `ws/message_in` and `ws/message_out`. **Never** route these into a metric
  label. They stay on the raw event for tracing/audit sinks (e.g.
  `opentelemetry_asobi` spans) that can afford per-entity cardinality.

### Events

#### Match - `[asobi, match, started | finished | player_joined | player_left]`

- `started`: metadata `#{match_id, mode}`
- `finished`: measurements add `duration_ms`; metadata `#{match_id, result :: map()}`
- `player_joined` / `player_left`: metadata `#{match_id, player_id}`

#### World - `[asobi, world, started | finished | player_joined | player_left | phase_changed]`

- `started`: metadata `#{world_id, mode}`
- `finished`: measurements add `duration_ms`; metadata `#{world_id, result :: map()}`
- `player_joined` / `player_left`: metadata `#{world_id, player_id}`
- `phase_changed`: metadata `#{world_id, from_phase, to_phase}`

#### Matchmaker - `[asobi, matchmaker, queued | removed | formed | failed]`

- `queued`: metadata `#{player_id, mode}`
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

  A bare unprefixed id is also treated as a group id by `classify/1`, but
  `validate_channel_id/1` rejects it on both the WS and HTTP paths, so it is
  not reachable in practice. `?MAX_CHANNEL_ID_BYTES` caps each value at 256
  bytes; that caps the size of one label value, not how many distinct ones
  exist. Every scheme above is keyed by a runtime entity - a player pair, a
  world, a zone coordinate, a group uuid - so the set grows with the running
  game, not with a fixed catalogue. Count the event and, if a breakdown is
  needed, derive the bounded prefix (`dm` / `world` / `zone` / `prox` /
  `room`) in the consumer rather than labelling on the full id.

  Pending: asobi#320 adds a `global:<Name>` tier above `world:`, for
  game-wide channels that outlive a single world. That one scheme is
  operator-declared - `<Name>` must appear in a configured mode's
  `chat => #{global => [...]}` - so it is bounded like `mode` is. It does
  not change the classification of `channel_id` as a whole, which stays
  unbounded because the per-entity schemes above dominate it. When #320
  merges, add `global:<Name>` to the list above and to the derivable prefix
  set.

#### Vote - `[asobi, vote, started | cast | resolved]`

- `started`: metadata `#{vote_id, method}`
- `cast`: metadata `#{vote_id, player_id}`
- `resolved`: measurements add `duration_ms`; metadata `#{vote_id, result :: map()}`

#### Auth cache - `[asobi, auth_cache, hit | miss | sweep]`

- `hit` / `miss`: metadata `#{kind :: positive | negative}`
- `sweep`: no metadata

That is 35 events across 13 domains (match, world, matchmaker, session, ws,
join, rehome, anticheat, error, economy, store, chat, vote, auth_cache - 14
domains if `join`/`rehome` are counted separately from `ws`, as they are
distinct top-level event-name prefixes).

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

- `asobi_telemetry:setup/0` (the built-in debug logger) attaches to only 24
  of the 35 events. Missing: `matchmaker/failed`, `join/rate_limited`,
  `ws/connect_rate_limited`, `rehome/rate_limited`, `ws/idle_auth_timeout`,
  `ws/origin_rejected`, `anticheat/violation`, `error`, and all three
  `auth_cache/*` events. `opentelemetry_asobi` mirrors the same stale list.
  Tracked in asobi#312, not addressed here.
- No event exists for world-tick duration or live zone/world count -
  `asobi_world_ticker`, `asobi_zone_manager`, and `asobi_zone_spawner` emit
  nothing today. This is the one genuine instrumentation gap identified
  against the "world/ECS/network/RPC/DB/queue/scheduler" scope proposed
  alongside `asobi_metrics`; ECS and RPC don't exist in asobi, and DB/queue
  are kura's and shigoto's telemetry surfaces respectively, not asobi's.
  Tracked in asobi#313, not addressed here.
- Four of the 35 events are declared API with no in-tree emitter today -
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
  emitters (or dropping the unused functions) is a follow-up to this ADR,
  alongside asobi#312 and asobi#313.

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
