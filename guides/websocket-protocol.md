# WebSocket Protocol

Asobi uses a single WebSocket connection per client at `/ws`. All messages
are JSON with a common envelope format.

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

### `match.join`

Join a match (after being matched via matchmaker or direct invite).

```json
{"type": "match.join", "payload": {"match_id": "..."}}
```

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

Notification that the matchmaker formed a match including this player. Wire
type is `match.matched` (the matchmaker emits a `{match_event, matched, ...}`
internally, which the WS handler renders as `match.` + the event atom).

```json
{"type": "match.matched", "payload": {"match_id": "...", "players": [...]}}
```

> **Note for SDK authors — `match.matched` vs `match.joined`**
>
> Both events signal "the client is in a match and `match.state` will follow",
> but they fire on different paths:
>
> - **`match.matched`** is pushed by the matchmaker after a queue forms a match.
>   The client did not call `match.join`; the server has already placed it.
> - **`match.joined`** is the reply to a client-initiated `match.join` (e.g.,
>   joining a friend's match by id, or rejoining after disconnect).
>
> SDKs SHOULD subscribe to both and surface them as a single `OnMatchReady`
> (or equivalent) event so consumers don't have to know which path was taken.
> A matchmade flow will fire `match.matched` only; a direct-join flow will
> fire `match.joined` only.

### `match.matchmaker_failed` (server push)

The matchmaker could not form a match for this ticket (e.g. no game module
configured for the requested mode).

```json
{"type": "match.matchmaker_failed", "payload": {"reason": "no_game_module"}}
```

### `match.matchmaker_expired` (server push)

The ticket exceeded the matchmaker's max wait time and was dropped.

```json
{"type": "match.matchmaker_expired", "payload": {"ticket_id": "..."}}
```

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

### `chat.join`

Join a chat channel.

```json
{"type": "chat.join", "payload": {"channel_id": "lobby"}}
```

### `chat.send`

Send a message to a channel.

```json
{"type": "chat.send", "payload": {"channel_id": "lobby", "content": "Hello!"}}
```

### `chat.message` (server push)

A new message in a joined channel.

```json
{
  "type": "chat.message",
  "payload": {
    "channel_id": "lobby",
    "sender_id": "...",
    "content": "Hello!",
    "sent_at": "2025-01-15T10:30:00Z"
  }
}
```

### `chat.leave`

Leave a chat channel.

```json
{"type": "chat.leave", "payload": {"channel_id": "lobby"}}
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
