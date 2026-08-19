# ADR 0010: The client wire protocol is frozen at 1.0

Date: 2026-08-13

## Status

Accepted. Freezes the client-facing wire that the ecosystem's ADR 0003
("RPC is the only extension wire seam") drew, now that both transports carry
it and all seven SDKs speak it.

This is a version on the **wire contract**, not on the asobi package. asobi is
a 0.x library and keeps moving; the frame corpus and the RPC envelope below it
do not. The two numbers are independent: the package can reach 1.0, or never,
without touching this freeze, and this freeze can bump to 2.0 while the package
stays 0.x. The number that moves here is the RPC protocol integer
(`?PROTOCOL` in `m:asobi_rpc`), which is `1`.

## Context

The wire is complete. `module.event` and the HTTP RPC transport shipped, and
all seven SDKs (JavaScript, Dart/Flame, Godot, Defold, LÖVE, Unity, Unreal)
decode both. There is no frame type left to add before a client can be written
against this server, so there is nothing left that a first release has to wait
for.

The SDKs do not depend on this server; they copy from it. Every SDK vendors the
fixture corpus (`priv/protocol/fixtures/`) by copying the JSON into its own test
tree, and the Godot and LÖVE SDKs are consumed by copying their source into a
game project. There is no package manager between this repository and a shipped
client, so there is no upgrade path but re-copying, which a shipped game does
not do.

That makes a quiet wire edit a silent client break. Additions are safe: five of
the seven SDKs drop a frame type they do not recognise, so a new frame type or a
new payload field reaches an old client as a no-op. A **rename** is not an
addition. It is a new type the old client drops plus the removal of a type the
old client dispatched on, and the client goes quiet with nothing on either end
reporting it. Changing an existing payload's shape is the same failure a layer
down: the client still dispatches, then reads a field that is no longer there.
The corpus is vendored, so the break lands in every game already shipped against
the old shape and cannot be pulled back.

The same failure runs the other way. An SDK hard-codes the `type` it sends for
each call, so the client -> server command frames are as fixed as the outbound
ones even though they are not in the vendored corpus. Rename a handled inbound
frame and the server answers `unknown_type` to every shipped client - the
identical un-re-pullable break, on the sending side.

This is why the wire freezes harder than the Erlang API. A library consumer of
asobi upgrades a pin and recompiles; a game holding a vendored corpus cannot.
The blast radius of a wire break is every shipped client, not every consumer who
chooses to upgrade.

## Decision

**Freeze the client-facing wire contract at 1.0.** In scope of the freeze:

- **The frame corpus, in both directions.**
  - *Outbound (server -> client): the 40 frame types under
    `priv/protocol/fixtures/` and the payload shape of each.* These are the
    types a client dispatches on and the fields it reads; the SDKs vendor them
    as their test corpus.
  - *Inbound (client -> server): the 22 command frame types the socket
    handles* - `chat.join`, `chat.leave`, `chat.send`, `dm.send`,
    `match.input`, `match.join`, `match.leave`, `match.list`, `matchmaker.add`,
    `matchmaker.remove`, `presence.update`, `rpc.call`, `session.connect`,
    `session.heartbeat`, `vote.cast`, `vote.veto`, `world.create`,
    `world.find_or_create`, `world.input`, `world.join`, `world.leave`,
    `world.list`. These are not in the vendored corpus; they are hard-coded in
    every SDK's call sites, so they cannot be re-pulled either. Renaming or
    removing a handled inbound frame makes the server answer `unknown_type` to
    every shipped client, the same blast radius as an outbound rename, from the
    sending side.
- **The envelope.** `{"type": ..., "payload": {...}}`, the frame every type
  above rides in.
- **The RPC contract.** `rpc.call` in, `rpc.ok` / `rpc.error` out; the
  `{code, message, details}` error object; and the RPC protocol integer
  (`?PROTOCOL = 1`), which versions the payload rather than the frame type.
- **Both transports.** WebSocket and `POST /api/v1/rpc/<method>`. They diverge
  in front of the dispatcher (auth, rate limit, size cap, where `protocol`
  comes from) but share one envelope below it, so a single SDK decoder serves
  both, and that shared envelope is frozen for both.

Compat policy from here:

- **Additive, with one carve-out.** A new frame type, and a new field on an
  existing payload, are allowed, and clients tolerate both: an unknown type is
  dropped and an unknown field is ignored. This is unconditionally safe in the
  reserved namespaces (`session`, `presence`, `module`, `rpc`). It is NOT
  unconditionally safe in the open `match.` / `world.` leaf space, which game
  scripts share: adding a core `match.<leaf>` or `world.<leaf>` frame forces
  adding `<leaf>` to `?RESERVED_EVENT_NAMES` (`m:asobi_ws_handler`), and the
  validate path then silently drops that leaf server-side for any shipped game
  already broadcasting it through `game.broadcast`. A core addition in the open
  leaf space can therefore retroactively ban a shipped game's own event, so it
  is weighed as a break there rather than waved through as additive.
- **Rename or removal of a frozen frame type, or a change to an existing
  payload's shape, is a breaking change.** It is not a silent edit. It requires
  bumping the RPC protocol integer (1 -> 2) and carrying both versions under an
  N / N-1 window, so a client on the old version keeps a server that answers it
  while it migrates.

## Consequences

- **A wire break now costs a version bump and a compat window, deliberately.**
  That is the point of the freeze, not a side effect of it. The cost is paid by
  whoever breaks the wire, once, rather than by every shipped game, silently.
- **The freeze is enforced by CI, not by discipline.** Two guards already hold
  most of it, and this ADR adds the frozen-set guards:
  - `scripts/protocol-sync.sh` and `.github/workflows/protocol-sync.yml` keep
    all seven SDK vendored copies of the corpus in lockstep with this
    repository, so no SDK carries a stale or forked fixture.
  - `asobi_protocol_coverage_tests` enforces corpus integrity: every emitted
    event has a fixture, no fixture is stale, every fixture is a valid envelope,
    and the listing projections match their fixtures.
  - The new frozen-set guards in that suite pin the frozen types by name in
    both directions - the 40 outbound fixtures, and the 22 inbound command
    frames scanned from `asobi_ws_handler`'s handled clauses - so removing or
    renaming either fails the build and forces a conscious wire-version decision
    rather than a green diff. Additions stay allowed; the coverage test above
    already covers new outbound types.
- **The frozen-set guards pin type NAMES, not payload shapes.** A field quietly
  dropped or retyped on a frozen frame is not what they catch; that is held by
  the other three mechanisms - the fixtures are the SDKs' vendored ground truth,
  `protocol-sync` keeps every copy identical, and
  `listing_fixtures_match_the_projection_test` pins the two listing payloads to
  their projection function. Do not read the frozen-set tripwire as a shape
  check.
- **The HTTP RPC status mapping is frozen too.**
  `POST /api/v1/rpc/<method>` returns the error object's own HTTP status
  (`asobi_error:status/1`), so that code -> status map is part of this frozen
  wire. The rest of the REST surface is out of scope here and is versioned
  separately through its own `/api/v1/` path.
- **The frozen sets are hand-maintained lists, not derived from the corpus or
  the handler scan.** Deriving either would defeat it: a deletion would shrink
  the derived list along with the thing it checks and pass, which is exactly the
  change the guards exist to catch.
