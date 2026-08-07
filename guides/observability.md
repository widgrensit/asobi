# Observability

asobi emits `telemetry` events and structured JSON logs. It does not ship a
metrics endpoint, a dashboard or an alerting rule, and that is deliberate: a
game backend that grows its own time-series store is a maintenance liability
with a strictly better substitute one hop away. Wire the events to Prometheus,
point your log shipper at stdout, and let Grafana own the graphs.

The operator console at `/console` answers "what is this node doing right
now". Everything on this page answers "what has it been doing for six hours",
which is a different question with a different tool. See
[Operator console](console.md) for the first one.

## What you get

- **37 telemetry events**, listed below. Stable names; the measurement and
  metadata keys are documented per-event in `m:asobi_telemetry`.
- **Structured JSON logs** on stdout, one object per line, via
  `nova_jsonlogger`. No configuration needed - a container log shipper reads
  them as-is.
- **`GET /health`** and **`GET /ready`** for liveness and readiness.

## What you do not get

- **No `/metrics` route.** asobi has no opinion about your scrape path,
  registry, or which events become counters versus histograms. Attaching an
  exporter is about fifteen lines, below.
- **No dashboards or alert rules** shipped in this repo yet.
- **No log aggregation.** The logs are structured; shipping them is your
  stack's job.

## Prometheus

Add `telemetry_metrics_prometheus` to your release and declare the metrics you
want. Nothing in asobi needs changing.

```erlang
{deps, [
    {telemetry_metrics_prometheus, "~> 1.1"}
]}.
```

```erlang
%% In your own application's start/2.
Metrics = [
    telemetry_metrics:counter(~"asobi.match.started.count", #{
        event_name => [asobi, match, started],
        measurement => count,
        tags => [mode]
    }),
    telemetry_metrics:distribution(~"asobi.match.finished.duration_ms", #{
        event_name => [asobi, match, finished],
        measurement => duration_ms,
        tags => [mode]
    }),
    telemetry_metrics:counter(~"asobi.ws.connected.count", #{
        event_name => [asobi, ws, connected],
        measurement => count
    })
],
{ok, _} = telemetry_metrics_prometheus:start_link(#{metrics => Metrics}).
```

### Choosing tags

A tag becomes a Prometheus label, and a label with unbounded cardinality will
take down your Prometheus rather than your game. `mode`, `reason` and `result`
are bounded and safe. **`player_id`, `match_id`, `world_id` and `zone_id` are
not** - they are one series per entity, forever. They are in the metadata
because a trace exporter and a log line want them; that is not the same as a
metric label wanting them.

[ADR 0005](https://github.com/widgrensit/asobi/blob/main/docs/adr/0005-telemetry-event-surface.md)
classifies the metadata keys it covers by label safety. It predates several of
the events below, so treat the list on this page as the current surface and the
ADR as the reasoning.

### In a cluster

Label every series with the node, or you cannot tell a fleet-wide change from
one node misbehaving. Most of these events are per-node by nature: the process
that emitted one lives somewhere specific.

```erlang
telemetry_metrics_prometheus:start_link(#{
    metrics => Metrics,
    default_tags => #{node => atom_to_binary(node(), utf8)}
})
```

## Logs

Every line is a JSON object on stdout. In Kubernetes, Promtail or Grafana Alloy
picks them up with no application configuration; under Compose, point your
shipper at the container's logs.

Fields worth building queries on:

| Field | What it is |
|-------|------------|
| `msg` | a stable event slug, e.g. `console_enabled`, `engine_bootstrap_failed` |
| `level` | `debug` through `error` |
| `mfa` | module, function and arity that logged it |
| `file`, `line` | where in the source |

Slugs are stable and worth alerting on. `engine_bootstrap_failed` and
`console_disabled_without_secret` both mean a deployment came up wrong, and
both are the kind of thing that is otherwise noticed a day later.

## The events

Thirty-seven, grouped by what they are about. Measurement and metadata keys
are in `m:asobi_telemetry`.

### Sessions and the socket

```
asobi.session.connected          asobi.session.disconnected
asobi.ws.connected               asobi.ws.disconnected
asobi.ws.message_in              asobi.ws.message_out
asobi.ws.connect_rate_limited    asobi.ws.idle_auth_timeout
asobi.ws.origin_rejected
```

`asobi.ws.origin_rejected` and `asobi.ws.connect_rate_limited` are the two
worth alerting on: a spike in either is either an attack or a client
misconfiguration, and both are invisible in game metrics.

### Matches and matchmaking

```
asobi.match.started              asobi.match.finished
asobi.match.player_joined        asobi.match.player_left
asobi.matchmaker.queued          asobi.matchmaker.removed
asobi.matchmaker.formed          asobi.matchmaker.failed
```

Queue depth is the number worth watching, and in a cluster it is per-node -
each node's matchmaker holds its own tickets, so a fleet-wide total is a sum
across nodes, not a reading from one. See [Clustering](clustering.md).

### Worlds and zones

```
asobi.world.started              asobi.world.finished
asobi.world.player_joined        asobi.world.player_left
asobi.world.phase_changed        asobi.world.tick
asobi.zone.opened                asobi.zone.closed
asobi.join.rate_limited          asobi.rehome.rate_limited
```

`asobi.world.tick` is sampled rather than emitted every tick - at 20 Hz per
world an unsampled event is a metrics pipeline of its own.

### Gameplay systems

```
asobi.vote.started               asobi.vote.cast
asobi.vote.resolved              asobi.chat.message_sent
asobi.economy.transaction        asobi.store.purchase
asobi.anticheat.violation
```

### Auth cache

```
asobi.auth_cache.hit             asobi.auth_cache.miss
asobi.auth_cache.sweep
```

Hit ratio is a useful health signal: a collapse means tokens are being
re-verified against the database on every request.

## OpenTelemetry

`opentelemetry_asobi` attaches to the same events and exports spans, so a
deployment already running a collector needs no exporter of its own.

## Next steps

- [Operator console](console.md) - live state and the ops API.
- [Clustering](clustering.md) - which readings are per-node.
- [Performance tuning](performance-tuning.md) - the knobs behind the numbers.
