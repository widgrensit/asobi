# Asobi WebSocket Protocol Fixtures

Canonical examples of every server-to-client message the asobi library itself emits over its WebSocket.

The `match.` and `world.` namespaces are open: a game can push its own events
through them, and those are not (and cannot be) in this corpus. See
[Game-defined events](#game-defined-events-are-not-in-the-corpus) before
writing an SDK dispatcher that switches exhaustively on `type`.

## What this is for

Each file in `fixtures/` is one realistic instance of a server-emitted message envelope. Client SDKs use the corpus as ground truth for **dispatch unit tests**: feed the raw JSON into the SDK's message handler, assert the right callback fires for the right `type`. This catches the class of bug where the docs and the wire disagree (e.g. docs say `matchmaker.matched`, server emits `match.matched`) at write time, in milliseconds, in every SDK's CI.

The corpus only covers **envelope routing** — `type` plus a representative `payload`. Game-mode-specific payload bodies (e.g. the `players` map inside `match.state`) are intentionally generic; SDKs assert that the SDK routes the message to the right callback, not that it parses domain-specific fields.

## Coverage contract

`asobi_protocol_coverage_tests.erl` is the keeper. It scans the asobi source for every emit site (`encode_reply/3` calls plus `{match_event, _, _}` and `{world_event, _, _}` send sites) and asserts that each event has exactly one fixture file. Adding an emit site without a fixture fails CI. Adding a stale fixture for a removed event fails CI.

The scan only recognises literal lowercase atoms, so an emit site whose event name is a variable is invisible to it. That is deliberate: the only such sites are the `game.broadcast` relays described below, whose names are game-owned and unenumerable.

## Game-defined events are not in the corpus

A game script's `game.broadcast("round_start", ...)` reaches clients as `{"type": "match.round_start"}` from a match, or `{"type": "world.round_start"}` from a world. asobi owns the prefix and validates the leaf name (1-64 bytes, `[A-Za-z0-9_-]`, and never one of asobi's own leaf names - see `asobi_ws_handler:reserved_event_names/0`); the leaf itself belongs entirely to the game.

That class of message is open-ended by design and can never be enumerated here. **Do not read this corpus as a closed set of wire types.** Every official SDK already has a generic fallback for exactly this reason - Unity's `AsobiDispatcher.HandleMessage` has a `default:` branch that strips the `match.`/`world.` prefix and fires `OnMatchEvent`/`OnWorldEvent`, and Godot and the JS SDK have the same path. A new SDK needs that fallback too; without it, every game-defined event is silently dropped.

The wire-level detail, including what happens to a rejected name, is in [guides/websocket-protocol.md](../../guides/websocket-protocol.md#custom-events).

## Layout

```
priv/protocol/
├── README.md              (this file)
└── fixtures/
    ├── error.json
    ├── match.matched.json
    ├── ...
```

One file per event. Filename is the `type` field plus `.json`.

## Keeping the SDK copies in sync

Every official SDK vendors a copy, and copies drift: when the automation below
was written core had 38 fixtures and the SDKs had between 28 and 35, with
nothing to notice.

```sh
scripts/protocol-sync.sh check <sdk> <path-to-sdk-repo>   # fails on drift, names each file
scripts/protocol-sync.sh apply <sdk> <path-to-sdk-repo>   # copies in, removes stale
scripts/protocol-sync.sh sdks                             # js dart godot love2d defold unity unreal
```

`.github/workflows/protocol-sync.yml` runs `apply` against all seven on any
change under `priv/protocol/` on main and opens one PR per SDK. It does not
merge them: a new event usually needs a dispatch case, and that is a decision
in the SDK's own repo.

An SDK's own CI should run `check` against a pinned asobi so drift fails there
too, rather than waiting for the next corpus change to reveal it.

## Using the corpus from a client SDK

A typical SDK dispatch test fetches `priv/protocol/fixtures/<type>.json` (vendored or pulled from a published asobi release artifact), feeds the raw bytes into the SDK's `_handle_message` (or equivalent), and asserts a callback fired:

```lua
-- love2d / busted
it("routes match.matched", function()
  local fired = nil
  local rt = realtime.new(); rt:on("match_matched", function(p) fired = p end)
  rt:_handle_message(read_fixture("match.matched.json"))
  assert.equals("01j8x000000000000000000001", fired.match_id)
end)
```

```typescript
// asobi-js / vitest
it("routes match.matched", () => {
  const ws = new AsobiWebSocket({...});
  let fired: any;
  ws.on("match.matched", p => fired = p);
  ws.handleMessage(loadFixture("match.matched.json"));
  expect(fired.match_id).toBe("01j8x000000000000000000001");
});
```

The pattern is identical across every SDK.

## What this does NOT cover

- Client→server messages (the SDK *sends* these — different test category).
- Payload field-rename drift inside an event (e.g. `match.state` payload schema). Game modes own their payload shape, not the asobi library.
- Game-defined `match.<name>`/`world.<name>` events from `game.broadcast` - the leaf name is game-owned, so there is no finite set to fixture. Dispatch-test those in the game's own SDK tests, against the generic `match.*`/`world.*` fallback.
- Authoring docs or types from these fixtures — that's a separate codegen step, not built today.
