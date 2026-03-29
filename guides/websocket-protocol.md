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

### `matchmaker.matched` (server push)

Notification that a match was found.

```json
{"type": "matchmaker.matched", "payload": {"match_id": "...", "players": [...]}}
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
