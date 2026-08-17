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

Bytes: 807 against 3856, so 4.8x smaller. Three runs each, stable.

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

**4. The protocol design is inherited, not redone.** ADR 0012's protocol survived
architectural review; only its authorisation failed. Frame layout, the two-phase
challenge binding, `conn_id` as the sole demux key, the no-fragmentation rule, the
amplification invariant and the downlink-authenticity decision carry over as
written.

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
