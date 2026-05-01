# Asobi WebSocket Protocol Fixtures

Canonical examples of every server-to-client message asobi emits over its WebSocket.

## What this is for

Each file in `fixtures/` is one realistic instance of a server-emitted message envelope. Client SDKs use the corpus as ground truth for **dispatch unit tests**: feed the raw JSON into the SDK's message handler, assert the right callback fires for the right `type`. This catches the class of bug where the docs and the wire disagree (e.g. docs say `matchmaker.matched`, server emits `match.matched`) at write time, in milliseconds, in every SDK's CI.

The corpus only covers **envelope routing** — `type` plus a representative `payload`. Game-mode-specific payload bodies (e.g. the `players` map inside `match.state`) are intentionally generic; SDKs assert that the SDK routes the message to the right callback, not that it parses domain-specific fields.

## Coverage contract

`asobi_protocol_coverage_tests.erl` is the keeper. It scans the asobi source for every emit site (`encode_reply/3` calls plus `{match_event, _, _}` and `{world_event, _, _}` send sites) and asserts that each event has exactly one fixture file. Adding an emit site without a fixture fails CI. Adding a stale fixture for a removed event fails CI.

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
- Lua-side `world.broadcast_event/3` and `match.broadcast_event/3` — those are user code; their event names are mode-specific.
- Authoring docs or types from these fixtures — that's a separate codegen step, not built today.
