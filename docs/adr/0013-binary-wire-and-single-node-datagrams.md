# ADR 0013: A binary wire, and datagrams in their single-node form

Date: 2026-08-17

## Status

**Accepted.** Supersedes ADR 0012, which rejected the datagram plane outright.

Reversing a decision taken the same day deserves an explicit account of what
changed, because most of the evidence did not.

**What did not change.** The measurement that closed ADR 0012 still holds: the
managed fleet runs at roughly 0.6 mean concurrent connections per environment
across four environments, ten simultaneous distinct network paths remains the
binomial floor for a sign test, and no instrument readable on that fleet can
*open* a latency question. Three gate designs failed on arithmetic and a fourth
would fail the same way. Nothing here claims otherwise.

**What changed is the basis of the decision, not the data.** Two things:

1. **A named user needs it.** A self-hoster is building an MMO on asobi. ADR 0012
   named exactly this as its reopening condition - "a business event, not a
   measurement" - and the condition has fired. This is the case the fleet numbers
   could never have surfaced, because a single self-hosted world plausibly carries
   more concurrent connections in one place than the entire managed fleet.
2. **A strategic bet, made deliberately and recorded as one.** No backend in this
   category ships a production UDP game-state transport: Nakama advertises
   reliable UDP and ships one WebSocket implementation, Colyseus's `sendDatagram`
   has no caller, SpacetimeDB is WebSocket-only. ADR 0012 read that as evidence
   asobi is not behind. This ADR reads the same fact as room to be ahead. That is
   a positioning judgement rather than a measured one, and it is the owner's to
   make. Worth recording honestly: nobody charges extra for UDP anywhere, so the
   revenue case is unproven.

**One thing changed measurably, and it is why the codec goes first.** Gate 11.4 -
the Godot decode benchmark that blocked the binary codec outright - was run and
closed in favour, by a wider margin than the design expected. See Decision 1.

**Scope is narrower than what ADR 0012 proposed.** The datagram plane is accepted
in its **single-node, self-hostable form only**. The fleet deployment stays
rejected: `asobi_saas` ADR 0013 is unchanged, because Hetzner load balancers
forward tcp/http/https only and klipper-lb masquerades the client address. So
self-hosters get datagrams; the managed cloud does not, until that topology
changes. Any public claim about asobi and UDP has to say so.

## Context

`world.tick` cannot travel on a lossy carrier as JSON, for two independent
reasons established in the transport investigation (research notes 01-17).

It does not fit. A 400-entity zone at 10% churn is 3883-5923 bytes of JSON
depending on float precision, against a 1200-byte safe MTU floor. At most 12
changed entities fit one datagram. The same delta in a fixed-layout binary is
1049 bytes with 16-byte ids and 489 with connection-local ones. **A binary
encoding is not an optimisation on this path, it is what makes single-datagram
delivery possible at all.**

And its ops are not idempotent under loss. That half is already fixed: ADR 0011
shipped `zone`, `frame_seq` and `kf` plus inbound `world.resync`, so loss is
detectable and repairable, and per-zone application closed a corruption path that
needed no packet loss to reproduce. That work was the prerequisite and it is done.

## Decision

**1. Build the binary codec first, and make it the wire for every SDK.**

It runs on the existing WebSocket: no new port, no deployment change, no auth
work, and every SDK including browsers can use it. It therefore delivers value
whether or not the datagram plane follows, and it is mandatory before any
datagram carries a zone delta.

Gate 11.4 asked whether a byte-loop decoder in interpreted GDScript could beat a
native JSON parser. Measured, 40 records, decoding to the same array-of-maps
structure both ways, with faithful 36-char UUIDv7 ids in the JSON:

| Runtime | binary | JSON | result |
|---|---|---|---|
| Godot 4, GDScript, `PackedByteArray.decode_*` | 23.4-26.1 us | 55.8-63.5 us | binary **2.4x faster** |
| Lua 5.4, `string.unpack` vs the SDK's own pure-Lua parser | 13.5-14.2 us | 438.8-490.4 us | binary **33x faster** |

Bytes on the benchmark's own frame: 807 against 3856, so 4.8x smaller. Three
runs each, stable.

**That 4.8x is not the shipped ratio, and this is the correction rather than the
number to quote.** The benchmark frame carried `x, y` per record; a real steady
state carries `x, y, vx, vy`, which doubles the binary side and barely moves the
JSON side. The wire has also since gained a `gen` byte per record for the
datagram plane's merge rule (decision 6). Measured against shipped `main`, with
36-char UUIDv7 ids in the JSON throughout:

| Frame | JSON | binary | smaller by |
|---|---|---|---|
| 1 update | 192 | 64 | 3.0x |
| 10 updates | 1019 | 289 | 3.5x |
| **40 updates (the steady state)** | **3795** | **1039** | **3.7x** |
| 400 updates | 37790 | 10039 | 3.8x |
| 40 adds (a keyframe) | 3795 | 2519 | 1.5x |
| 40 records as a `pose` datagram | 3795 | 512 | 7.4x |

Three things that table says and the single figure did not.

The ratio *settles* around 3.7x from roughly ten entities up. Below that the
26-byte frame header dominates, so a one-entity frame is only 3.0x.

**Keyframes get 1.5x and that is by design, not a shortfall.** An `add` carries
the full 36-character id because that is where the slot binding is established;
updates and removes carry two bytes of slot instead. Sending ids as text costs 20
bytes per add and buys a client an id byte-identical to the one
`session.connected` gave it. Keyframes are rare - join and resync - and updates
are every tick, so the wire is optimised for the frequent case and pays on the
rare one.

**The `pose` datagram is where the bytes actually matter**, at 7.4x, because it
drops everything a delta needs: no field names, no ids, no dictionary, just slot,
generation, mask and four int16s at twelve bytes an entity. That is what puts 400
entities inside one 1200-byte datagram (1100 bytes) where the same set as JSON is
37 KB. Decision 3's whole case rests on that number and not on this one.

**None of which is why the codec ships.** Bandwidth is the argument for the
datagram plane, where fitting one MTU is pass or fail. The WebSocket codec is
justified on the decode figures above and nothing else.

The design's fear was true but irrelevant at this frame size: `decode_u16` and
`decode_float` are themselves native calls, the loop is 40 iterations, and the
JSON parser has to chew 3856 bytes including 40 UUID strings and 160 float
literals. Text parsing loses on volume before interpretation overhead matters.

The Lua figure is the honest comparator rather than a flattering one: stock Lua
has no native JSON, so Defold and LOVE ship a **pure-Lua parser**, and that is
what a real client runs.

This also corrects something ADR 0012 asserted. It said CPU could not justify the
codec, measuring encode on the **server** at ~50 us per zone per broadcast tick
against a 50 ms budget. That is true and remains true. It is the wrong side of
the wire: a Defold client currently spends ~440 us per frame parsing JSON, which
at 20 Hz is close to 1% of a mobile CPU doing nothing but text parsing. **The
codec is justified on client cost, not server cost.**

So the codec is fleet-wide rather than a per-SDK negotiation. No SDK needs to
stay on JSON for decode reasons, and the two whose runtimes looked weakest are
the two with the largest wins.

**2. Negotiate it, do not impose it.** The frozen 1.0 wire stays the default and
stays supported. A client opts in at `session.connect`; a client that does not ask
sees no change. Seven SDKs are consumed by copying source, three with no version
pin, so a shipped game must keep working untouched.

**3. Datagrams in the single-node form only.** One gateway process tree, one UDP
port, one internal channel to one engine, one binding table. A self-hoster runs it
beside the engine on one box and opens one port. Nothing in asobi may assume a
multi-tenant control plane, a per-environment fan-out, or any particular network
fabric; the fleet shape is `asobi_saas`'s decision and it currently says no.

**4. Entity ids on the binary wire are 2-byte slots, scoped to a ZONE.**

A raw 16-byte UUID costs 34 bytes per record; a 2-byte slot costs 20. That is
about 40% off a delta frame, and it changes the outcome in exactly one band -
400 entities at 10% churn is 1385 bytes with UUIDs, so 1.2x the MTU and
fragmenting, against 825 with slots, which fits one datagram. That band is the
plausible steady state for the MMO this ADR reopens the question for.

**Zone-scoped, and the scope is the load-bearing part.** A per-connection id
space would mean different bytes for every subscriber, which destroys ADR 0001's
encode-once fan-out - the whole point of building one buffer per zone per tick.
Scoping slots to the zone keeps one buffer, because the mapping is a property of
the zone rather than of who is listening. It also composes with ADR 0011 rather
than fighting it: clients already keep a table per zone, so that table is now
keyed by slot instead of by UUID, and slot 5 in one zone being unrelated to slot
5 in another is expected rather than surprising.

**The binding rides the `add`, so there is no mapping message.** An `op:"a"`
record carries slot AND the full entity id; `op:"u"` and `op:"r"` carry only the
slot. An add is the only op that introduces an entity, so it is the natural place
for the binding, and a client can always recover the real id when it needs to
correlate - its own player, say.

**Resync re-establishes every binding for free.** A keyframe is all-adds by
construction (ADR 0011, decision 3), so a client that has lost the mapping asks
for the resync it would ask for anyway and gets the whole zone's bindings back.
No new mechanism, no separate mapping state to keep in sync.

**Reuse is safe, and the reasoning matters more than the rule.** A freed slot
being reused is the classic ABA hazard: miss the `remove` for entity X on slot 5,
then apply an `update` meant for entity Y to X. It does not bite here, because a
new entity always enters via an `add`, and an `add` carries the id and REPLACES
the client's binding. The only sequence that corrupts is missing both the remove
of X and the add of Y and then receiving an update - and that is a gap, which
`frame_seq` detects and `world.resync` repairs. So the existing detector bounds
the hazard and no generation counter is needed. Slots are allocated
monotonically with wraparound so that reuse is as distant as the space allows.

**Exhaustion fails loudly.** 65536 concurrently-live entities in a single zone is
far outside any sane grid config (the default is 10x10 cells of 200 units), so the
allocator logs and refuses rather than wrapping into live slots. Silently
rebinding an in-use slot would be undetectable corruption; a loud failure is a
capacity conversation.

**Cost to ADR 0001, stated honestly.** Negotiation means a zone can have both JSON
and binary subscribers, and it must then produce two buffers per broadcast instead
of one. That is 2 encodes per zone per tick, not N - the fan-out is still one
shared buffer per wire. ADR 0001's property is preserved in substance; its literal
"one encode" becomes "one encode per wire in use".

**5. Both buffers travel in ONE message, and falling back to text is always
allowed.**

Three consequences of decision 4 that only surface when it is built.

*The zone does not track who negotiated what.* A broadcast puts both buffers in
a single message and the connection picks. The alternative - per-subscriber wire
state in the zone - buys one skipped encode and costs a race between negotiation
and subscription, plus a wire preference threaded through `asobi_world_server`'s
join and reconnect paths. The dual encode is gated on `asobi.binary_wire`
instead, off by default, so a deployment with no binary clients pays nothing and
one with any pays the two encodes decision 4 already accounted for.

*A frame the encoder cannot produce is sent as text, never dropped or mangled.*
Negotiating binary covers `world.tick` alone - `world.ack`, `match.*`,
`world.terrain` and every error are text on both wires - so a binary client is
by construction one that still handles text, and the fallback costs bandwidth
rather than correctness. It fires on slot exhaustion, on a dictionary past 32
names, and on an entity field with no binary form. That last case is a whole-zone
decision on purpose: dropping a list-valued field from the binary frame while the
text frame keeps it would make the two wires disagree about what an entity IS,
which is a worse failure than not using the binary wire.

*The wire is little-endian, not network byte order.* Godot's
`PackedByteArray.decode_*` reads little-endian and ships no big-endian
counterpart, so big-endian would force a hand-rolled byte loop in interpreted
GDScript - and those native calls are the entire reason decision 1's benchmark
came out 2.4x in favour rather than against. Every other target reads either
order for the same price. Found by running the Godot decoder against the fixture
corpus, which is the case for building the corpus first.

*Each record carries a generation byte, for a plane that does not exist yet.* The
reuse argument above is sound on this wire and does NOT carry to the datagram
plane, where loss is real and records have no per-entity ordering to gap-detect
against: ADR 0012's merge rule needs a generation to tell the entity holding slot
5 now from the one that held it a moment ago. That generation has to come from
somewhere, and the only carrier that introduces an entity is the `add` on this
wire. Two slot tables that could disagree is exactly the class of defect ADR 0011
existed to close, so there is one table, and one byte per record is what buys it.
Decided while both wires were unmerged, because the same change after the codec
ships is a wire that moves under shipped games.

*The frame header carries a kind byte.* The text wire says "this frame holds no
position in the zone's sequence" by omitting `frame_seq`, which a fixed-layout
binary frame cannot do. Encoding the leave-removal frame as sequence 0 instead
would have every client past its first frame discard the one message that clears
its ghosts, so the distinction moves into the header: kind 1 sequenced, kind 2
ungated.

**6. The protocol design is otherwise inherited, not redone.** ADR 0012's protocol survived
architectural review; only its authorisation failed. Frame layout, the two-phase
challenge binding, `conn_id` as the sole demux key, the no-fragmentation rule, the
amplification invariant and the downlink-authenticity decision carry over as
written.

Two amendments, both recorded here rather than edited into the superseded
document.

*The datagram wire is little-endian, where ADR 0012 wrote `uint32be`.* The same
six SDK decoders read this plane and the WebSocket binary wire, and that wire is
little-endian because Godot's byte readers have no big-endian counterpart
(decision 5). One carrier in each byte order is a trap nobody would thank us for,
and network byte order buys nothing here: there is no intermediary that reads
these bytes.

*The amplification invariant is asserted over a reply table in code, not stated
in prose.* ADR 0012 asked for exactly this and its own worked example did not
hold - it paired a 36-byte `hello` with a 48-byte `hello_ok` and then patched it
with padding. The table now lives in `asobi_dgram_tests`, every uplink opcode must
appear in it, and adding an opcode without deciding what it answers fails the
build. The sizes came out with room to spare: padded `hello` 64 against
`hello_ok` 24, `ping` 48 against `pong` 32.

## Consequences

**The prerequisite chain is real and unchanged.** The codec is 6-11 person-weeks
across seven SDKs; the datagram plane 10-20 more. ADR 0011's 6.5 are already
spent. This is the largest single commitment on the roadmap and it competes with
the licensing move and the marketplace.

**Two wires, permanently.** Browsers cannot do raw UDP and five of seven SDKs
have web export targets, so the JSON WebSocket path can never be retired. Every
SDK carries two decoders and two fixture corpora from here on. That is the cost
ADR 0012 correctly identified; this ADR accepts it rather than disputing it.

**The managed cloud does not get datagrams.** Self-host and cloud diverge on
transport for the first time. That is a product asymmetry to state plainly in the
docs rather than let a reader discover.

**The measurement gap stays open.** Nothing here makes the fleet measurable. If a
latency question arises on the managed side, it is still unanswerable, and that is
now a known limitation rather than a blocker on this work.

**What would reverse this.** The self-hosting MMO going away without another
concrete need behind it, or the codec measuring materially worse than the
benchmark above on a real client under load rather than in a synthetic loop.

## References

- ADR 0011, the sequencing and repair layer this depends on.
- ADR 0012, superseded, for the protocol design and the reasoning that closed it.
- `asobi_saas` ADR 0013, still rejected, for why the fleet cannot expose UDP.
- Research notes 01-17, for the measurements cited throughout.
