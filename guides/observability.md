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

- **53 telemetry events**, listed below. Stable names; the measurement and
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

Fifty-three, grouped by what they are about. Measurement and metadata keys
are in `m:asobi_telemetry`, which is also the list `asobi_telemetry:events/0`
returns - attach to that rather than restating the names.

### Sessions and the socket

```
asobi.session.connected          asobi.session.disconnected
asobi.ws.connected               asobi.ws.disconnected
asobi.ws.message_in              asobi.ws.message_out
asobi.ws.connect_rate_limited    asobi.ws.idle_auth_timeout
asobi.ws.origin_rejected         asobi.ws.legacy_input_unwrap
asobi.dgram.bindings_expired     asobi.dgram.dropped
asobi.dgram.send_failed          asobi.dgram.recv_failed
asobi.dgram.input_undelivered    asobi.dgram.input_unknown
asobi.dgram.input_undecodable    asobi.dgram.canary_missed
asobi.dgram.link_up              asobi.dgram.link_closed
asobi.dgram.link_error           asobi.dgram.pose_saturated
asobi.wire.binary_refused
```

The `asobi.dgram.*` events fire only on a node in the
[`dgram_gw` role](configuration.md#the-datagram-gateway).

`asobi.dgram.dropped` is the one to build a dashboard on, and `gate` is why it is
one event rather than seven. Nothing is ever sent back to a rejected datagram, so
this counter is the only evidence a rejection happened at all.

| `gate` rising | What it means |
| --- | --- |
| `parse` alone | Someone is pointing a scanner at the port. Uninteresting. |
| `parse` + `ingress_global` | A volumetric flood. The global tier is doing its job. |
| `unknown_conn` | Guessing at `conn_id`s, which is a 32-bit space. |
| `mac` | **Wake up.** Someone has a live `conn_id` and not the key. |
| `ingress` / `input` | One connection over its budget: a broken client, usually. |
| `binding` | Replays or a flapping path. Check `reason`. |

`asobi.dgram.canary_missed` carries `consecutive`, and that is the field to alert
on: one miss is a scheduler hiccup, two in a row means the receive loop is wedged
and the node stops reporting ready. It is the only signal that separates a wedged
loop from a quiet port, which look identical from outside. Note what it does not
cover: `SO_REUSEPORT` means the kernel chooses which shard receives the probe, so
a healthy canary proves **at least one** shard is alive, not all of them. A single
wedged shard shows up as a fraction of players timing out, and the place to catch
that is `asobi.dgram.recv_failed` plus client-side telemetry.

`asobi.dgram.pose_saturated` counts transform values that did not fit their
configured scale. Any sustained rate means the `scale` in
[`dgram_pose`](configuration.md#describing-your-transform-fields) is wrong for
this game's world size, and the fix is configuration rather than code.

`asobi.wire.binary_refused` fires on the **engine**, not the gateway, and counts
`world.tick` frames the binary encoder could not produce, which are sent as text
instead. One is not a fault - a client that negotiated binary still handles text,
and the frame after it is a keyframe that rebinds every slot. A **sustained** rate
is: it means the zone is refusing, repairing and refusing again, and a zone whose
rebind keyframe also refuses drops off the binary wire and the datagram plane for
its life (look for `binary wire disabled for this zone`).

`reason` says which: `dict_too_large` for a frame past the 32 field names the
dictionary can index - count the fields on your widest entity, the log line names
it - `unencodable_field` for a list or a nested map where the wire carries
scalars, `bad_field_name` and `bad_entity_id` for a name or id that is not text or
is past 255 bytes, `ambiguous_field_name` for two names that collide once atoms
are rendered as text, `value_too_large` for a string past 65535 bytes, and
`no_slot` for a slot map that has drifted from the baseline. The matching log line
is throttled to one per zone per minute and carries the count it suppressed.

`asobi.dgram.link_error` with `reason = bad_auth` is worth an alert. The engine
link is loopback-only, so a failed authentication is either a misconfigured
`dgram_link_secret` or something local that should not be talking to it.

`asobi.dgram.link_closed` on its own is not an outage: bindings already in the
table keep working, so players stay on the plane while the engine restarts. What
stops is new mints and revocations, and an undeliverable revocation is bounded by
the mint's own expiry.

`asobi.dgram.input_unknown` is expected in small numbers around a session ending,
because the two ends revoke asynchronously. Sustained, it means the gateway
believes in a binding the engine has forgotten.

`asobi.dgram.bindings_expired` fires once per sweep, counting datagram
credentials that were minted and never used. A rising count is
a client-side fault rather than an attack - minting costs an authenticated
WebSocket, so this is clients opening the plane and walking away, not anyone
getting something for free.

`asobi.ws.origin_rejected` and `asobi.ws.connect_rate_limited` are the two
worth alerting on: a spike in either is either an attack or a client
misconfiguration, and both are invisible in game metrics.

`asobi.ws.legacy_input_unwrap` counts input frames sent in the deprecated
sole-`data` shape (see [WebSocket protocol](websocket-protocol.md#world-input)).
It is not an error, and not worth an alert: it exists so the carve-out can be
retired once the counter reaches zero for a release, instead of guessing which
clients still depend on it.

### Matches and matchmaking

```
asobi.match.started              asobi.match.finished
asobi.match.player_joined        asobi.match.player_left
asobi.matchmaker.queued          asobi.matchmaker.removed
asobi.matchmaker.deduped         asobi.matchmaker.formed
asobi.matchmaker.failed          asobi.matchmaker.dropped
```

`dropped{reason=no_live_session}` counts tickets that were matched but could
not be seated because the player had disconnected while queued. It is
deliberately NOT on `[asobi, error]`: on mobile that is the ordinary
consequence of backgrounding the app or moving between networks, and counting
it as an error would make the node's error rate track connection churn. A
rising rate means players are abandoning the queue - look at wait times, not at
the game.

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
asobi.zone.cold                  asobi.zone.hot
asobi.rehome.rate_limited        asobi.lua.state
```

`asobi.world.tick` is sampled rather than emitted every tick - at 20 Hz per
world an unsampled event is a metrics pipeline of its own.

`asobi.zone.cold` and `asobi.zone.hot` are the two halves of one gauge: a zone
with nothing to simulate ticks at `cold_tick_divisor` instead of every tick, and
these fire on the transition rather than per tick. On a large lazy world most
zones should be cold most of the time, and a world where none are is a world
paying the full per-callback cost for empty space. The direction worth an alert
is the other one - a zone that goes cold and never comes back is a zone that has
stopped responding to the players in it. See
[Performance tuning](performance-tuning.md#zone-tick-hibernation-and-reaping).

`asobi.zone.tick_skipped` is the one to alert on. It counts zones the world
tick skipped because they had not finished the previous one, so a healthy
world never emits it at all and a sustained non-zero rate means a world that
can no longer keep up. A single event is a zone that ran long once, which is
normal; alert on the rate, not the event. Rising counts here usually mean a
`zone_tick` doing too much, too many entities in one zone, or Lua memory that
is no longer being collected - see
[Performance tuning](performance-tuning.md#lua-memory).

`asobi.lua.state` is what tells you which of those it is. It reports `words`
and `bytes` for the Luerl state behind one Lua bridge - a zone, a world or a
match - about once a second per bridge
(`asobi_lua.state_sample_interval_ms`). That size decides what a Lua tick
costs, because asobi copies the whole state into the callback's eval worker at
roughly 7 ms per MB, so a state climbing through tens of MB pushes a zone past
its tick budget on its own. A healthy zone's state is flat; alert on the trend
rather than a threshold.

Metadata is `#{script, kind, world_id | match_id, coords}`. `script` and `kind`
(`zone | world | match`) are label-safe; the identifiers and `coords` are
unbounded and must not be labels. The event is per bridge process, so a world
with a hundred live zones produces a hundred series - key them on `coords`, or
whichever zone reported last overwrites the rest and you get one flapping
gauge. asobi also logs `lua_state_large` once per excursion past
`state_warn_words` (~100 MB by default), for operators without a metrics
pipeline attached.

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
