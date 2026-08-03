# REST API

All endpoints are under `/api/v1`. Requests and responses use JSON.

Authenticated endpoints require the `Authorization: Bearer <access_token>` header.

> #### Real-time flows go over WebSocket {: .info}
>
> Use REST for request/response. Matchmaking notifications, chat, votes,
> presence, and live game state are pushed over the [WebSocket
> protocol](websocket-protocol.md), not polled here.

> **Windows / PowerShell**: examples below use `curl` (Linux, macOS, Git Bash,
> WSL). In PowerShell, translate any block by hand once - the shape is the same:
>
> ```powershell
> Invoke-RestMethod -Uri http://localhost:8084/api/v1/auth/register `
>   -Method Post -ContentType application/json `
>   -Body '{"username": "player1", "password": "secret123"}'
> ```
>
> Add auth with `-Headers @{ Authorization = "Bearer $token" }`.
> `Invoke-RestMethod` parses the JSON response for you, so no `jq` is needed.

## Auth

```
POST   /api/v1/auth/register        Register a new player
POST   /api/v1/auth/login           Login, returns session token
POST   /api/v1/auth/refresh         Refresh session token
POST   /api/v1/auth/oauth           OAuth / Steam token validation
POST   /api/v1/auth/guest           Create or resume an anonymous guest
POST   /api/v1/auth/guest/upgrade   Claim a guest account (username + password)
POST   /api/v1/auth/link            Link a provider to the current account
DELETE /api/v1/auth/unlink          Unlink a provider
```

### Register

```bash
curl -X POST /api/v1/auth/register \
  -H 'Content-Type: application/json' \
  -d '{"username": "player1", "password": "secret123", "display_name": "Player One"}'
```

```json
{"player_id": "...", "access_token": "...", "refresh_token": "...", "username": "player1"}
```

### Login

```bash
curl -X POST /api/v1/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"username": "player1", "password": "secret123"}'
```

```json
{"player_id": "...", "access_token": "...", "refresh_token": "...", "username": "player1"}
```

### Guest

Anonymous device-based auth, opt-in via config. `POST /auth/guest` creates a
player on first call and resumes the same one on later calls; `/auth/guest/upgrade`
(authenticated) claims it with a username and password. See the
[Authentication guide](authentication.md#guest-anonymous) for the device-secret
contract, config, and error codes.

```bash
curl -X POST /api/v1/auth/guest \
  -H 'Content-Type: application/json' \
  -d '{"device_id": "b64-device-id", "device_secret": "b64-32-random-bytes"}'
```

```json
{"player_id": "...", "access_token": "...", "refresh_token": "...",
 "username": "guest_9c41e0b7a2d5f318", "created": true, "guest": true}
```

## Players

```
GET /api/v1/players/:id        Get player profile
PUT /api/v1/players/:id        Update own profile
```

## Worlds

```
GET  /api/v1/worlds         Browse live worlds
GET  /api/v1/worlds/:id     Get one world
POST /api/v1/worlds         Create a world
```

`GET /api/v1/worlds` accepts `mode` (ignored above 64 bytes) and
`has_capacity=true`. Only worlds whose mode sets `listed` (the default) are
returned. Results are cached for 500ms.

`POST /api/v1/worlds` returns **201** with the world info, **429** when the
player is at their per-player cap (`player_world_limit_reached`), and **503**
when the global cap is reached (`world_capacity_reached`). See
[World capacity](configuration.md#world-capacity).

`GET /api/v1/worlds/:id` returns **404** for an unknown id.

None of these return the player roster - see [World Server](world-server.md).
There is no REST join: joining binds the world to your WebSocket session, so
it is `world.join` over WS.

## Matches

```
GET /api/v1/matches         Match history (finished matches)
GET /api/v1/matches/live    Live, joinable matches
GET /api/v1/matches/:id     Get one match record
```

**These read different data sources, and it is the most confusing thing in
this API.** `GET /api/v1/matches` queries the match *record* table: finished
matches, an audit trail, nothing you can join. It accepts `mode`, `status`
and `limit` (1-200, default 50), newest first.

`GET /api/v1/matches/live` enumerates running match processes and is what a
lobby browser wants. It accepts `mode` and `has_capacity=true`. Matches are
**unlisted by default** - a mode opts in with `listed => true` - so an empty
result usually means no mode has opted in yet.

Neither returns the player roster. As with worlds, joining is `match.join`
over WS.

## Social

```
GET    /api/v1/friends                               List friends
POST   /api/v1/friends                               Send friend request
PUT    /api/v1/friends/:friend_id                    Accept/reject/block
DELETE /api/v1/friends/:friend_id                    Remove friend

POST   /api/v1/groups                                Create group
GET    /api/v1/groups/:id                            Get group
PUT    /api/v1/groups/:id                            Update group
POST   /api/v1/groups/:id/join                       Join group
POST   /api/v1/groups/:id/leave                      Leave group
GET    /api/v1/groups/:id/members                    List group members
PUT    /api/v1/groups/:id/members/:player_id/role    Update member role
DELETE /api/v1/groups/:id/members/:player_id         Kick member
```

## Economy

```
GET  /api/v1/wallets                   List player wallets
GET  /api/v1/wallets/:currency/history Transaction history
GET  /api/v1/store                     List store catalog
POST /api/v1/store/purchase            Purchase item
GET  /api/v1/inventory                 List player items
POST /api/v1/inventory/consume         Consume item

POST /api/v1/iap/apple                 Validate an Apple receipt
POST /api/v1/iap/google                Validate a Google Play receipt
```

## Leaderboards

```
GET  /api/v1/leaderboards/:id                  Top N entries
GET  /api/v1/leaderboards/:id/around/:player_id Around player
POST /api/v1/leaderboards/:id                  Submit score
```

## Matchmaking

```
POST   /api/v1/matchmaker              Submit matchmaking ticket
GET    /api/v1/matchmaker/:ticket_id   Check ticket status
DELETE /api/v1/matchmaker/:ticket_id   Cancel ticket
```

## Tournaments

```
GET  /api/v1/tournaments               List active tournaments
GET  /api/v1/tournaments/:id           Get tournament details
POST /api/v1/tournaments/:id/join      Join tournament
```

## Votes

```
GET /api/v1/matches/:match_id/votes    List votes for a match (newest first, max 50)
GET /api/v1/votes/:id                  Get a single vote with full results
```

Voting itself happens over WebSocket. See the [Voting guide](voting.md).

## Chat

```
GET /api/v1/chat/:channel_id/history   Message history (paginated)
```

Real-time chat messages are sent and received over WebSocket.

## Notifications

```
GET    /api/v1/notifications           List notifications (paginated)
PUT    /api/v1/notifications/:id/read  Mark as read
DELETE /api/v1/notifications/:id       Delete notification
```

## Direct messages

```
POST /api/v1/dm                        Send a direct message
GET  /api/v1/dm/:player_id/history     DM history with a player
```

## Storage

```
GET    /api/v1/saves                   List save slots
GET    /api/v1/saves/:slot             Get save data
PUT    /api/v1/saves/:slot             Write save (with version for OCC)

GET    /api/v1/storage/:collection             List objects
GET    /api/v1/storage/:collection/:key        Read object
PUT    /api/v1/storage/:collection/:key        Write object
DELETE /api/v1/storage/:collection/:key        Delete object
```

## Ops

```
GET /api/v1/ops/players     Paginated player list
GET /api/v1/ops/matches     Paginated match-record list
GET /api/v1/ops/features    Installed feature set
```

The game-operations read plane, for a console rather than a game client. The
lists differ from the ones above in three ways: they report a total, they
accept a sort, and they page by offset.

Every list returns the same envelope:

```json
{
  "data": [ ... ],
  "page": { "limit": 50, "offset": 0, "total": 137 }
}
```

Parameters shared by `ops/players` and `ops/matches`:

| Parameter | Meaning |
| --- | --- |
| `limit` | Rows per page. Default 50, clamped to 1-200. |
| `page` | 1-based page number. Wins over `offset` when both are given. |
| `offset` | Rows to skip. Clamped to 0-100000 and snapped down to a multiple of `limit`, so the `offset` in the response is the one the query ran with. |
| `sort` | Field to sort by. Must be one of the fields listed below - anything else is **400**, never a silent fallback. |
| `order` | `asc` (default) or `desc`. Anything else is **400**. |
| `q` | Case-insensitive substring search. `%` and `_` are matched literally. |

A malformed number is never an error: `?limit=abc` uses the default. A
malformed *sort* always is, because ordering the wrong rows silently is worse
than a 400.

Sorts always end on `id`, so paging by offset cannot repeat or skip a row when
the sort key has duplicates.

`ops/players` sorts on `id`, `username`, `display_name`, `inserted_at`,
`updated_at`, and searches username and display name. `ops/matches` sorts on
`id`, `mode`, `status`, `started_at`, `finished_at`, `inserted_at`, filters on
`mode` and `status`, and searches mode. Both return the same fields as their
public counterparts - no roster, no credentials.

`GET /api/v1/ops/features` reports what this deployment has installed:

```json
{
  "data": {
    "core": {
      "name": "asobi",
      "version": "0.46.0",
      "capabilities": [{ "name": "guest_auth", "enabled": true }]
    },
    "extensions": []
  }
}
```

Capabilities report what is *configured*, not what is compiled in, and carry a
boolean only - never the configured value. `extensions` is empty until an
extension registry exists; entries will have the same shape as `core`.

> #### Ops routes use player auth today {: .warning}
>
> These routes sit behind the same bearer check as the rest of `/api/v1`, so
> any authenticated player can read them, and their fields are held to exactly
> what the public endpoints already expose. An operator capability model is
> the follow-up.

## Next steps

- [WebSocket protocol](websocket-protocol.md) - the push side of the API.
- [Authentication](authentication.md) - obtaining and refreshing the bearer token.
- [Economy & IAP](economy.md) - wallets, the store, and receipt validation.
