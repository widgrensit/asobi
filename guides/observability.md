# Observability

Asobi emits [telemetry](https://github.com/beam-telemetry/telemetry) events at all
critical points. You can attach any handler — OpenTelemetry, Prometheus, StatsD,
or your own logger.

## Telemetry Events

| Event | Measurements | Metadata |
|-------|-------------|----------|
| `[asobi, match, started]` | `count` | `match_id`, `mode` |
| `[asobi, match, finished]` | `duration_ms`, `count` | `match_id`, `result` |
| `[asobi, match, player_joined]` | `count` | `match_id`, `player_id` |
| `[asobi, match, player_left]` | `count` | `match_id`, `player_id` |
| `[asobi, world, started]` | `count` | `world_id`, `mode` |
| `[asobi, world, finished]` | `duration_ms`, `count` | `world_id`, `result` |
| `[asobi, world, player_joined]` | `count` | `world_id`, `player_id` |
| `[asobi, world, player_left]` | `count` | `world_id`, `player_id` |
| `[asobi, world, phase_changed]` | `count` | `world_id`, `from_phase`, `to_phase` |
| `[asobi, matchmaker, queued]` | `count` | `player_id`, `mode` |
| `[asobi, matchmaker, removed]` | `count` | `player_id`, `reason` |
| `[asobi, matchmaker, formed]` | `player_count`, `wait_ms`, `count` | `mode` |
| `[asobi, session, connected]` | `count` | `player_id` |
| `[asobi, session, disconnected]` | `duration_ms`, `count` | `player_id` |
| `[asobi, ws, connected]` | `count` | |
| `[asobi, ws, disconnected]` | `count` | |
| `[asobi, ws, message_in]` | `count` | `type` |
| `[asobi, ws, message_out]` | `count` | `type` |
| `[asobi, economy, transaction]` | `amount`, `count` | `player_id`, `currency`, `reason` |
| `[asobi, store, purchase]` | `cost`, `count` | `player_id`, `item_id` |
| `[asobi, chat, message_sent]` | `count` | `channel_id`, `sender_id` |
| `[asobi, vote, started]` | `count` | `vote_id`, `method` |
| `[asobi, vote, cast]` | `count` | `vote_id`, `player_id` |
| `[asobi, vote, resolved]` | `duration_ms`, `count` | `vote_id`, `result` |

## OpenTelemetry Setup

Add the OTel instrumentation libraries to your game app's `rebar.config`:

```erlang
{deps, [
    {asobi, "~> 0.20"},
    %% OTel instrumentation (optional)
    {opentelemetry_exporter, "~> 1.8"},
    {opentelemetry_asobi,
        {git, "https://github.com/Taure/opentelemetry_asobi.git", {branch, "main"}}},
    {opentelemetry_nova,
        {git, "https://github.com/novaframework/opentelemetry_nova.git", {branch, "main"}}},
    {opentelemetry_kura,
        {git, "https://github.com/Taure/opentelemetry_kura.git", {branch, "main"}}},
    {opentelemetry_shigoto,
        {git, "https://github.com/Taure/opentelemetry_shigoto.git", {branch, "main"}}}
]}.
```

Add to your `applications` in `.app.src`:

```erlang
{applications, [
    kernel, stdlib, asobi,
    opentelemetry_exporter,
    opentelemetry_asobi,
    opentelemetry_nova,
    opentelemetry_kura,
    opentelemetry_shigoto
]}.
```

Call setup in your app's `start/2`:

```erlang
start(_StartType, _StartArgs) ->
    opentelemetry_asobi:setup(),
    opentelemetry_nova:setup(#{prometheus => #{port => 9464}}),
    opentelemetry_kura:setup(),
    opentelemetry_shigoto:setup(),
    my_sup:start_link().
```

Add OTel config to your `sys.config`:

```erlang
{opentelemetry, [
    {span_processor, batch},
    {traces_exporter, otlp}
]},
{opentelemetry_exporter, [
    {otlp_protocol, http_protobuf},
    {otlp_endpoint, "http://localhost:4318"}
]}
```

## Docker Compose Stack

Asobi ships a ready-to-use observability stack in `docker/`:

- **OTel Collector** — receives traces (OTLP) and scrapes Prometheus metrics
- **Tempo** — trace storage and query
- **Mimir** — metrics storage (Prometheus-compatible)
- **Grafana** — dashboards with pre-provisioned datasources

Start it alongside PostgreSQL:

```bash
docker compose up
```

Then open Grafana at [http://localhost:3000](http://localhost:3000).

### Services

| Service | Port | Purpose |
|---------|------|---------|
| Grafana | 3000 | Dashboards and trace explorer |
| OTel Collector | 4317 (gRPC), 4318 (HTTP) | Receives traces and metrics |
| Tempo | 3200 | Trace backend |
| Mimir | 9009 | Metrics backend |
| Prometheus scrape | 9464 | Scraped from your app by the collector |

## Custom Telemetry Handlers

You can attach your own handlers to any Asobi event:

```erlang
telemetry:attach(
    <<"my-match-counter">>,
    [asobi, match, started],
    fun(_Event, _Measurements, Metadata, _Config) ->
        logger:info(#{msg => <<"match_started">>, mode => maps:get(mode, Metadata)})
    end,
    #{}
).
```
