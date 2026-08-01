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
names — reshaping either after a dashboard or alert rule pins against it is
disruptive. And a label built from an unbounded field (a `player_id`, a
`match_id`) is a cardinality DoS on the exporter and the scraping Prometheus,
not just an inconvenience.

Recording the surface now, exactly as it exists, is the prerequisite for
building an exporter safely — not a step to defer until after one is built.

## Decision

`asobi` core depends on `telemetry` (already an `applications` entry in
`asobi.app.src`) and emits the events below via `asobi_telemetry`.

### Conventions

- All events use `telemetry:execute/3`, never `telemetry:span/3`. Every
  event's measurements include `count => 1`; duration-bearing events add
  `duration_ms` (wall-clock milliseconds) as an integer.
- **Label-safe metadata** — bounded, developer/game-declared enums with a
  small fixed cardinality (`mode`, `reason`, `kind`, `type`, `method`,
  `from_phase`, `to_phase`, `currency`). Safe to use as a Prometheus label.
- **Unbounded metadata** — per-entity identifiers or free-form data
  (`match_id`, `world_id`, `player_id`, `sender_id`, `vote_id`, `item_id`,
  `channel_id`, `peer_ip`, `details`, `result`). **Never** route these into a
  metric label. They stay on the raw event for tracing/audit sinks (e.g.
  `opentelemetry_asobi` spans) that can afford per-entity cardinality.
  `item_id` and `channel_id` are game-catalog values, not literally
  unbounded, but their size is controlled by the game author, not asobi —
  a consumer must not assume they stay small.

### Events

#### Match — `[asobi, match, started | finished | player_joined | player_left]`

- `started`: metadata `#{match_id, mode}`
- `finished`: measurements add `duration_ms`; metadata `#{match_id, result :: map()}`
- `player_joined` / `player_left`: metadata `#{match_id, player_id}`

#### World — `[asobi, world, started | finished | player_joined | player_left | phase_changed]`

- `started`: metadata `#{world_id, mode}`
- `finished`: measurements add `duration_ms`; metadata `#{world_id, result :: map()}`
- `player_joined` / `player_left`: metadata `#{world_id, player_id}`
- `phase_changed`: metadata `#{world_id, from_phase, to_phase}`

#### Matchmaker — `[asobi, matchmaker, queued | removed | formed | failed]`

- `queued`: metadata `#{player_id, mode}`
- `removed`: metadata `#{player_id, reason}`
- `formed`: measurements `#{player_count, wait_ms, count}`; metadata `#{mode}`
- `failed`: measurements `#{player_count, count}`; metadata `#{mode}`

#### Session — `[asobi, session, connected | disconnected]`

- `connected`: metadata `#{player_id}`
- `disconnected`: measurements add `duration_ms`; metadata `#{player_id}`

#### WebSocket — `[asobi, ws, connected | disconnected | message_in | message_out | connect_rate_limited | idle_auth_timeout | origin_rejected]`

- `connected` / `disconnected` / `idle_auth_timeout` / `origin_rejected`: no metadata
- `message_in` / `message_out`: metadata `#{type}`
- `connect_rate_limited`: metadata `#{peer_ip}` — unbounded (network-controlled); never a label

#### Rate limits outside the `ws` namespace — `[asobi, join, rate_limited]`, `[asobi, rehome, rate_limited]`

- Both: metadata `#{player_id}`

#### Anticheat — `[asobi, anticheat, violation]`

- Metadata `#{player_id, type, details :: map()}`. `type` is label-safe;
  `details` is not.

#### Error — `[asobi, error]`

- Metadata `#{kind :: asobi_telemetry:game_error_kind(), details => map()}`.
  `kind` is a fixed literal type by design (never derived from untrusted
  input, to avoid atom-table exhaustion) and is label-safe. `details` must
  stay bounded and free of sensitive data per the existing moduledoc, but is
  not itself an enum — do not use as a label.

#### Economy — `[asobi, economy, transaction]`

- Measurements `#{amount, count}`; metadata `#{player_id, currency, reason}`

#### Store — `[asobi, store, purchase]`

- Measurements `#{cost, count}`; metadata `#{player_id, item_id}`

#### Chat — `[asobi, chat, message_sent]`

- Metadata `#{channel_id, sender_id}`

#### Vote — `[asobi, vote, started | cast | resolved]`

- `started`: metadata `#{vote_id, method}`
- `cast`: metadata `#{vote_id, player_id}`
- `resolved`: measurements add `duration_ms`; metadata `#{vote_id, result :: map()}`

#### Auth cache — `[asobi, auth_cache, hit | miss | sweep]`

- `hit` / `miss`: metadata `#{kind :: positive | negative}`
- `sweep`: no metadata

That is 35 events across 13 domains (match, world, matchmaker, session, ws,
join, rehome, anticheat, error, economy, store, chat, vote, auth_cache — 14
domains if `join`/`rehome` are counted separately from `ws`, as they are
distinct top-level event-name prefixes).

### Stability

Event names, and the keys present in measurements and metadata, are stable
and follow semver from this ADR onward: removing or renaming an event, or a
measurement/metadata key, is a breaking change requiring a major-version
bump. Adding new measurement keys, metadata keys, or new events is a minor
bump. The label-safe/unbounded classification above is part of the contract
— reclassifying a key from unbounded to label-safe is fine (it only loosens
a downstream consumer's options); reclassifying the other direction is
breaking, because a consumer may already have keyed a label on it.

### Known gaps (documented, not fixed by this ADR)

- `asobi_telemetry:setup/0` (the built-in debug logger) attaches to only 24
  of the 35 events. Missing: `matchmaker/failed`, `join/rate_limited`,
  `ws/connect_rate_limited`, `rehome/rate_limited`, `ws/idle_auth_timeout`,
  `ws/origin_rejected`, `anticheat/violation`, `error`, and all three
  `auth_cache/*` events. `opentelemetry_asobi` mirrors the same stale list.
  Tracked as a follow-up fix, not addressed here.
- No event exists for world-tick duration or live zone/world count —
  `asobi_world_ticker`, `asobi_zone_manager`, and `asobi_zone_spawner` emit
  nothing today. This is the one genuine instrumentation gap identified
  against the "world/ECS/network/RPC/DB/queue/scheduler" scope proposed
  alongside `asobi_metrics`; ECS and RPC don't exist in asobi, and DB/queue
  are kura's and shigoto's telemetry surfaces respectively, not asobi's.
  Tracked as a follow-up addition, not addressed here.

## Consequences

**Positive.**

- Users get observability via their existing stack (logs, OpenTelemetry
  traces, or a future Prometheus exporter) with no asobi-specific glue.
- A companion `asobi_metrics` package (or any future consumer) can subscribe
  to these events and expose metrics without core taking a dependency back,
  the same shape as `Taure/shigoto_metrics` and `Taure/gakudan_metrics`.
- The label-safe/unbounded split, written down once, is the answer every
  future consumer needs instead of re-deriving it from source.

**Negative.**

- The event surface is now locked. Future refactors of match, world,
  matchmaker, session, ws, economy, or vote code must preserve these names
  and keys or follow semver.
- The two known gaps above are real and now visibly incomplete rather than
  silently incomplete — they need separate follow-up PRs.

## Alternatives considered

- **Leave the surface undocumented and let each consumer infer it from
  source.** Rejected — this is exactly what let `opentelemetry_asobi` and
  `setup/0` drift to the same stale 24-event list without anyone noticing.
- **Have the Prometheus exporter map every metadata key straight to a
  label.** Rejected — the majority of metadata keys here are unbounded
  per-entity identifiers; doing this naively is a cardinality DoS.
