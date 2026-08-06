# WebSocket Protocol

Asobi uses a single WebSocket connection per client at `/ws`. All messages
are JSON with a common envelope format.

> **You probably do not call this directly.** This page is the raw wire reference.
> Every official SDK (Defold, Godot, Unity, Unreal, Dart/Flame, JavaScript, LÖVE)
> wraps this protocol: each message you *send* is a function, each message the
> server *pushes* is a callback you register. Reach for this page only to write a
> client from scratch or to debug what is on the wire. For the calls in your
> language, see the realtime section of your [SDK quickstart](https://asobi.dev/docs).

## Message Format

### Client to Server

```json
{
  "cid": "optional-correlation-id",
  "type": "message.type",
  "payload": {}
}
```

### Server to Client

```json
{
  "cid": "correlation-id-if-request",
  "type": "message.type",
  "payload": {}
}
```

The `cid` field is optional. When provided, the server echoes it back in
the response so the client can correlate request/response pairs.

## Custom events

The events listed on this page are the ones asobi itself emits. They are not
the whole `type` space: a game script owns the leaf name under `match.` and
`world.`, so a client must never switch exhaustively on the list below.

`game.broadcast` from a match script:

```lua
game.broadcast("round_start", { phase = "combat" })
```

reaches every player in that match as:

```json
{"type": "match.round_start", "payload": {"phase": "combat"}}
```

The same call from a world script produces `world.round_start` and reaches
every player in the world. There is no `cid` - these are pushes, never
replies.

The runtime validates the leaf name before it goes on the wire:

- 1 to 64 bytes.
- `A-Z`, `a-z`, `0-9`, `_` and `-` only. `.` is excluded, so a script cannot
  mint a deeper `world.foo.bar` sub-namespace.
- Not one of asobi's own leaf names, otherwise a script could forge a frame
  byte-identical to an authoritative event such as `world.tick` or
  `match.finished`. The reserved set is
  `asobi_ws_handler:reserved_event_names/0`:

<!-- BEGIN reserved-event-names (verified against asobi_ws_handler:reserved_event_names/0 by asobi_protocol_coverage_tests) -->
```
finished            joined              left                list
matched             matchmaker_expired  matchmaker_failed   phase_changed
state               terrain             tick                vote_result
vote_start          vote_tally          vote_vetoed
```
<!-- END reserved-event-names -->

The payload is also capped at 64 KiB encoded, the same bound as an inbound
frame, because it fans out to every player. A payload that cannot be encoded
as JSON at all is rejected on the same path.

A broadcast that fails any of these is dropped and logged server-side. The
client is told nothing, so do not wait for an error frame that will not come.

Client SDKs handle this open namespace with a generic fallback: any
`match.*`/`world.*` type with no dedicated callback has its prefix stripped
and is handed to a catch-all match/world event handler. Every official SDK
has one; a client written from scratch needs one too.

## Connection

### `session.connect`

Authenticate the WebSocket connection. Must be the first message sent. The
token is the `access_token` from any auth route.

```json
{"type": "session.connect", "payload": {"token": "<access_token>"}}
```

Response:

```json
{"type": "session.connected", "payload": {"player_id": "..."}}
```

A bad or expired token answers `error` with reason `invalid_token` and code
`unauthenticated`, and the socket stays open so the client can retry with a
refreshed token.

### `session.heartbeat`

Keep-alive ping. Send periodically to prevent timeout.

```json
{"type": "session.heartbeat", "payload": {}}
```

Reply, carrying the server's clock in Unix milliseconds:

```json
{"type": "session.heartbeat", "cid": "h-1", "payload": {"ts": 1785312000000}}
```

The reply is the same type as the request. A client that switches on `type`
alone must tolerate that; a `cid` distinguishes the reply from a push.

### Limits

Every bound below is enforced by the socket itself, and a client that
reconnects or backs off needs all of them.

| Bound | What happens |
| --- | --- |
| 60 messages per second per connection | Further frames in that second are answered with `error`, reason `rate_limited`. The connection stays open. |
| 64 KiB per inbound frame | Answered with `error`, reason `payload_too_large`. Measured on the raw frame, before JSON parsing. |
| 10s to send `session.connect` | The socket is closed with code 1008 and the reason `idle_auth_timeout`. Override with `asobi.ws_idle_auth_timeout_ms`. |
| 60 connects per second per IP | The upgrade is closed with 1008 `rate_limited` before anything else runs. Tune under `asobi.rate_limits`, group `ws_connect`. |
| Origin allowlist | A browser `Origin` outside `asobi.ws_allowed_origins` is closed with 1008 `origin_rejected`. With no allowlist configured every Origin passes, and a request with no `Origin` header always passes, because a native client sends none. |

The message-rate window is a fixed 1000ms bucket, not a sliding one: a burst
that straddles the boundary can put 120 frames through in two adjacent
windows. Size a client's send rate against the limit, not against the burst.

Joining is bounded separately, per player rather than per connection: 10
world or match joins per 60 seconds, including `world.create` and
`world.find_or_create`. The 11th is `error` with reason `join_rate_limited`
and code `join_rate_limited`.

The first two bounds are per connection. The connect-flood and join buckets
are per node, so across a cluster the real ceiling is the figure above times
the node count. See [Clustering](clustering.md).

## Matches

> The `match.input` (client -> server) and `match.state` (server -> all clients)
> pair below is the core real-time loop. In an SDK these are one send function and
> one receive callback - see the realtime section of your [SDK quickstart](https://asobi.dev/docs).

### `match.list`

Browse live, joinable matches. Filters are optional.

```json
{"type": "match.list", "payload": {"mode": "arena", "has_capacity": true}}
```

Reply payload is `{"matches": [...]}`, each entry carrying `match_id`,
`mode`, `status`, `player_count` and `max_players`. The roster is not
included; see [World Server](world-server.md) for why discovery and
membership are separate surfaces.

**Matches are unlisted by default.** A matchmaker-spawned match is already
assigned to its players, so it has no reason to appear in a browser. A mode
opts in with `listed => true`. This is the inverse of worlds, which default
to listed.

Distinct from `GET /api/v1/matches`, which reads the match *record* table
(finished matches, an audit trail). `GET /api/v1/matches/live` is the REST
equivalent of this message.

### `match.join`

Join a match (after being matched via matchmaker, discovered via
`match.list`, or a direct invite).

```json
{"type": "match.join", "payload": {"match_id": "..."}}
```

Joining is WebSocket-only by design: the join binds the match to your
session so subsequent `match.input` is routed. There is no REST join, the
same as for worlds.

#### `match.joined` (reply)

The full match info, including the roster:

```json
{"type": "match.joined", "cid": "j-1", "payload": {"match_id": "...", "mode": "arena", "status": "waiting", "player_count": 1, "max_players": 4, "players": ["..."], "listed": false}}
```

An unknown id is `match_not_found` (`match.not_found`); over the join rate
it is `join_rate_limited`; a game module that refuses the join answers with
whatever reason it returned, wrapped as `ws.request_failed`.

#### Join context

Both `match.join` and `world.join` accept an optional `ctx`, passed through
to your game module untouched:

```json
{"type": "match.join", "payload": {"match_id": "...", "ctx": {"code": "AB12"}}}
```

Asobi never interprets, echoes, or logs it. It reaches your game's join
callback, which decides whether to accept.

In Lua, declare a third parameter:

```lua
function join(player_id, state, ctx)
	if ctx.code ~= state.room_code then
		return state              -- refuse: player is not added
	end
	state.players[player_id] = true
	return state
end
```

In Erlang, export `join/3` (`join(PlayerId, Ctx, GameState)`) alongside or
instead of `join/2`.

Either way a game that takes only `(player_id, state)` is unaffected and a
supplied `ctx` is ignored.

This is how you build join codes, invites, passwords and party checks:
without it there is no channel from a client to your game before
membership exists, so `join/2` can implement an allowlist but never a code.

Bounded at the server: a flat object, at most 8 keys, keys up to 64 bytes,
string values up to 256 bytes, plus integers and booleans. No nesting.
Violations are rejected with `invalid_join_ctx`, `invalid_join_ctx_key`,
`join_ctx_too_many_keys`, `join_ctx_key_too_long`, `join_ctx_value_too_long`,
or `invalid_join_ctx_value`. None of the six has a code of its own, so each
arrives as `ws.request_failed` with the reason in `details` - see
[error](#error-server-push).

**A join context does not make a world private.** Only a game that
implements `join/3` and rejects unauthorised joins restricts entry; a game
that ignores it stays open to anyone holding a `world_id`.

### `match.input`

Send game input to the match server.

```json
{"type": "match.input", "payload": {"action": "move", "x": 10, "y": 5}}
```

Input sent while not in a match or world is dropped. The first drop (at
most one per 5 seconds per connection) is answered with an error event so
the client can tell input is going nowhere:

```json
{"type": "error", "payload": {"type": "match.input", "reason": "not_in_match", "error": {"code": "match.not_in_match", "message": "This connection is not joined to a match.", "details": {}}}}
```

### `error` (server push)

Every failure on this socket is an `error` frame, carrying the `cid` of the
request that caused it when there was one:

```json
{"type": "error", "cid": "c-17", "payload": {"reason": "world_not_found", "error": {"code": "world.not_found", "message": "No live world exists with this id.", "details": {}}}}
```

- `error.code` is the contract - stable, machine-readable, and namespaced by
  domain (`match.`, `world.`, `chat.`, `dm.`, `matchmaker.`, `rpc.`, `ws.`) or
  bare when it is cross-cutting (`rate_limited`, `join_rate_limited`,
  `unauthenticated`, `forbidden`, `payload_too_large`, `invalid_json`,
  `invalid_message`, `invalid_payload`, `missing_field`, `unknown_type`,
  `internal`). Branch on this. Codes come from the same closed set the
  [REST API](rest-api.md#errors) uses.
- The two surfaces agree only where a failure has a first-class code. A
  WebSocket reason that has one carries it, so `world_not_found` here and a
  404 on `GET /api/v1/worlds/:id` are both `world.not_found`. Everything else
  arrives as `ws.request_failed` with the reason in `details`, including
  several common failures. On this page that covers the world capacity pair
  (`world_capacity_reached`, `player_world_limit_reached`, which REST answers
  as `world.capacity_reached` and `world.player_limit_reached`) and every
  join-context rejection listed under [Join context](#join-context). Match a
  reason string on `details.reason` for those, not a code.
- `error.message` is prose for a human reading a log. Do not parse it.
- `error.details` is **always** an object, `{}` when there is nothing to add.
- `reason` is the original, flatter dialect. It is unchanged and still sent, so
  existing clients keep working, but it is not namespaced and two unrelated
  failures can share a string. Prefer `error.code`.

A reason with no code of its own yet - including anything a Lua game script
returns from a rejected join - arrives as `ws.request_failed` with the raw
string in `details`, so script-supplied text can never mint a code:

```json
{"type": "error", "payload": {"reason": "party_is_full", "error": {"code": "ws.request_failed", "message": "The request failed. See `details.reason`.", "details": {"reason": "party_is_full"}}}}
```

### `module.error` (server push)

An extension callback error, sent to the player whose input triggered it.
Only emitted when the extension runs with dev errors enabled (for asobi's
Lua runtime, `ASOBI_DEV_ERRORS=true` or `{asobi_lua, [{dev_errors, true}]}`);
production runtimes keep script errors server-side.

`module` names the extension that produced the error. It is the only field
asobi owns; the rest of the payload is the extension's.

```json
{"type": "module.error", "payload": {"module": "lua", "callback": "handle_input", "script": "match.lua", "message": "bad arithmetic + on nil, 1"}}
```

### `module.message` (server push)

A message addressed to one player by an extension - in Lua,
`game.send(player_id, message)`. The message is wrapped rather than sent
raw, because it may be any scripting value (string, number, table).

```json
{"type": "module.message", "payload": {"module": "lua", "message": "you are player 3"}}
```

### `game.error` / `game.message` (server push, deprecated)

The pre-rename names for the two frames above. Deprecated. **New SDK code
dispatches on `module.error` and `module.message`.** The pair is removed
at the 1.0 wire break and will not be replaced.

They are still emitted, byte-identical payload and same reply as their
`module.*` twin, so every SDK built before the rename keeps working with
no change. Each message therefore produces two frames today: the legacy
frame first, then the `module.*` frame.

Do not dispatch on both - a client that handles `game.message` and
`module.message` processes every message twice.

Neither name was ever Lua-specific: both frames are produced by
extensions in general, which is why the producer travels in the payload's
`module` key. Clients that care which extension spoke read
`payload.module` and treat a missing value as `"lua"`. `game.*` put one
extension in the wire type, where no second extension could reuse it -
that is what the rename fixes.

**Wire history.** `module.*` did not exist on the wire in any release
before this change: not in v0.54.0, and not in v0.53.0, where commit
`a6bc2eb` says otherwise. That commit's message describes a dual-emit
that its own follow-up commit in the same pull request removed, because
Nova could not send two frames from one reply at the time
(novaframework/nova#400). Every release up to v0.54.0 emits `game.error`
and `game.message` only.

**Turning the legacy pair off.** Set `asobi.ws_legacy_game_frames` to
`false` to emit only `module.*`. `game.message` is `game.send/2`, which a
script may call per player per tick, so on a chatty game the compat frame
doubles asobi's hottest extension-produced egress. Any client still
dispatching on `game.*` goes silent when you do this, so flip it only
once every client on the deployment reads `module.*`. It defaults to
`true` and becomes a no-op at 1.0.

### `match.state` (server push)

Server broadcasts game state updates to all players in the match.

```json
{"type": "match.state", "payload": {"players": {...}, "tick": 42}}
```

There is no "match started" frame. The match server notifies its players on
`finished` and on nothing else, so a client learns the match began from
`match.matched` (matchmaker) or `match.joined` (its own join reply), and
then from the first `match.state`.

### `match.finished` (server push)

Notification that a match has ended with results.

```json
{"type": "match.finished", "payload": {"match_id": "...", "result": {...}}}
```

`result` is whatever your game returned with `{finished, Result, State}`;
asobi does not interpret it, with one exception. It reads `winners` (a list
of player ids) or `winner` (one id), and `losers` / `loser`, to move the
`wins` and `losses` columns in `player_stats`. `games_played` moves for
every player in the match either way. Declare winners without losers and
every other player in the match takes the loss; declare `losers: []` to
score a co-op run where nobody loses. `rating` and `rating_deviation` are
not maintained by asobi.

### `match.leave`

Leave the current match.

```json
{"type": "match.leave", "payload": {}}
```

#### `match.left` (reply)

```json
{"type": "match.left", "cid": "l-1", "payload": {"success": true}}
```

Sent whether or not the connection was in a match, so leaving is safe to
call unconditionally on teardown.

## Matchmaking

The queue is per node. A ticket lives in the matchmaker process on the node
that accepted it, there is no ticket table, and the matcher only ever sees
that node's tickets. Two players who queue for the same mode against
different nodes therefore never match each other, and a ticket id is
meaningless on any other node. A cluster needs every matchmaker call from
one player pinned to one node, and matchmaking only works at all if the
whole population lands on one node or the fleet is deliberately partitioned
by mode.

World and match discovery and join are **not** subject to this. They resolve
through a cluster-wide process registry rather than the matchmaker's own
state, so `world.list`, `match.list`, `world.join` and `match.join` reach a
world or match on any node. See [Clustering](clustering.md).

### `matchmaker.add`

Submit a matchmaking ticket.

```json
{"type": "matchmaker.add", "payload": {"mode": "arena", "properties": {"skill": 1200}}}
```

#### `matchmaker.queued` (reply)

```json
{"type": "matchmaker.queued", "cid": "q-1", "payload": {"ticket_id": "...", "status": "pending", "players_needed": 4}}
```

`players_needed` is the mode's configured `match_size`, or `null` when the
mode declares none. How many others are already waiting is deliberately not
reported.

A mode that resolves to no game module is `unknown_mode`
(`matchmaker.unknown_mode`); a full queue is `queue_full`
(`matchmaker.queue_full`). Re-adding for a mode you already have an open
ticket for returns that same ticket rather than a second one.

### `matchmaker.remove`

Cancel a matchmaking ticket.

```json
{"type": "matchmaker.remove", "payload": {"ticket_id": "..."}}
```

#### `matchmaker.removed` (reply)

```json
{"type": "matchmaker.removed", "cid": "r-1", "payload": {"success": true}}
```

Another player's ticket is `not_owner` (`forbidden`). An unknown ticket is
`not_found`, which has no code of its own and arrives as `ws.request_failed`.
A ticket issued by another node reads as unknown here.

### `match.matched` (server push)

Notification that the matchmaker paired you into a match. The join is
already done: the matchmaker joins every paired player before sending this,
so no `match.join` follows.

```json
{"type": "match.matched", "payload": {"match_id": "...", "players": ["...", "..."]}}
```

A mode whose matches are backed by a **world** rather than a match server
sends a different payload on the same frame: `match_id` holds the world id,
`mode` is present, and the roster is under `player_ids` rather than
`players`. Read both keys if your game has any world-backed mode.

Distinct from `match.joined`, which is the reply to a client-initiated
`match.join`. Both mean "you are in a match and `match.state` will follow",
but only `match.matched` arrives unprompted and without a `cid`.

### `match.matchmaker_expired` (server push)

Your ticket waited longer than `matchmaker.max_wait_seconds` (default 60)
without being matched. It is gone; submit a new one to keep queuing.

```json
{"type": "match.matchmaker_expired", "payload": {"ticket_id": "..."}}
```

### `match.matchmaker_failed` (server push)

A group formed but the match could not be started, so everyone in it is back
out of the queue. `reason` is `match_start_failed` or `no_game_module`.

```json
{"type": "match.matchmaker_failed", "payload": {"reason": "match_start_failed"}}
```

## Worlds

The world server runs persistent shared spaces with zoned interest
management. See [World server](world-server.md) for the model and
[Large worlds](large-worlds.md) for tuning.

### `world.list`

List running worlds. Optional filters: `mode` (string, up to 64 bytes) and
`has_capacity` (bool - only worlds that are not full). A filter of the wrong
type is rejected with `invalid_mode_filter` or `invalid_has_capacity_filter`
rather than silently dropped.

```json
{"type": "world.list", "payload": {"mode": "walkers", "has_capacity": true}}
```

Response:

```json
{"type": "world.list", "payload": {"worlds": [{"world_id": "...", "mode": "walkers", "player_count": 1, "max_players": 8}]}}
```

### `world.create`

Create a new world for the given mode. Refuses with
`world_capacity_reached` (global cap hit) or `player_world_limit_reached`
(per-player cap hit). Neither reason has a code of its own on this socket:
both arrive as `ws.request_failed` with the reason in `details`, unlike
`POST /api/v1/worlds`, which answers `world.capacity_reached` (503) and
`world.player_limit_reached` (429). On success the caller is auto-joined and
the reply is `world.joined`.

```json
{"type": "world.create", "payload": {"mode": "walkers"}}
```

### `world.find_or_create`

Atomic find-or-create: returns the first non-full world for the mode,
or creates one if none exists. The caller is auto-joined. **This is the
right call for "drop me into a shared room" flows.**

```json
{"type": "world.find_or_create", "payload": {"mode": "walkers"}}
```

### `world.join`

Join a specific world by id (e.g. one returned from `world.list`).

```json
{"type": "world.join", "payload": {"world_id": "..."}}
```

### `world.input`

Send game input to your zone. The `payload` IS the input map - there is
no inner `data` wrapper. Field names are entirely up to your game; the
server only forwards the map verbatim to your `handle_input/3` callback.

```json
{"type": "world.input", "payload": {"kind": "move", "x": 600, "y": 480}}
```

The server routes the message to whichever zone owns your player
entity - clients do not specify zone coordinates. Input sent while not in a
zone is dropped with no reply at all.

### `world.leave`

Leave the current world.

```json
{"type": "world.leave", "payload": {}}
```

### `world.joined` (server push)

Sent in response to a successful `world.create`, `world.find_or_create`,
or `world.join`. The `payload` is the full world info (mode, world_id,
player_count, grid_size, max_players, …).

```json
{"type": "world.joined", "payload": {"world_id": "...", "mode": "walkers", "grid_size": 1, "max_players": 8, "player_count": 1, "status": "running"}}
```

### `world.tick` (server push)

Per-zone delta broadcast. The first `world.tick` after `world.joined` is
the **initial snapshot** for every entity in the zone - register your
handler before sending the join message or you miss it.

```json
{"type": "world.tick", "payload": {"tick": 42, "updates": [{"op": "a", "id": "01HX...", "x": 600, "y": 480, "type": "player"}]}}
```

`updates` is a list of entity deltas. `op` values:

| `op` | Meaning | Fields |
|------|---------|--------|
| `"a"` | Added, full state | id + every field on the entity |
| `"u"` | Updated, diff | id + only changed fields |
| `"r"` | Removed | id only |

### `world.terrain` (server push)

Sent on zone subscription when the world has a terrain provider. The
chunk data is base64-encoded compressed binary; see
[Large worlds](large-worlds.md) for the encoding.

```json
{"type": "world.terrain", "payload": {"coords": [3, 5], "data": "eJw..."}}
```

### `world.left` (server push)

Confirmation that the leave completed (or that the client was already
out of any world).

```json
{"type": "world.left", "payload": {"success": true}}
```

### `world.finished` (server push)

The world ended (e.g. last player left and the empty grace expired, or
the game module returned `{finished, Result, State}` from `post_tick`).

```json
{"type": "world.finished", "payload": {"world_id": "...", "result": {}}}
```

### `world.phase_changed` (server push)

Phase state for a world whose mode declares phases. Only worlds emit this;
there is no match equivalent, so a client that wants phases in a match reads
them out of `match.state` or has the script broadcast its own event.

```json
{"type": "world.phase_changed", "payload": {"world_id": "...", "status": "active", "phase": "combat", "remaining_ms": 42000, "config": {}, "timers": {}}}
```

`status` is `waiting`, `active` or `complete`, and it decides which other
fields are present:

| `status` | Fields beside `phase` |
| --- | --- |
| `waiting` | `start_condition` - what the phase is waiting for. |
| `active` | `remaining_ms`, `config` (the phase's own config object) and `timers` (the phase's live timers, keyed by id). |
| `complete` | None. `phase` is `null`. |

The frame is sent on every transition, and again periodically while a phase
runs, so a client must treat it as state rather than as an edge. `world_id`
is present on the transition frame and absent from the periodic one; do not
key off it.

## Chat

Channel ids are namespaced: every id must start with one of these prefixes, and
a `chat.join` whose channel id is missing or unprefixed is rejected with
`invalid_channel_id` (`chat.invalid_channel_id`). The prefix lets the runtime
route the message and enforce membership without a per-frame registry lookup.

| Prefix   | Used for                                  | Membership rule |
|----------|-------------------------------------------|-----------------|
| `dm:`    | Direct messages                           | The two named participants only. |
| `global:`| Game-wide chat, spans every world         | Any signed-in player, for a name the operator declared. |
| `world:` | World-wide chat                           | Players currently joined to the world. |
| `zone:`  | A specific zone within a world            | Players currently joined to the world. |
| `prox:`  | Proximity chat (radius around a position) | Players currently joined to the world. |
| `room:`  | App-defined group chat                    | Members of the group whose id is the part of the channel id after `room:`. Not open-join. |

`global:<name>` is the only scheme that outlives a single world, so it is the
one to use for "everyone in the game". A client cannot mint one: the name must
appear in the `chat => #{global => [...]}` of a configured game mode, otherwise
the join is rejected like any other unauthorised channel. Names are up to 64
bytes of `a-z A-Z 0-9 _ - .`. Players in a world whose mode declares a global
channel are joined to it automatically on `world.join` and left on
`world.leave`, exactly as with `world:` - see the
[World Server](world-server.md#chat-channels) guide.

There is no open-join room policy and no `match:` scheme. `room:` is authorised
as a group membership check: the runtime strips the `room:` prefix and looks up
the remainder as a group id, so `room:<group_id>` authorises exactly the members
of `<group_id>`, not members of a group literally named `"room:<group_id>"`. For
pre-game lobby chat, gate on world membership with `world:<world_id>`, or use
`game.broadcast`; see the [Lobbies](lobbies.md) guide.

For a group created with `open=true`, anyone can join without an invite
(`POST /api/v1/groups/:id/join` never rejects with `group_closed`). Membership
is still required to read `room:<group_id>` - joining is what's unrestricted,
not reading. Once joined, a member sees the group's full retained history (up
to the last 200 messages, per the `history` limit below), including messages
sent before they joined. This is intentional and matches how public channels
work in Slack/Discord: it is not a bug or a cutoff to add later.

The worked examples below use a `world:` channel, which authorises on world
membership you already hold after `world.join`.

A single connection may join at most **32 channels** at once; a 33rd is rejected
with `too_many_channels` (`chat.too_many_channels`). Idle channels with no
members stop after 60s; rejoining is cheap.

`chat.send` never answers with a size error. Content over 2000 bytes, and
content that is not a string, is dropped with no reply at all, and empty
content is accepted and broadcast. A client that needs either rejected has to
check before sending. The only failure `chat.send` reports is `not_authorized`
(`forbidden`), for a malformed channel id or a channel this player may not
write to. `content_empty` and `content_too_large` are direct-message codes -
see [Direct messages](#direct-messages).

History (`GET /api/v1/chat/:channel_id/history`) requires membership; `?limit`
defaults to 50 and clamps to 1-200, and a non-member gets `403`.

### `chat.join`

Join a chat channel. The channel id must be namespaced.

```json
{"type": "chat.join", "payload": {"channel_id": "world:w_ancient_ruins"}}
```

#### `chat.joined` (reply)

```json
{"type": "chat.joined", "cid": "c-1", "payload": {"channel_id": "world:w_ancient_ruins"}}
```

A malformed id is `invalid_channel_id` (`chat.invalid_channel_id`); a channel
this player is not authorised for is `not_authorized` (`forbidden`).

Joining does not replay history. Fetch it from
`GET /api/v1/chat/:channel_id/history`.

### `chat.send`

Send a message to a channel.

```json
{"type": "chat.send", "payload": {"channel_id": "world:w_ancient_ruins", "content": "Hello!"}}
```

### `chat.message` (server push)

A new message in a joined channel.

```json
{
  "type": "chat.message",
  "payload": {
    "channel_id": "world:w_ancient_ruins",
    "sender_id": "...",
    "content": "Hello!",
    "sent_at": 1785312000000
  }
}
```

`sent_at` is Unix milliseconds, not an ISO string. The same field on the
persisted history read is a timestamp column, so the two differ.

### `chat.leave`

Leave a chat channel.

```json
{"type": "chat.leave", "payload": {"channel_id": "world:w_ancient_ruins"}}
```

#### `chat.left` (reply)

```json
{"type": "chat.left", "cid": "c-2", "payload": {"channel_id": "world:w_ancient_ruins"}}
```

Sent whether or not the connection had joined that channel.

## Direct messages

A DM is a chat message on a `dm:` channel whose id is both player ids sorted
and joined with colons, so both sides always name the same channel. The
sender gets a reply carrying that id; the recipient gets a `dm.message`
push. Both sides read history from `GET /api/v1/dm/:player_id/history`.

### `dm.send`

```json
{"type": "dm.send", "cid": "d-1", "payload": {"recipient_id": "...", "content": "Hello!"}}
```

#### `dm.sent` (reply)

```json
{"type": "dm.sent", "cid": "d-1", "payload": {"channel_id": "dm:0197...:0198..."}}
```

| Reason | Code | Cause |
| --- | --- | --- |
| `content_empty` | `dm.content_empty` | `content` was the empty string. |
| `content_too_large` | `dm.content_too_large` | `content` was over 2000 bytes. |
| `blocked` | `dm.blocked` | The recipient has blocked the sender. |
| `invalid_input` | `ws.request_failed` | `recipient_id` or `content` was not a string. |

Unlike `chat.send`, these are real error frames: a DM that is too long or
empty is refused rather than dropped.

### `dm.message` (server push)

Addressed to the recipient's session, not to the channel. The sender's own
confirmation is the `dm.sent` reply.

```json
{"type": "dm.message", "payload": {"channel_id": "dm:0197...:0198...", "sender_id": "...", "content": "Hello!", "sent_at": 1785312000000}}
```

A recipient who is offline gets no push; the message is persisted either way
and appears in history when they return.

A connection that has also `chat.join`ed the `dm:` channel additionally
receives the message as a `chat.message` on that channel. Handle one or the
other, or a client that does both shows every DM twice.

## Voting

### `vote.cast`

Cast a vote in an active match vote.

```json
{"type": "vote.cast", "cid": "v1", "payload": {"vote_id": "...", "option_id": "jungle"}}
```

For approval voting, `option_id` is a list:

```json
{"type": "vote.cast", "payload": {"vote_id": "...", "option_id": ["jungle", "caves"]}}
```

#### `vote.cast_ok` (reply)

```json
{"type": "vote.cast_ok", "cid": "v1", "payload": {"success": true}}
```

Casting while not in a match is `not_in_match` (`match.not_in_match`), and
changing your vote more times than the vote's `max_revotes` allows (3 by
default) is `rate_limited`. The refusals that come from the vote itself -
`vote_not_found`, `vote_closed`, `not_eligible`, `invalid_option` - have no
code of their own and arrive as `ws.request_failed` with the reason in
`details`.

### `vote.veto`

Use a veto token to cancel the current vote. Requires `veto_tokens_per_player > 0`
in match config and `veto_enabled` on the vote.

```json
{"type": "vote.veto", "payload": {"vote_id": "..."}}
```

#### `vote.veto_ok` (reply)

```json
{"type": "vote.veto_ok", "cid": "v2", "payload": {"success": true}}
```

An unknown vote is `vote_not_found`, a player out of tokens is
`no_veto_tokens`, and a vote that did not enable vetoes is `veto_disabled`.
None of the three has a code of its own either.

### `match.vote_start` (server push)

A new vote has started.

```json
{
  "type": "match.vote_start",
  "payload": {
    "vote_id": "...",
    "options": [{"id": "jungle", "label": "Jungle Path"}, {"id": "volcano", "label": "Volcano Path"}],
    "window_ms": 15000,
    "method": "plurality"
  }
}
```

### `match.vote_tally` (server push)

Running tally update (only with `"live"` visibility).

```json
{
  "type": "match.vote_tally",
  "payload": {
    "vote_id": "...",
    "tallies": {"jungle": 2, "volcano": 1},
    "time_remaining_ms": 8432,
    "total_votes": 3
  }
}
```

### `match.vote_result` (server push)

Vote closed, winner determined.

```json
{
  "type": "match.vote_result",
  "payload": {
    "vote_id": "...",
    "winner": "jungle",
    "counts": {"jungle": 2, "volcano": 1},
    "distribution": {"jungle": 0.666, "volcano": 0.333},
    "total_votes": 3,
    "turnout": 1.0
  }
}
```

### `match.vote_vetoed` (server push)

A player vetoed the vote.

```json
{"type": "match.vote_vetoed", "payload": {"vote_id": "...", "vetoed_by": "player_id"}}
```

## Presence

### `presence.update`

Set your own status string. `status` is the only field read; anything else in
the payload is discarded. Omitting it sets `"online"`.

```json
{"type": "presence.update", "cid": "p-1", "payload": {"status": "in_game"}}
```

#### `presence.updated` (reply)

```json
{"type": "presence.updated", "cid": "p-1", "payload": {"status": "in_game"}}
```

The status is not validated against a list, and it is not persisted: it lives
for the length of the session. There is no push telling a client that another
player's presence changed - a client that needs a friends list with live
status polls for it.

## Notifications

### `notification.new` (server push)

A new notification for the player.

```json
{
  "type": "notification.new",
  "payload": {
    "id": "...",
    "type": "friend_request",
    "subject": "New friend request",
    "content": {"from_player_id": "..."}
  }
}
```

## Extension RPC

One frame type reaches every method any installed
[extension](extensions.md) declares, so an extension needs no per-extension
SDK work to be callable from a client.

### `rpc.call`

```json
{
  "type": "rpc.call",
  "cid": "c-1",
  "payload": {"protocol": 1, "method": "quests.claim", "params": {"quest_id": "q-1"}}
}
```

- `cid` is **required** here and validated by the server: 1 to 64 printable
  ASCII bytes. Elsewhere on this socket it is an optional echo; an RPC reply
  is useless without it, because it is the only way to pair a reply with its
  call. A rejected `cid` is not echoed back, so that one reply carries none.
- `protocol` is the RPC payload version, currently `1`. Version the payload
  rather than the frame type, so a server that does not speak your version
  says so instead of answering `unknown_type`.
- `params` is **always** an object, `{}` when the method takes nothing.
- `method` is `<extension>.<name>`. The socket must already be authenticated:
  every declared method is player-scoped, and the player is the one that sent
  `session.connect`.

### `rpc.ok` (reply)

```json
{"type": "rpc.ok", "cid": "c-1", "payload": {"result": {"reward": 100}}}
```

`result` is **always** an object, so a method can grow a field without
breaking a shipped client.

### `rpc.error` (reply)

```json
{"type": "rpc.error", "cid": "c-1", "payload": {"error": {"code": "quests.already_claimed", "message": "This quest was already claimed.", "details": {}}}}
```

The same error object the rest of this socket and the
[REST API](rest-api.md#errors) carry, and only that object - the flatter
`reason` dialect is not repeated on a frame nothing has shipped against.

An extension mints codes in its own domain, so a failure arrives as
`quests.already_claimed` rather than `internal`. The set stays closed: a code
no installed extension declared is answered as `internal` instead of being
reflected back. Codes core itself adds for this surface:

| Code | Meaning |
|---|---|
| `rpc.unknown_method` | No installed extension serves that method |
| `rpc.invalid_cid` | `cid` was missing, not a string, empty, over 64 bytes, or not printable ASCII |
| `rpc.unsupported_protocol` | `details.supported` lists the versions this server speaks |
| `rpc.invalid_params` | `params` was not an object |
| `invalid_payload` | `payload` itself was not an object |
| `unauthenticated` | The socket has not completed `session.connect` |
| `not_ready` | The node is still running migrations. Retry |

## Next steps

- [REST API](rest-api.md) - the request/response surface alongside this socket protocol.
- [Extensions](extensions.md) - declaring the methods `rpc.call` reaches.
- [Authentication](authentication.md) - obtaining the token the socket authenticates with.
- [Voting](voting.md) - the vote flow whose `match.vote_*` pushes appear above.
