# ADR 0012: The datagram plane protocol, designed, rejected, then superseded

Date: 2026-08-16

## Status

**Superseded by ADR 0013** (2026-08-17), which accepts the protocol below in its
single-node self-hostable form. Read 0013 first: it records what changed, which
was the basis of the decision rather than the measurements, and it narrows the
scope. The fleet deployment half remains rejected in `asobi_saas` ADR 0013.

The original ruling, kept because the reasoning is still the best account of why
this is hard, and because 0013 reverses it on strategy rather than on evidence:

**Rejected.** Not gated, not deferred: closed. Nothing here shipped and nothing here
is scheduled. Recorded rather than discarded because a rejection carrying its
reasoning is worth more than an absent document: without it, the next person to
think a datagram transport is obviously a good idea starts from scratch, and the
three measurements that closed it would have to be rediscovered.

**Why rejected, and it is not the design.** The protocol below survived architectural
review. What failed is the evidence base: three successive attempts to build a gate that
could authorise this work failed on arithmetic rather than on effort.

The killing measurement is scale. The fleet runs at roughly **0.6 mean concurrent
connections per environment** across four environments. The unit of independent evidence
for a transport question is the distinct network path; the exact one-sided binomial tails
put the floor for a sign test at ten simultaneous distinct paths, and a p99 on a heavy
tail needs an effective sample of about 6465 per arm where a 24-hour experiment plausibly
yields 1440. At this scale the only honest instrument available **can close this stage but
can never open it**. Every gate design produced, and all three independent judges, agreed
on that point.

Each gate also failed on its own terms. The first made `p99 > 3x p50` the trigger, a ratio
that is identically 1.98 at `broadcast_interval` 3 and at 1 - scale-invariant to the
one-line config change it was meant to detect, and decreasing in base path RTT, so it
pointed away from the players a datagram plane would help. The second named statistics no
instrument emitted, and a condition (`[asobi, zone, tick_skipped]` at zero for 14 days)
that can never hold. The third rested on a per-server egress threshold whose own formula
returns exactly EUR 0 of saving at its trip point, and on a precondition reading a
connection gauge that drifts permanently negative.

**What would reopen this.** Not a measurement, because none is available at this scale. A
business event: a paying tenant reporting latency that investigation attributes to
transport rather than to tick cadence, server overrun or client prediction; or a fleet
large enough that ten simultaneous distinct network paths exist in one environment, at
which point a sign test becomes possible and the question can be asked properly for the
first time. Both are judgements a person makes, not thresholds a pipeline crosses.
Reopening means a new ADR superseding this one, not an amendment to it.

**What is kept.** The protocol design below, in full. If the question is reopened the work
starts from a reviewed design rather than a blank page, and the reasons it was closed are
on the record to be argued against.

**Scope: the protocol only, and only in its single-node form.** `asobi_dgram_gw` is
specified here as a single-node, self-hostable OTP release: one gateway process tree, one
UDP port, one internal channel to one engine, one binding table. A self-hoster runs it
beside the engine on one box and opens one port. Nothing here may assume a multi-tenant
control plane, a per-environment fan-out, or any particular network fabric; asobi is a
single-node library by design and importing a deployment model into it is the mistake ADR
0006 exists to prevent in the other direction. The fleet deployment of the same release is
a separate decision, recorded by whoever operates the fleet.

## Context

`world.tick` cannot travel on a lossy carrier, in any design. It is an op-delta against a
baseline that advances unconditionally on send (`src/world/asobi_zone.erl:622-628`,
`:748`, `:750-762`), so a dropped frame corrupts the client's view permanently. Whatever a
datagram plane carries, it is not that frame.

That leaves one thing worth moving: absolute per-record transform state, which is
self-contained per record, framework-defined every byte, and harmless to lose because the
next one supersedes it. Everything with authority - auth, inventory, economy, chat, match
results, and every frame in the existing corpus - stays on the TLS WebSocket.

Two constraints shape the rest. First, the observed source address of a datagram is not an
identity: any NAT, proxy or load balancer between the client and the gateway may rewrite
it, and a kernel-assigned mapping is expirable and reusable. A design that binds a
connection to an observed address is not portable and is not safe. Second, server CPU
justifies nothing here: measured, the whole delta-compute plus encode step is about 50 us
per zone per broadcast tick against a 50 ms budget, and datagram fan-out costs 4-5x the
TCP fan-out asobi does today *per message*. The only live arguments are latency,
head-of-line blocking and correctness, and only the first is unmeasured.

## Decision

**Design the plane in full; build nothing until the gate opens.** The protocol below is
the record.

**1. What it carries, and what it never carries.** Exactly two payload frames plus six
control frames.

- Down, `pose`: absolute per-record transform state. Binary only, never a JSON envelope,
  never on the WebSocket.
- Up, `world.input`: the existing frozen frame's payload bytes on a different carrier,
  with the existing optional `seq` promoted to a mandatory `cseq`. It lands on the
  identical `asobi_zone:player_input/4` call the WebSocket handler makes
  (`asobi_zone.erl:59-60`, exported at `:11`).
- Control: `hello`, `hello_ok`, `hello_confirm`, `bye`, `ping`, `pong`. No WebSocket
  counterpart.

Never on this plane: `world.tick` (unsafe under loss by construction); `match.state` (the
game's arbitrary map, nothing to quantise, `src/matches/asobi_match_server.erl:850-859`);
`world.terrain` and the join snapshot (structurally too large for a datagram in any
encoding); `world.resync` (an amplifier even in its one-zone form); and everything with
authority. The selection rule is written policy, not taste: this plane carries only frames
the framework, not the game, defines every byte of, and only frames that are self-contained
per record.

**2. There is no fragmentation.** `MAX_DATAGRAM` is 1100 bytes. When the record set for a
tick exceeds it, the zone emits multiple independent datagrams in the same tick: same
`tick`, distinct consecutive `bseq`, disjoint record subsets, each individually applicable.
No reassembly buffer, no timer, no partial-frame state, no head-of-line coupling. A
reassembly buffer is a memory-exhaustion surface that this design simply does not have.

**3. Byte layout.** A 16-byte per-subscriber prefix (`magic` 0xA5, `version`, `opcode`,
`flags` with reserved bits that MUST be zero, `conn_id` uint32be, `path_tag` uint64be which
MUST be 0 on every uplink), then a 16-byte shared body header (`tick` uint32be as the
ordering authority, `bseq` uint32be as the per-zone loss metric, `zone_x`/`zone_y` int16be,
`fieldmask`, `count`, `epoch` uint16be), then records of 4 to 20 bytes (`slot` uint16be
zone-scoped, `gen`, `rmask`, then int16be fields in canonical bit order). Fixed overhead is
32 bytes, giving 133 records with `x,y` or 89 with `x,y,vx,vy`.

`zone_x`/`zone_y` are in the body header and are not optional: a compact per-zone slot
index is meaningless without the zone, and a player is subscribed to a whole interest ring,
so without it every compact-index scheme corrupts continuously with zero packet loss.

Scales, the field manifest and each extra field's range are delivered **once**, over TLS,
in the mint response, so the decoder is a fixed layout rather than self-describing. A value
outside its declared range is **saturated with a telemetry counter**, never wrapped. int16
rather than float32 because it halves every field and decodes in Lua 5.1 with two
multiplies.

**4. `conn_id` plus MAC is the identity. The observed address is a return-path handle.**
`conn_id` is cleartext bytes 4-7 of every datagram and is the sole demux key; uplink routing
never consults the observed address. A reverse-lookup table from handle to `{conn_id, epoch}`
exists for the sender only, is populated **only** by a completed challenge exchange and never
by observation, and is deleted synchronously on teardown, so a client that inherits a dead
client's handle cannot inherit its downlink.

**`conn_id` is not a secret.** It is on the wire in cleartext, visible to any on-path
observer, and it will end up in logs and metric labels. No guarantee may be stated as
though it never leaves TLS.

**5. The credential is a registered binding, not a token.** Mint is `rpc.call` with method
`asobi.datagram.open` over the already-authenticated WebSocket - `rpc.call` / `rpc.ok` /
`rpc.error` are already frozen and already implemented in every SDK, so the plane adds
**zero** frame types to the JSON wire. The engine generates `conn_id` and a 32-byte `KUp`
with `crypto:strong_rand_bytes/1`, registers `{conn_id, KUp, player_id, session_pid,
expires_at}` with the gateway and waits for the ack, then replies with `conn_id`, `kup`,
`endpoint`, the scales, the field manifest and the pose interval. `KUp` travels exactly
once, inside TLS, and never on the datagram plane; every uplink datagram including the first
`hello` is authenticated under it, so there is no key exchange in the datagram protocol at
all. A registered binding gives instant revocation on session death, which a signed token
structurally cannot.

`endpoint` in the mint response is what makes the plane independent of DNS and of SNI, and
is why a non-standard port costs the client nothing.

**6. Two-phase binding, and the precise claim it supports.** `hello` (MAC-valid, `conn_id`
known, `cseq` advancing) moves the connection to `pending`; the server replies `hello_ok`
with a 64-bit random challenge **to the candidate handle only** and sends no state frames;
`hello_confirm` echoing the challenge from the same handle moves it to `bound`. A `hello`
from a different handle is a **hint, never an authority**: a new challenge is minted to the
new handle and the downlink stays on the old one until the echo returns.

The claim, stated so nobody later reads more into it: **the challenge proves that the sender
can receive at whatever the return-path handle currently resolves to.** That is return
routability, which is exactly the anti-reflection property this plane needs. It is **not**
proof of a client address, and no part of the design may treat it as one. `cseq` strictly
advances and is covered by the MAC; it is the only thing stopping a captured `hello_confirm`
being replayed from another handle, so it is load-bearing, and it is checked before the
rebind path is entered.

**7. Rebind is asserted by the client, never inferred by the server.** Through a rewriting
middlebox the server cannot see a path change, and the inference fails in both directions -
the client's address can change with the handle unchanged, and a quiet client's handle can
change with nothing else changing. So: no pose for 2 s, including heartbeats, makes the
client re-send `hello` on the same `conn_id` with an advancing `cseq`, and the server always
re-runs the challenge. Bounded by a limiter at 3 rebinds per 60 s per connection, then
teardown. The cost is up to about 2 s of stale pose after a path change, which is degradation
rather than loss because the WebSocket carries everything throughout.

**8. The client keepalive is a hard requirement.** With a NAT anywhere in the path a quiet
client loses its mapping and the downlink is blackholed with no signal, and server heartbeats
cannot fix it - only a client-originated packet recreates the mapping. `ping` is therefore
client-originated at an interval strictly below the smallest mapping timeout on the path.
Until an operator measures that timeout the constant is 10 s, one third of the common 30 s
unreplied default, costing about 35 bit/s per connection.

**9. No rate-limit tier is keyed on an observed source address.** Bare-IP keying starves
every player behind a carrier-grade NAT, and `(IP, port)` keying is worse behind a masquerade:
the IP collapses to one value while the port is attacker-chosen, minting tens of thousands of
free keys. Every tier is keyed in a server-issued namespace - a constant, or `conn_id`:

| Tier | Key | Bounds |
|---|---|---|
| parse guard | none | magic, version, reserved bits, minimum length. Pure arithmetic on the first four bytes. |
| ingress global | a constant | total datagrams looked at. The primary volumetric defence, because it is the only key an attacker cannot rotate. |
| unknown conn | a constant | datagrams whose `conn_id` misses the table; bounds log and telemetry volume, not CPU. |
| ingress | `conn_id` | pre-MAC work per live connection. Key space bounded by live sessions. |
| input | `conn_id` | post-MAC input rate. |
| rebind | `conn_id` | challenge mints per connection, then teardown. |

The ordering is the guarantee: MAC verification, the only expensive step, is reachable only
by a datagram that passed the parse guard, fitted the global budget, carried a live `conn_id`
and fitted that connection's own pre-MAC budget. This is the codebase's own doctrine, stated
verbatim at `src/asobi_sup.erl:265-268` and `:271-272`. If a deployment is ever verified to
preserve the real client address, an address tier may be added as defence in depth, but it may
never become load-bearing: a limiter whose correctness depends on a network topology fails
silently when the topology moves.

**10. The amplification invariant, enforced as a CI assertion over the frame table rather than
as prose:** *every server reply is smaller than or equal to the request that caused it, and no
unauthenticated or malformed datagram receives any reply at all.* `hello` is 36 bytes and
`hello_ok` is 48, so `hello` is **padded by the client to at least 64 bytes** and the gateway
drops a short `hello` before doing MAC work. `ping` 44 -> `pong` 40 passes. `hello_confirm`
gets no reply. The gateway emits no error datagram of any kind: every rejection is a silent
drop plus a counter.

**11. The downlink is unauthenticated. It carries no MAC and no encryption.** `path_tag` is a
bearer cookie, not integrity. The uplink is fully authenticated per datagram under `KUp`. A
shared-key MAC is not a security control at all, since every subscriber holds the key and could
forge to every other subscriber; a per-client-key MAC was measured at +46% CPU per subscriber
*and* destroys the shareable wire bytes, which is the one reversal of ADR 0001 this design
refuses. Priced honestly: an attacker needs `conn_id` **and** `path_tag` **and** the ability to
deliver to the victim's current handle, and `path_tag` never appears in the mint response. With
all three they can make one client's *render* of other entities wrong for at most one pose
interval, after which the rolling resync overwrites it. They cannot affect the server, any other
player, the authoritative simulation, entity creation or removal, or any state-class field.

The label, verbatim in the guide as well as here: *the datagram plane provides off-path forgery
resistance and no confidentiality or on-path integrity. Everything with authority travels only
on the TLS WebSocket.*

**12. The merge rule.** Per entity the client keeps `t_pose` (last `tick` whose transform fields
were applied) and `t_state` (last `tick` whose non-transform fields were applied). A field is
transform-class if and only if the manifest says so.

- `world.tick` `op:"a"`: create or replace wholesale, install the slot mapping, **always wins**.
- `world.tick` `op:"r"`: delete, **always wins**, but only if `gen` matches - `compute_deltas/2`
  returns `Updates ++ Removed` (`asobi_zone.erl:748`), so an `op:"a"` reusing a freed slot always
  precedes the `op:"r"` that released it within one frame.
- `world.tick` `op:"u"`: apply all state-class fields unconditionally (`world.tick` is their only
  carrier and it is reliable and ordered); apply transform-class fields only if `tick > t_pose`.
- `pose` record: resolve `(zone, slot)`; a missing mapping, gen mismatch or epoch mismatch drops
  the record. Apply only if `tick > t_pose`. It can **never** create or remove an entity and
  structurally cannot touch a state-class field.

**A keyframe must not rewind the pose clock.** The join and resync keyframes carry `tick: 0`
(`asobi_zone.erl:541`), so a rule that sets `t_pose := tick` on every `op:"a"` would let a stale
in-flight pose datagram apply over fresher state for one interval on every subscribe. On a
`kf: true` frame the client sets `t_state := tick` and `t_pose := max(t_pose, tick)`. This is
stated here rather than in the sequenced-wire ADR because it is a property of the two-carrier
merge and costs stage 1 nothing.

Entities at rest are covered by axial frame synchronisation: at each pose tick, additionally
include every entity where `slot rem TicksPerPeriod =:= TickN rem TicksPerPeriod`. At 20 Hz with
a 1 s period that force-includes one twentieth of the zone per tick, at zero per-client state,
zero acks and zero extra encodes - the only canonical loss-repair scheme compatible with a single
shared baseline and a single shared encode.

**13. Fallback ships in the same phase, never after, with a hard timeout.** Client states are
`off -> minting -> probing -> active -> degraded -> off`. `probing` retries `hello` at 200 / 400 /
800 ms and gives up to `off` after 3 s. `degraded` (no pose for 2 s) resumes applying `world.tick`
transform fields unconditionally and re-sends `hello`. Any WebSocket reconnect returns to `off`.
**The WebSocket carries everything in every state; there is no state in which correctness depends
on the datagram plane.** That is what makes a browser's permanent exclusion an asymmetry rather
than a wound, and what makes an SDK never shipping the carrier a legitimate permanent end state.

**14. Process shape.** A separate release and image: `asobi_dgram_gw_sup` (one_for_one) over a
table owner, a receiver per `SO_REUSEPORT` shard, a sender owning the send socket, one upstream
channel process, a reaper, a canary and a limiter. Pure modules for the codec and the slot
allocator, unit-tested with no process. Shard count is fixed at boot: adding or removing a socket
reshuffles the hash and breaks every existing flow, so runtime rescaling is not possible. Send uses
`socket:sendmmsg/4` with a two-element iovec, `[Prefix, SharedBody]`, which is what preserves ADR
0001 - the shared body is referenced, never copied per subscriber. Readiness completes a real
datagram loopback exchange against itself on a timer and fails after two misses; a port-bound check
would not catch a wedged receive loop. Readiness stays local: it must not depend on the public
internet, or a transient upstream fault restarts a healthy process.

The engine never binds a UDP port, never parses a hostile packet, and never needs a client's source
address. It hands the gateway one shared body plus a list of `conn_id`s.

## Consequences

- **ADR 0001 needs one clarifying amendment if and only if this is ever built**, not a reversal.
  Proposed wording: *"Encode-once is a property of the state-production path: one `get_state` and
  one `json:encode` per tick per zone or match, regardless of subscriber count. It has never been a
  claim about the send term, which has always been O(N). On a datagram plane the per-subscriber send
  term is roughly four times more expensive, so the discipline's measured leverage falls, but the
  discipline holds and the shared binary is still shared, delivered as the second element of a
  two-element iovec."* The two things that would genuinely reverse ADR 0001 - per-client baselines
  and a per-client-key MAC on the fan-out - are both refused above.
- **ADR 0010 is not engaged.** `pose` is not a JSON envelope frame and never travels on the
  WebSocket, so it sits below the frozen wire. Mint reuses the already-frozen `rpc.call` /
  `rpc.ok` / `rpc.error`. No frame type is added to the corpus in either direction.
- **The gateway is a second release to build, sign, ship and patch**, with its own image and its own
  upgrade path, for a plane that is optional in every state. That cost is real and is the main
  argument against ever opening this gate.
- **Every constant here is provisional until measured.** The 1100-byte budget depends on a path MTU
  nobody has measured through a real deployment; the 10 s keepalive depends on a connection-tracking
  timeout nobody has measured; the fan-out ratios are loopback figures. None of these may be inferred
  at build time.
- **The plane puts a shared kernel connection-tracking table in the blast radius of an
  unauthenticated flood**, because each distinct spoofed 4-tuple costs an entry upstream of the
  process. No in-process limiter can defend it. An operator running this must measure the table
  ceiling and alert well below it; removing tracking from the path is possible only with host
  networking, which is an operator decision with its own trade-offs and is out of scope here.
- **Two SDKs are the minimum counterparty**, and both must ship the fallback state machine in the
  same phase as the carrier. Browsers are permanently excluded from raw UDP, so a web export is
  always `off`.
- **The wire is the asset; the carrier is replaceable.** Everything above is carrier-agnostic bytes
  with its own sequence space, so it moves onto QUIC or WebTransport datagrams unchanged if that
  becomes the better carrier.

## Alternatives considered

- **QUIC or WebTransport instead of raw UDP.** Not closed, and re-evaluated against this design at
  the gate. Today `quicer` is Preview at 0.4.8 with no OTP 29 coverage in its CI while asobi is OTP
  29.0.2, and it wraps a large memory-unsafe C parser facing hostile internet packets. Both objections
  are dated facts rather than principles, and the browser objection has already expired - Safari
  shipped WebTransport datagrams in March 2026. WebTransport also keeps SNI, which raw UDP loses and
  which this design works around with `endpoint` in the mint response.
- **OTP DTLS as the carrier.** Rejected: DTLS 1.2 only, measured at 2.75x plain UDP per packet, and
  its receive side is one process per listening socket with no reuseport hook.
- **A signed connect token on the datagram wire.** Rejected while mint and verify sit on the same
  machine: a registered binding revokes instantly on session death, which a token cannot. The token
  shape is recorded so the option exists if the two are ever separated.
- **Binding the connection to the client's source address.** Rejected: not portable, not
  authenticated, kernel-assigned, expirable and reusable. The design is address-independent by
  construction and any address-derived defence is defence in depth only.
- **Fragmentation with a reassembly window.** Rejected: a memory-exhaustion surface with no
  compensating benefit when records are individually applicable.
- **Putting the socket in the engine.** Rejected: hostile internet packets would reach the process
  tree holding the Lua sandbox and the tenant database credentials. The gateway costs one internal
  hop and is worth it.
- **A per-connection MAC on the downlink.** Rejected; see decision 11. The reduction is stated in the
  open rather than left implied.
