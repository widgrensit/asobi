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

## Connection

### `session.connect`

Authenticate the WebSocket connection. Must be the first message sent.

```json
{"type": "session.connect", "payload": {"token": "session_token_here"}}
```

Response:

```json
{"type": "session.connected", "payload": {"player_id": "..."}}
```

### `session.heartbeat`

Keep-alive ping. Send periodically to prevent timeout.

```json
{"type": "session.heartbeat", "payload": {}}
```

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
Violations are rejected with `invalid_join_ctx`, `join_ctx_too_many_keys`,
`join_ctx_key_too_long`, `join_ctx_value_too_long`, or
`invalid_join_ctx_value`.

**A join context does not make a world private.** Only a game that
implements `join/3` and rejects unauthorised joins restricts entry; a game
that ignores it stays open to anyone holding a `world_id`.

### `match.input`

Send game input to the match server.

```json
{"type": "match.input", "payload": {"action": "move", "x": 10, "y": 5}}
```

### `match.state` (server push)

Server broadcasts game state updates to all players in the match.

```json
{"type": "match.state", "payload": {"players": {...}, "tick": 42}}
```

### `match.started` (server push)

Notification that a match has begun.

```json
{"type": "match.started", "payload": {"match_id": "...", "players": [...]}}
```

### `match.finished` (server push)

Notification that a match has ended with results.

```json
{"type": "match.finished", "payload": {"match_id": "...", "result": {...}}}
```

### `match.leave`

Leave the current match.

```json
{"type": "match.leave", "payload": {}}
```

## Matchmaking

### `matchmaker.add`

Submit a matchmaking ticket.

```json
{"type": "matchmaker.add", "payload": {"mode": "arena", "properties": {"skill": 1200}}}
```

### `matchmaker.remove`

Cancel a matchmaking ticket.

```json
{"type": "matchmaker.remove", "payload": {"ticket_id": "..."}}
```

### `match.matched` (server push)

Notification that the matchmaker paired you into a match.

```json
{"type": "match.matched", "payload": {"match_id": "...", "players": [...]}}
```

> Note: distinct from `match.joined`, which is the server's reply to a
> client-initiated `match.join` message. Both signal "you're in a match
> and `match.state` will follow," but only `match.matched` is fired
> spontaneously by the matchmaker.

## Worlds

The world server runs persistent shared spaces with zoned interest
management. See [World server](world-server.md) for the model and
[Large worlds](large-worlds.md) for tuning.

### `world.list`

List running worlds. Optional filters: `mode` (string), `has_capacity`
(bool — only worlds that aren't full).

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
(per-player cap hit). On success the caller is auto-joined.

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

Send game input to your zone. The `payload` IS the input map — there is
no inner `data` wrapper. Field names are entirely up to your game; the
server only forwards the map verbatim to your `handle_input/3` callback.

```json
{"type": "world.input", "payload": {"kind": "move", "x": 600, "y": 480}}
```

The server routes the message to whichever zone owns your player
entity — clients don't specify zone coordinates.

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
the **initial snapshot** for every entity in the zone — register your
handler before sending the join message or you miss it.

```json
{"type": "world.tick", "payload": {"tick": 42, "updates": [{"op": "a", "id": "01HX...", "x": 600, "y": 480, "type": "player"}]}}
```

`updates` is a list of entity deltas. `op` values:

| `op` | Meaning | Fields |
|------|---------|--------|
| `"a"` | Added — full state | id + every field on the entity |
| `"u"` | Updated — diff | id + only changed fields |
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

Phase transition for worlds that declare phases. Payload mirrors the
match `match.phase_changed` event.

```json
{"type": "world.phase_changed", "payload": {"phase": "combat", "duration_ms": 60000}}
```

## Chat

Channel ids are namespaced: every id must start with one of these prefixes, and
a frame whose channel id is missing or unprefixed is rejected with
`channel_id_invalid`. The prefix lets the runtime route the message and enforce
membership without a per-frame registry lookup.

| Prefix   | Used for                                  | Membership rule |
|----------|-------------------------------------------|-----------------|
| `dm:`    | Direct messages                           | The two named participants only. |
| `world:` | World-wide chat                           | Players currently joined to the world. |
| `zone:`  | A specific zone within a world            | Players currently joined to the world. |
| `prox:`  | Proximity chat (radius around a position) | Players currently joined to the world. |
| `room:`  | App-defined group chat                    | Members of the group whose id equals the channel id. Not open-join. |

There is no open-join room policy and no `match:` scheme. `room:` is authorised
as a group membership check: the runtime treats the full channel id as the group
id, so a player must already belong to a group with that exact id. For pre-game
lobby chat, gate on world membership with `world:<world_id>`, or use
`game.broadcast`; see the [Lobbies](lobbies.md) guide.

The worked examples below use a `world:` channel, which authorises on world
membership you already hold after `world.join`.

A single connection may join at most **32 channels** at once; a 33rd is rejected
with `too_many_channels`. Idle channels with no members stop after 60s; rejoining
is cheap. Message `content` is capped at 2000 bytes and empty or non-binary
content is rejected with `content_empty` / `content_too_large`.

History (`GET /api/v1/chat/:channel_id/history`) requires membership and clamps
`?limit` to 200; non-members get `403`.

### `chat.join`

Join a chat channel. The channel id must be namespaced.

```json
{"type": "chat.join", "payload": {"channel_id": "world:w_ancient_ruins"}}
```

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
    "sent_at": "2025-01-15T10:30:00Z"
  }
}
```

### `chat.leave`

Leave a chat channel.

```json
{"type": "chat.leave", "payload": {"channel_id": "world:w_ancient_ruins"}}
```

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

### `vote.veto`

Use a veto token to cancel the current vote. Requires `veto_tokens_per_player > 0`
in match config and `veto_enabled` on the vote.

```json
{"type": "vote.veto", "payload": {"vote_id": "..."}}
```

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

Update your online status.

```json
{"type": "presence.update", "payload": {"status": "in_game", "metadata": {"match_id": "..."}}}
```

### `presence.changed` (server push)

A friend's presence changed.

```json
{"type": "presence.changed", "payload": {"player_id": "...", "status": "online"}}
```

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

## Next steps

- [REST API](rest-api.md) - the request/response surface alongside this socket protocol.
- [Authentication](authentication.md) - obtaining the token the socket authenticates with.
- [Voting](voting.md) - the vote flow whose `match.vote_*` pushes appear above.
