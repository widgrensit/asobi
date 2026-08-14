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

- **40 telemetry events**, listed below. Stable names; the measurement and
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

Forty, grouped by what they are about. Measurement and metadata keys
are in `m:asobi_telemetry`, which is also the list `asobi_telemetry:events/0`
returns - attach to that rather than restating the names.

### Sessions and the socket

```
asobi.session.connected          asobi.session.disconnected
asobi.ws.connected               asobi.ws.disconnected
asobi.ws.message_in              asobi.ws.message_out
asobi.ws.connect_rate_limited    asobi.ws.idle_auth_timeout
asobi.ws.origin_rejected         asobi.ws.legacy_input_unwrap
```

`asobi.ws.origin_rejected` and `asobi.ws.connect_rate_limited` are the two
worth alerting on: a spike in either is either an attack or a client
misconfiguration, and both are invisible in game metrics.

`asobi.ws.legacy_input_unwrap` counts input frames sent in the deprecated
sole-`data` shape (see [WebSocket protocol](websocket-protocol.md#worldinput)).
It is not an error, and not worth an alert: it exists so the carve-out can be
retired once the counter reaches zero for a release, instead of guessing which
clients still depend on it.

### Matches and matchmaking

```
asobi.match.started              asobi.match.finished
asobi.match.player_joined        asobi.match.player_left
asobi.matchmaker.queued          asobi.matchmaker.removed
asobi.matchmaker.deduped         asobi.matchmaker.formed
asobi.matchmaker.failed
```

Queue depth is the number worth watching, and in a cluster it is per-node -
each node's matchmaker holds its own tickets, so a fleet-wide total is a sum
across nodes, not a reading from one. See [Clustering](clustering.md).

**The alert worth having is `removed{reason=expired}` rising while `formed`
stays flat.** That pair says exactly one thing, with no interpretation needed:
players waited the full `max_wait_seconds` and got nothing. Removals carry
`reason` - `cancelled` when a client withdraws, `expired` when the ticket times
out - and only `expired` means the matchmaker failed to do its job.

`deduped` fires when a player asks to queue for a mode they already have an
open ticket on and gets that ticket back. (The client-facing field on the reply
is named `already_queued`; the metric keeps the mechanism's name.) Some of it
is routine: a double-tapped *find match*, and reconnect resubmits, which are
idempotent by design. It is a hint, not a diagnosis. A sustained rate is worth looking at -
one cause is several clients authenticated as the same player, which no amount
of waiting will fix because one player cannot fill a two-player match - but a
bored player re-tapping in an empty queue produces the same shape.

Note what this view **cannot** tell you. Distinguishing "one player re-tapping"
from "several clients sharing one identity" needs a distinct-player count, and
`player_id` is unbounded so an exporter must never make it a label (see
[ADR 0005](https://github.com/widgrensit/asobi/blob/main/docs/adr/0005-telemetry-event-surface.md)).
`queued` and `deduped` are counters of events, not a live-ticket count - queue
depth is the snapshot gauge described above. To separate those two cases you
need the node's queue snapshot or its logs, not Prometheus.

Handlers run **synchronously in the process that emitted the event**, so a
handler attached to a matchmaker event runs inside the matchmaker's own message
loop. Never call `asobi_matchmaker:get_queue_stats/0` from one - that is a
`gen_server:call` to the process currently executing your handler, so it
deadlocks until the call times out and stalls matchmaking for every player
meanwhile. Read `asobi_matchmaker:snapshot/0` instead: it reads ETS and never
messages the matchmaker.

### Worlds and zones

```
asobi.world.started              asobi.world.finished
asobi.world.player_joined        asobi.world.player_left
asobi.world.phase_changed        asobi.world.tick
asobi.zone.opened                asobi.zone.closed
asobi.zone.tick_skipped          asobi.join.rate_limited
asobi.rehome.rate_limited
```

`asobi.world.tick` is sampled rather than emitted every tick - at 20 Hz per
world an unsampled event is a metrics pipeline of its own.

`asobi.zone.tick_skipped` is the one to alert on. It counts zones the world
tick skipped because they had not finished the previous one, so a healthy
world never emits it at all and a sustained non-zero rate means a world that
can no longer keep up. A single event is a zone that ran long once, which is
normal; alert on the rate, not the event. Rising counts here usually mean a
`zone_tick` doing too much, too many entities in one zone, or Lua memory that
is no longer being collected - see
[Performance tuning](performance-tuning.md#lua-memory).

### Gameplay systems

```
asobi.vote.started               asobi.vote.cast
asobi.vote.resolved              asobi.chat.message_sent
asobi.economy.transaction        asobi.store.purchase
asobi.anticheat.violation        asobi.error
```

`asobi.error` is game-code failing rather than asobi failing - a Lua callback
raising, a spawn naming a template that does not exist, a zone that could not
be reached. Its `kind` is a fixed enum and safe as a label; its `details` are
not.

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
