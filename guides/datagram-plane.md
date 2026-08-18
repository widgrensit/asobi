# The datagram plane

Entity **positions** can travel over UDP instead of the WebSocket. One lost
packet then costs one frame of staleness rather than stalling everything behind
a TCP retransmit.

Optional, off by default, and **self-hosting only**. Everything below is safe to
switch on and safe to leave alone.

## What problem it solves

Every frame today goes over one TLS WebSocket, which is TCP. TCP guarantees
order, so a single lost packet stalls everything behind it until it is
retransmitted, typically 100-200ms. For a chat message that is invisible. For
"where is the player standing right now" it is a rubber-band.

## What it carries, and what it never carries

Downstream, exactly one thing: `pose`, the absolute transform state of entities.
`x, y, vx, vy` as `int16` against a scale you configure, about ten bytes an
entity. Upstream, `world.input`, the frame your client already sends when a
player moves.

**Never on this plane:** authentication, inventory, economy, chat, match results,
and entity creation and removal. `world.tick` above all, which is an op-delta
against a baseline that advances on send, so one lost frame corrupts the client's
view permanently.

That selection is a written rule rather than taste: the plane carries only frames
the framework defines every byte of, and only frames that are self-contained per
record.

## Why losing packets is fine here

A pose is **absolute**: "entity 5 is at (300, 480)". Miss one and the next one
50ms later supersedes it completely. Nothing accumulates and nothing goes wrong.

That is the whole reason the plane carries positions and nothing else.

Entities that stop moving stop being mentioned, which would leave a client that
missed the last update wrong forever. Axial refresh fixes that with no acks and
no per-client state: each tick additionally re-sends the slice of entities whose
slot falls in that tick, so nothing is stale for longer than one period.

## What an attacker can do

The downlink carries no MAC and no encryption, stated plainly because it is a
real reduction: *the datagram plane provides off-path forgery resistance and no
confidentiality or on-path integrity.*

An attacker needs the connection id **and** the path tag **and** the ability to
deliver to the victim's current network path. With all three they can make one
player's *render* of other entities wrong for at most one pose interval, after
which the next pose overwrites it. They cannot affect the server, any other
player, the simulation, entity creation or removal, or any non-transform field.

Everything with authority travels only on the TLS WebSocket, in every state.

## Server setup

Two containers from the same image. The gateway binds a UDP port and parses
packets from anyone on the internet, so it must not share a process tree with
your Lua sandbox or your database credentials: in the `dgram_gw` role no zone,
world, match, Lua VM or database pool is ever started.

```bash
openssl rand -hex 32 > dgram_secret.txt
printf 'dgram_secret.txt\n' >> .gitignore
```

```yaml
  asobi:
    image: ghcr.io/widgrensit/asobi:latest
    # ...your existing engine configuration, plus:
    environment:
      # Where to dial the gateway. This is the engine's opt-in: without it
      # nothing is dialled and clients are told the plane is unavailable.
      ASOBI_DGRAM_GATEWAY: "dgram:7778"
      # What clients are told to send to - your public address, not the
      # container's. Delivered in the mint reply, which is why the plane needs
      # no DNS and no SNI and why a non-standard port costs nothing.
      ASOBI_DGRAM_ENDPOINT: "udp.example.com:7777"
      ASOBI_DGRAM_LINK_SECRET_FILE: /run/secrets/dgram
      ASOBI_DGRAM_POSE_FIELDS: "x:100,y:100,vx:100,vy:100"
    volumes:
      - ./dgram_secret.txt:/run/secrets/dgram:ro

  dgram:
    image: ghcr.io/widgrensit/asobi:latest
    environment:
      ASOBI_ROLE: dgram_gw
      ASOBI_DGRAM_PORT: 7777
      ASOBI_DGRAM_LINK_PORT: 7778
      ASOBI_DGRAM_LINK_SECRET_FILE: /run/secrets/dgram
      ASOBI_DGRAM_POSE_FIELDS: "x:100,y:100,vx:100,vy:100"
    ports:
      - "7777:7777/udp"
    volumes:
      - ./dgram_secret.txt:/run/secrets/dgram:ro
    restart: unless-stopped
```

Open **UDP** 7777 on your firewall. Never publish the link port: it carries mint
credentials, has no transport security of its own, and binds loopback for that
reason.

The engine dials the gateway rather than the other way round, so the gateway
needs no knowledge of where the engine is. The link is deliberately **not**
distributed Erlang, which would have been the obvious answer: dist is
all-or-nothing, so a node that can reach another can call any function in it, and
handing that to the process parsing internet packets gives back most of what the
two-role split is for.

### Describing your transform fields

`ASOBI_DGRAM_POSE_FIELDS` has no default and the plane stays off without it.
Guessing `x` and `y` at some scale would silently pick a precision for a world
that might be a thousand times larger.

```
ASOBI_DGRAM_POSE_FIELDS: "x:100,y:100,vx:100,vy:100"
```

Name and scale, in canonical order. **At most eight fields** - the per-record
bitmask is one byte - and a ninth disables the plane rather than dropping a field
silently. The order is load-bearing: the wire carries no field names, so
reordering this changes what every field on the wire means.

`scale` converts to the `int16` the wire carries. `100` gives two decimal places
and a range of about +/-327 world units. A bigger world needs a smaller scale and
coarser steps, which is a trade only your game can make. A value outside the
range **saturates and is counted**, never wraps: wrapping would teleport an
entity across the world, which reads as a game bug, where saturation reads as
what it is.

`ASOBI_DGRAM_POSE_PERIOD` (default 20) is the axial refresh in ticks.

Full variable list in [Configuration](configuration.md#the-datagram-gateway-role).

## Client setup

Clients opt in per SDK. Nothing else about your game changes: entity callbacks
fire exactly as before and `world.tick` keeps carrying everything else.

### Godot

```gdscript
Asobi.realtime.entities = AsobiEntities.new()
Asobi.realtime.request_datagram = true

Asobi.realtime.entities.entity_updated.connect(func(id, state, changed):
    if "x" in changed:
        move_sprite(id, state.x, state.y))

Asobi.realtime.connect_to_server()
```

`AsobiEntities` is required, and that is not incidental. Two carriers describe
the same entity and they can disagree, so something has to hold the merge rule:
which `world.tick` field loses to a fresher position, which wins regardless, and
which frame may never create an entity at all. Putting that in a registry the SDK
owns is the difference between an API and a subtle correctness problem handed to
every game. It is useful on its own too - bind it without the plane and it folds
`world.tick` into a per-zone entity view with the crossing and keyframe rules
already handled.

### Defold and LOVE

```lua
client.realtime.request_datagram = true
client.realtime:connect()
```

Both SDKs already keep an entity registry, so the merge happens where it always
did and your `entity_updated` handlers are unchanged.

### SDK support

| SDK | Binary `world.tick` | Datagram plane |
|---|---|---|
| Godot | yes | yes |
| Defold | yes | yes |
| LOVE | yes | yes |
| Dart | yes | not yet |
| Unity | yes | not yet |
| Unreal | yes | not yet |
| JS | n/a | never |

The JS SDK has no world-mode WebSocket surface, and browsers have no raw UDP in
any case, so a web export is permanently on the WebSocket. That is an asymmetry
rather than a wound: see below.

## When it does not work, nothing breaks

This is the design's whole safety property, and the reason it is safe to switch
on before you have tested every player's network.

| Situation | What happens |
|---|---|
| Server has no gateway | The mint answers `datagram_unavailable`. The client stays on the WebSocket. |
| A firewall drops UDP | Three probes over three seconds, then the client gives up to `off`. |
| The path goes quiet for 2s | `degraded`: positions come from `world.tick` again while the client re-probes in the background. |
| The WebSocket reconnects | Back to `off`, and a fresh mint. A credential is bound to a session. |
| A web export | Never opens the plane at all. |

**The WebSocket carries everything in every state.** There is no state in which
correctness depends on this plane.

The client keepalive is not optional and cannot be moved to the server: with a
NAT anywhere in the path a quiet client loses its mapping and the downlink is
blackholed with no signal at all, and only a client-originated packet recreates
it.

## Checking it works

```
asobi.dgram.link_up          the engine attached to the gateway
asobi.dgram.canary_missed    consecutive >= 2 means the receive loop is wedged
asobi.dgram.dropped          gate=mac is the one to wake up for
asobi.dgram.pose_saturated   your scale is wrong for your world size
```

The gateway proves itself by sending itself a real datagram every five seconds
and waiting for the reply, so a wedged receive loop fails readiness where a
port-bound check would not. It does **not** prove every shard: the kernel chooses
which one receives the probe, so a healthy canary means at least one is alive. A
single wedged shard shows up as a fraction of players timing out, and
`asobi.dgram.recv_failed` plus client-side telemetry is where to catch that.

Full event list in [Observability](observability.md).

## The managed cloud does not have this

[asobi cloud](cloud.md) is WebSocket-only and will stay that way until its
network topology changes: Hetzner load balancers forward tcp/http/https only, and
the ingress masquerades the client address, so a datagram plane cannot be exposed
there at all.

Self-host and cloud diverge on transport for the first time. Stated here rather
than left for a reader to discover.

## Further reading

- [Configuration](configuration.md#the-datagram-gateway-role) - every variable.
- [Self-hosting](self-hosting.md#adding-the-datagram-plane) - the compose file in
  context.
- [WebSocket protocol](websocket-protocol.md#binary-worldtick) - the binary
  `world.tick` encoding, which the plane depends on for its slot bindings.
- ADR 0012 and ADR 0013 in `docs/adr/` - the protocol design, why it was
  rejected, and why it was reopened.
