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
GET /api/v1/ops/players                      Paginated player list
GET /api/v1/ops/players/:id                  One player
GET /api/v1/ops/matches                      Paginated match-record list
GET /api/v1/ops/matches/:id                  One match record
GET /api/v1/ops/features                     Installed feature set
GET /api/v1/ops/leaderboards                 Paginated board list
GET /api/v1/ops/leaderboards/:id/entries     Paginated, ranked board entries
GET /api/v1/ops/matchmaker                   Matchmaking queue, by mode
GET /api/v1/ops/economy/items                Paginated item catalogue
GET /api/v1/ops/economy/items/:id            One item definition
GET /api/v1/ops/economy/listings             Paginated store listings
GET /api/v1/ops/economy/listings/:id         One store listing
GET /api/v1/ops/chat/channels                Live chat channels, by members
GET /api/v1/ops/chat/channels/:id/messages   Paginated channel history
GET /api/v1/ops/tournaments                  Paginated tournament list
GET /api/v1/ops/tournaments/:id              One tournament
GET /api/v1/ops/notifications                Paginated sent notifications
```

The game-operations read plane, for a console rather than a game client. The
lists differ from the ones above in three ways: they report a total, they
accept a sort, and they page by offset.

These routes do **not** accept player tokens. They are their own auth plane -
see [Ops authentication](#ops-authentication) below.

Every list returns the same envelope:

```json
{
  "data": [ ... ],
  "page": { "limit": 50, "offset": 0, "total": 137 }
}
```

Parameters shared by every ops list:

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

A filter is dropped when its value is empty or too long: you get a superset,
and the rows show it. The exception is a filter on an **id** column
(`player_id`, `sender_id`, `item_def_id`): a value that is not a uuid is
`400 ops.invalid_filter`, because dropping it would answer a request scoped to
one player with everybody's rows and nothing in the response would say so.

Sorts always end on a unique column, so paging by offset cannot repeat or skip
a row when the sort key has duplicates. That column is `id` on most lists,
`board_id` for the board list, `player_id` within a board, `mode` for the
queue and `channel_id` for the channel list.

### Lookup by id

Every list with a `:id` route beside it returns one row in the same envelope
minus the page:

```json
{ "data": { "id": "0197...", "username": "kaito" } }
```

The row is passed through the list's own projection, so a lookup can never
return a field the list withheld. An id that is not a uuid is
`400 ops.invalid_id` and never reaches the database; a real miss is
`404 ops.not_found`.

### Players and matches

`ops/players` sorts on `id`, `username`, `display_name`, `inserted_at`,
`updated_at`, and searches username and display name. `ops/matches` sorts on
`id`, `mode`, `status`, `started_at`, `finished_at`, `inserted_at`, filters on
`mode` and `status`, and searches mode. Both return the same fields as their
public counterparts - no roster, no credentials.

### Economy

`GET /api/v1/ops/economy/items` is the item catalogue. Sorts on `id`, `slug`,
`name`, `category`, `rarity`, `inserted_at`, `updated_at`, filters on
`category` and `rarity`, and searches slug and name.

`GET /api/v1/ops/economy/listings` is the store. Sorts on `id`, `item_def_id`,
`currency`, `price`, `active`, `valid_from`, `valid_until`, and filters on
`item_def_id`, `currency` and `active` (`true` or `false` - nothing else
filters).

```json
{
  "data": [
    { "id": "0198...", "item_def_id": "0197...", "currency": "gold",
      "price": 250, "active": true, "valid_from": null, "valid_until": null,
      "metadata": {} }
  ],
  "page": { "limit": 50, "offset": 0, "total": 38 }
}
```

Listings carry no timestamp, so they default to `id` descending. Ids are
UUIDv7, so that is still newest-first. There is no `q` on listings: nothing on
a listing is prose. Search the catalogue and filter by the `item_def_id` it
gives you.

### Chat

`GET /api/v1/ops/chat/channels` lists the channels running on this node with
their current member count. Sorts on `channel_id` and `members`, busiest
first, and searches the channel id. It is process state, so it is this node's
view and it changes between reads.

```json
{
  "data": [{ "channel_id": "room:lobby", "members": 14 }],
  "page": { "limit": 50, "offset": 0, "total": 1 }
}
```

`GET /api/v1/ops/chat/channels/:id/messages` pages one channel's persisted
history. Sorts on `id`, `channel_type`, `sender_id`, `sent_at`, newest first,
filters on `sender_id` and `channel_type`, and searches message content - the
read a moderator acting on a report needs. `metadata` does not leave.

A channel with history but no live process is still readable here; a live
channel that has not been written to yet has no rows.

### Tournaments

`GET /api/v1/ops/tournaments` sorts on `id`, `name`, `leaderboard_id`,
`status`, `start_at`, `end_at`, `inserted_at`, filters on `status` and
`leaderboard_id`, and searches the name.

Every row carries `live`: whether a tournament process is actually running for
it. A row can say `"status": "active"` with `"live": false` after a node
restart, and no other read shows that. `metadata` does not leave; `entry_fee`
and `rewards` do.

### Notifications

`GET /api/v1/ops/notifications` is the send history. Sorts on `id`,
`player_id`, `type`, `subject`, `read`, `sent_at`, newest first, filters on
`player_id`, `type` and `read`, and searches the subject. It answers the
question a broadcast raises: who received it, and how many have opened it.

The ops plane is read-only, so there is no broadcast route here. The broadcast
is an in-process entry point that writes an audit row - see
[Ops audit](#ops-audit).

### Leaderboards

`GET /api/v1/ops/leaderboards` lists boards rather than scores. Sorts on
`board_id`, `entries`, `top_score`, `updated_at`, defaults to the largest
board first, and searches `board_id`.

```json
{
  "data": [
    { "board_id": "arena_eu", "entries": 4120, "top_score": 98210,
      "updated_at": "2026-08-03T12:00:00Z", "live": true }
  ],
  "page": { "limit": 50, "offset": 0, "total": 1 }
}
```

`live` says whether the board currently has a process. A board is live without
rows for its first 30 seconds - scores are flushed on an interval - and has
rows without being live when nothing has written to it since the node started.
Both cases are listed.

`GET /api/v1/ops/leaderboards/:id/entries` pages one board. Sorts on `id`,
`player_id`, `score`, `sub_score`, `updated_at`, and defaults to `score`
descending, which is the board's own order.

```json
{
  "data": [
    { "id": "0198...", "leaderboard_id": "arena_eu", "player_id": "0197...",
      "score": 98210, "sub_score": 0, "rank": 1,
      "updated_at": "2026-08-03T12:00:00Z" }
  ],
  "page": { "limit": 50, "offset": 0, "total": 4120 }
}
```

`rank` is the position on the whole board, not within the page: row 501 is
rank 501. It stays the board's rank whatever you sort the page by, and it is
computed over the same order the public `GET /api/v1/leaderboards/:id` uses,
so the two agree on any flushed score.

The read is of persisted scores. A score submitted seconds ago is on the
public top-N endpoint before it is here.

### Matchmaker

`GET /api/v1/ops/matchmaker` reports the queue, one row per mode. Sorts on
`mode`, `waiting`, `oldest_wait_ms`, `average_wait_ms`, deepest queue first.

```json
{
  "data": [
    { "mode": "ranked", "waiting": 14, "oldest_wait_ms": 21400, "average_wait_ms": 8300 }
  ],
  "page": { "limit": 50, "offset": 0, "total": 1 },
  "queue": { "waiting": 14, "modes": 1, "sampled_at": 1785312000000, "age_ms": 420 }
}
```

Counts come from a sample the matchmaker publishes on each tick, so they are
up to one tick old - 1s by default - and `age_ms` says how old. Waits are
measured from the reading, so they keep growing between ticks. The read never
touches the matchmaker process itself; it cannot slow matchmaking down however
often it is polled.

No ticket, player id or ticket property appears here. Who is queued is player
data and waits on the capability model.

### Features

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
boolean only - never the configured value.

`extensions` is the resolved extension set, in dependency order and in the
same shape as `core`, so a client reads one row type:

```json
{ "name": "quests", "version": "1.0.0",
  "capabilities": [{ "name": "lua", "enabled": true },
                   { "name": "rpc", "enabled": true },
                   { "name": "tables", "enabled": true }] }
```

An extension's capabilities are the manifest keys it declares something under.
They say what it contributes, never what it contains - no method name, no
table name. `[]` when nothing is installed.

This is what a console reads to decide which of its built-in screens to
render, and to surface a version it was not built against.

### Ops authentication

Ops routes sit behind an operator credential, never a player token. Send the
configured operator secret as a bearer token:

```
GET /api/v1/ops/players
Authorization: Bearer <ops_secret>
```

Configure it with the `ops_secret` application env (see
[Configuration](configuration.md#ops-plane)). There is **no default**: a
deployment that has not set one rejects every ops request. A player or guest
token is rejected the same way - the ops plane never consults the player token
store at all.

Every rejection is `403` with `{"error": "forbidden"}`, whatever the cause. A
caller cannot tell an unconfigured deployment from a wrong secret.

A browser has a second transport for the same credential. `POST
/console/session` with `{"secret": "..."}` exchanges the operator secret for
an `HttpOnly` session cookie and a derived CSRF token; every later ops request
then carries the cookie plus `x-csrf-token` instead of the bearer header. A
cookie **without** a matching header is refused, so a cross-site request that
arrives with the browser's cookies attached gets 403.

A bearer token wins when both are present. See
[Configuration](configuration.md#operator-console).

Each route carries exactly one capability class - `read`, `player_data` or
`config` - and a request is admitted only if the credential holds that class.
Everything above is `read`. Role names never appear on the wire.

> #### One secret means one privilege level {: .warning}
>
> The static secret resolves to all three classes, so anyone holding it holds
> `config`. A studio cannot hand a community manager `player_data` without
> also handing over everything else. Restrict who reaches the console at all
> with a reverse proxy; per-person capabilities arrive with managed cloud,
> which mints a short-lived token carrying an explicit capability list.

Optionally send `x-asobi-operator: <name>` to name the human behind a shared
secret. It is attribution only: it is read after the credential is accepted,
it never affects what a request may do, and it is recorded unattested. A
label that is empty, multi-valued, over 64 bytes, or not printable ASCII is
dropped rather than trusted.

### Ops audit

Every ops-plane mutation writes a row to `ops_audit_entries`, carrying the
acting operator (`actor_id`, `actor_display`, `actor_source`,
`actor_attested`), the action, its subject, and when it happened. Reads are
not audited.

The routes above are all reads, so nothing above writes a row yet. The table
exists ahead of the write plane, and the one operator mutation that already
exists - broadcasting a notification - goes through it.

`actor_attested` is the important column. A name that came from
`x-asobi-operator` is self-declared, so it is stored `false`; only a verified
identity is stored `true`. Treat an unattested name as a hint, not evidence.

`outcome` is `ok`, `partial` or `error`, with `succeeded_count` and
`failed_count` beside it, so a fan-out that reached some of its subjects is
never recorded as a success. Per-subject reasons sit in `details` and are
diagnostic only; the counts are what you query.

Rows are append-only and core never prunes them. Retention is yours to set:
delete by `occurred_at`, which leads both composite indexes. Nothing cascades
into the table either, so deleting a player does not erase the record of what
was done to them.

An audit write never fails the operation it describes. It runs after the
change has already happened, so refusing the response could only invite a
retry that applies the change twice. If the insert fails, the row is emitted
instead at error level with the same field names, so ship your logs.

## Errors

A failing request returns its HTTP status and one object:

```json
{"error": {"code": "storage.not_found", "message": "No object exists at this collection and key.", "details": {}}}
```

- `code` is the contract. It is stable, machine-readable, and namespaced by
  domain (`storage.`, `save.`, `auth.`, `guest.`, `player.`, `match.`,
  `world.`, `matchmaker.`, `leaderboard.`, `economy.`, `inventory.`, `iap.`,
  `social.`, `chat.`, `dm.`, `tournament.`, `notification.`, `vote.`, `ops.`)
  or bare when it is cross-cutting (`rate_limited`, `forbidden`,
  `validation_failed`, `internal`). Branch on this.
- `message` is prose for a human reading a log. It may be reworded at any
  time. Do not parse it.
- `details` is **always** an object, `{}` when there is nothing to add, so no
  client needs a null branch. A version conflict, for example, carries what
  the client needs to retry:

```json
{"error": {"code": "save.version_conflict", "message": "The slot was written by another client.", "details": {"current_version": 4}}}
```

Codes are a closed set. A string supplied by a client, by an identity
provider, by a store's receipt verifier, or by a Lua game script never becomes
a code; it arrives inside `details` instead. So a rejected sign-in reads:

```json
{"error": {"code": "auth.provider_rejected", "message": "The identity provider rejected the token.", "details": {"reason": "publisher_banned"}}}
```

> #### Rollout {: .info}
>
> Every route returns this shape, as does every WebSocket `error` frame. There
> is no route left on the older, flat body (`{"error": "some_string"}`) and
> none that answers a failure with an empty body.
>
> The change is additive except for `error` itself, which went from a string
> to the object. A route that already sent more than `error` still sends it,
> unchanged and in the same place: `fields` and `errors` on a 422, `retry_after`
> on a 429, `field` and `order` on an ops sort rejection, `reason` on a
> registration-gate 403. Each of those is repeated inside `details`, so new
> code can read one place. The one key that moved is the bespoke top-level
> `message` on `POST /auth/guest` when guest auth is disabled; the same prose
> is now `error.message`.
>
> Statuses did not change. Routes that used to answer 403 or 404 with no body
> answer the same status, now with the object in it.

## Next steps

- [WebSocket protocol](websocket-protocol.md) - the push side of the API.
- [Authentication](authentication.md) - obtaining and refreshing the bearer token.
- [Economy & IAP](economy.md) - wallets, the store, and receipt validation.
