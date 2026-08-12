# REST API

All endpoints are under `/api/v1`. Requests and responses use JSON.

Authenticated endpoints require the `Authorization: Bearer <access_token>` header.

> #### Real-time flows go over WebSocket {: .info}
>
> Use REST for request/response. Matchmaking notifications, chat, votes,
> presence, and live game state are pushed over the [WebSocket
> protocol](websocket-protocol.md), not polled here.

**Windows / PowerShell.** The examples below use `curl` (Linux, macOS, Git
Bash, WSL). In PowerShell, translate any block by hand once - the shape is the
same:

```powershell
Invoke-RestMethod -Uri http://localhost:8084/api/v1/auth/register `
  -Method Post -ContentType application/json `
  -Body '{"username": "player1", "password": "secret123"}'
```

Add auth with `-Headers @{ Authorization = "Bearer $token" }`.
`Invoke-RestMethod` parses the JSON response for you, so no `jq` is needed.

## Auth

```
POST   /api/v1/auth/register        Register a new player
POST   /api/v1/auth/login           Sign in, returns an access + refresh pair
POST   /api/v1/auth/refresh         Exchange a refresh token for a new pair
POST   /api/v1/auth/logout          Revoke the current tokens
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

### Logout

Unauthenticated, because it accepts a token that may already have expired.
Send the refresh token in the body to kill the whole refresh family; the
access token in the `Authorization` header is revoked too, so it cannot
outlive its cache TTL.

```bash
curl -X POST /api/v1/auth/logout \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -d '{"refresh_token": "..."}'
```

```json
{"success": true}
```

Always **200**, including with no body and no header at all: logout is
idempotent and reports nothing about which token was valid.

### Guest

Anonymous device-based auth, opt-in via config. `POST /auth/guest` creates a
player on first call and resumes the same one on later calls; `/auth/guest/upgrade`
(authenticated) claims it with a username and password. To delete a guest, use
[the account-erasure route](#erasing-your-own-account) - guest removal is not a
guest-specific endpoint. See the
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

`created` is present only on the call that created the player. A resume
returns the same body without it, so treat a missing `created` as `false`
rather than expecting the key.

To delete a guest account, call
[`POST /players/me/erase`](#erasing-your-own-account) on its session. No
`password` is needed, because a guest has none.

## Players

```
GET /api/v1/players/:id        Get player profile
PUT /api/v1/players/:id        Update own profile
```

### Erasing your own account

```
POST /api/v1/players/me/erase
```

Erases the calling player and everything core holds about them. The subject is
always the caller - the id comes from the session and there is no id in the
path or body - so this route can never reach another account. An operator
erasing somebody else is a different route with a different credential:
[`/ops/players/:id/erase`](#erasing-and-exporting-a-player).

An account with a password must echo it. One without - a guest, or a
provider-only account - has no credential the client can re-present, so its
session is the whole confirmation.

```bash
# password account
curl -X POST /api/v1/players/me/erase \
  -H 'Authorization: Bearer <access_token>' \
  -H 'Content-Type: application/json' \
  -d '{"password": "secret123"}'

# guest or provider-only account
curl -X POST /api/v1/players/me/erase \
  -H 'Authorization: Bearer <access_token>' \
  -H 'Content-Type: application/json' -d '{}'
```

```json
{"deleted": true}
```

POST rather than DELETE because the confirmation travels in the body, and a
DELETE body has no defined semantics - the same shape the operator route uses.

Irreversible, and it takes the children with it: wallets, ledger, inventory,
storage, cloud saves, notifications, leaderboard entries, chat, group
memberships, friendships, stats, sessions and identities. Purchase receipts are
severed rather than deleted, for the reason described under
[the operator route](#erasing-and-exporting-a-player). Every erasure writes an
audit row whose actor is the player themselves.

A refused confirmation is `403`, not `401`, on purpose: the caller is
authenticated and failed a step-up check, so an SDK that treats `401` as
"refresh the token pair and replay the request" must not do either of those
things here.

**The session dies with the account.** A retried call after a successful one
answers `401`, not `200` or `404`, because the token it presents was deleted
inside the same transaction. A client whose request timed out should read a
subsequent `401` as "it worked", not as "sign in again".

| Status | `error.code` | Meaning |
|--------|--------------|---------|
| `400`  | `missing_field` | The account has a password and the body carried none |
| `401`  | `unauthenticated` | No session, or the account is already gone |
| `403`  | `player.confirmation_failed` | The password does not match. Nothing was deleted, and the session is still valid |
| `409`  | `player.credentials_changed` | The password changed while the request was in flight. Nothing was deleted; retry |
| `429`  | `rate_limited` | Erasure has its own tight bucket, because the wrong-password path runs the password KDF |
| `500`  | `player.erase_failed` | The transaction rolled back. Nothing was deleted |

## Worlds

```
GET  /api/v1/worlds         Browse live worlds
GET  /api/v1/worlds/:id     Get one world
POST /api/v1/worlds         Create a world
```

`GET /api/v1/worlds` accepts `mode` (ignored above 64 bytes) and
`has_capacity=true`. Only worlds whose mode sets `listed` (the default for a
world; set `listed = false` in the script to hide one) are returned. Results
are cached for 500ms.

`POST /api/v1/worlds` returns **201** with the world info, **429**
`world.player_limit_reached` when the player is at their per-player cap, and
**503** `world.capacity_reached` when the global cap is reached. See
[World capacity](configuration.md#world-capacity). The equivalent
`world.create` failures over WebSocket carry no code of their own - see the
[WebSocket protocol](websocket-protocol.md).

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
lobby browser wants. It accepts `mode`, `has_capacity=true` and
`joinable=true|false`. Matches are **unlisted by default** - a mode opts in
with `listed = true` (a Lua global, or `listed => true` in the operator's
`game_modes` config) - so an empty result usually means no mode has opted in
yet.

Every entry carries `joinable`, and a browser looking for somewhere to play
should filter on both it and `has_capacity`: a match with room may have closed
itself to new players, and a full one has not closed. `running` matches are
included, because a running match takes joins - that is how backfill works.

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
GET  /api/v1/store                     List store catalogue
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

`GET /api/v1/leaderboards/:id` accepts `?limit`, default 100, clamped to
1-100. `GET .../around/:player_id` accepts `?range`, default 5, clamped to
1-50, and returns that many entries either side. A non-numeric value falls
back to the default rather than erroring.

`POST /api/v1/leaderboards/:id` is **off by default** and answers **403**
`leaderboard.client_submit_disabled`. Scores are normally submitted from game
code, where the client cannot forge them. An operator opts a board in by
listing its id under the `leaderboard_client_submit` application env, or by
setting that to `all` - reasonable for a casual scoreboard where cheating
does not matter, wrong for anything competitive.

A board that is full answers **503** `leaderboard.capacity_reached`.

## Matchmaking

```
POST   /api/v1/matchmaker              Submit matchmaking ticket
GET    /api/v1/matchmaker/:ticket_id   Check ticket status
DELETE /api/v1/matchmaker/:ticket_id   Cancel ticket
```

A ticket is only valid on the node that issued it. The queue lives in one
process per node and there is no ticket table, so a status check or a cancel
that lands on a second node answers **404** `matchmaker.ticket_not_found` for
a ticket that is very much alive elsewhere. A cluster needs a sticky route
pinning all three calls for one player to one node. Another player's ticket is
**403** `forbidden`. See [Clustering](clustering.md).

Ticket outcomes are pushed over WebSocket, not polled here.

## Tournaments

```
GET  /api/v1/tournaments               List active tournaments
GET  /api/v1/tournaments/:id           Get tournament details
POST /api/v1/tournaments/:id/join      Join tournament
```

## Votes

```
GET /api/v1/matches/:id/votes    List votes for a match (newest first, max 50)
GET /api/v1/votes/:id            Get a single vote with full results
```

The match list is **participant-only**: a caller who is not on the match's
roster gets **403** `forbidden`, whether the match is live or finished. A
vote whose visibility is `hidden` and whose status is not yet `resolved` has
its `votes_cast` field withheld, so a participant cannot read who voted for
what while the vote is still open.

Voting itself happens over WebSocket. See the [Voting guide](voting.md).

## Chat

```
GET /api/v1/chat/:channel_id/history   Message history
```

Requires membership of the channel: a non-member gets **403** `forbidden`, and
so does a malformed channel id. `?limit` defaults to 50 and is clamped to
1-200, oldest-first within the window.

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
GET /api/v1/ops/stats                        Runtime health of this node
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

GET  /api/v1/ops/players/:id/export          Everything held about one player
POST /api/v1/ops/players/:id/erase           Delete one player. Irreversible.

GET|POST|PUT|DELETE
    /api/v1/ops/ext/:extension/:action       Dispatch to an installed extension
```

The game-operations plane, for a console rather than a game client. The lists
differ from the ones above in three ways: they report a total, they accept a
sort, and they page by offset.

Everything here is a read except two account-lifecycle routes - see
[Erasing and exporting a player](#erasing-and-exporting-a-player) - and
`/api/v1/ops/ext/:extension/:action`, whose behaviour comes from an installed
extension.

These routes do **not** accept player tokens. They are their own auth plane -
see [Ops authentication](#ops-authentication) below. For turning the console
on, the environment variables and the operator narrative, see
[Operator console](console.md).

### What is node-local and what is not

Four of these read live process state on the node that answers, so behind a
load balancer two consecutive reads can disagree and neither is wrong:

| Route | What it reads |
| --- | --- |
| `ops/stats` | This node's VM. `online_players` is the exception: presence is a cluster-wide process group, so that one gauge is fleet-wide. |
| `ops/features` | This node's resolved extension set and configured capabilities. |
| `ops/matchmaker` | This node's queue. The whole matchmaker is per node. |
| `ops/chat/channels` | The chat channels running on this node. |

Every other ops route reads Postgres and is therefore consistent whichever
node answers. See [Clustering](clustering.md).

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
| `order` | `asc` (default) or `desc`, matched case-insensitively, so `DESC` works. Anything else is **400**. |
| `q` | Case-insensitive substring search. `%` and `_` are matched literally. Only on the lists with something to search: not the queue, a board's entries, or listings. |

`page` has its own ceiling of 10000 on top of the offset clamp, so the
deepest reachable window is whichever of `page * limit` and 100000 is
smaller.

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

### Players

### Erasing your own account

```
POST /api/v1/players/me/erase
```

Erases the calling player and everything core holds about them. The subject is
always the caller - the id comes from the session and there is no id in the
path or body - so this route can never reach another account. An operator
erasing somebody else is a different route with a different credential:
[`/ops/players/:id/erase`](#erasing-and-exporting-a-player).

An account with a password must echo it. One without - a guest, or a
provider-only account - has no credential the client can re-present, so its
session is the whole confirmation.

```bash
# password account
curl -X POST /api/v1/players/me/erase \
  -H 'Authorization: Bearer <access_token>' \
  -H 'Content-Type: application/json' \
  -d '{"password": "secret123"}'

# guest or provider-only account
curl -X POST /api/v1/players/me/erase \
  -H 'Authorization: Bearer <access_token>' \
  -H 'Content-Type: application/json' -d '{}'
```

```json
{"deleted": true}
```

POST rather than DELETE because the confirmation travels in the body, and a
DELETE body has no defined semantics - the same shape the operator route uses.

Irreversible, and it takes the children with it: wallets, ledger, inventory,
storage, cloud saves, notifications, leaderboard entries, chat, group
memberships, friendships, stats, sessions and identities. Purchase receipts are
severed rather than deleted, for the reason described under
[the operator route](#erasing-and-exporting-a-player). Every erasure writes an
audit row whose actor is the player themselves.

A refused confirmation is `403`, not `401`, on purpose: the caller is
authenticated and failed a step-up check, so an SDK that treats `401` as
"refresh the token pair and replay the request" must not do either of those
things here.

**The session dies with the account.** A retried call after a successful one
answers `401`, not `200` or `404`, because the token it presents was deleted
inside the same transaction. A client whose request timed out should read a
subsequent `401` as "it worked", not as "sign in again".

| Status | `error.code` | Meaning |
|--------|--------------|---------|
| `400`  | `missing_field` | The account has a password and the body carried none |
| `401`  | `unauthenticated` | No session, or the account is already gone |
| `403`  | `player.confirmation_failed` | The password does not match. Nothing was deleted, and the session is still valid |
| `409`  | `player.credentials_changed` | The password changed while the request was in flight. Nothing was deleted; retry |
| `429`  | `rate_limited` | Erasure has its own tight bucket, because the wrong-password path runs the password KDF |
| `500`  | `player.erase_failed` | The transaction rolled back. Nothing was deleted | and matches

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

There is no broadcast route here. The broadcast is an in-process entry point
that writes an audit row - see [Ops audit](#ops-audit).

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
      "version": "0.68.2",
      "capabilities": [{ "name": "guest_auth", "enabled": true }]
    },
    "extensions": []
  }
}
```

Capabilities report what is *configured*, not what is compiled in, and carry a
boolean only - never the configured value. `lua` is the one exception: it is a
module check, and it is true in every stock release because the Lua runtime
ships in asobi.

`extensions` is the resolved extension set, in dependency order and in the
same shape as `core`, so a client reads one row type:

```json
{ "name": "quests", "version": "1.0.0",
  "capabilities": [{ "name": "console", "enabled": true },
                   { "name": "lua", "enabled": true },
                   { "name": "ops", "enabled": true },
                   { "name": "rpc", "enabled": true },
                   { "name": "tables", "enabled": true }] }
```

An extension's capabilities are the seams it declares something under, plus
`console` for one that ships operator screens - which is a file check rather
than a manifest key. They say what it contributes, never what it contains - no
method name, no action name, no table name. `[]` when nothing is installed.

This is what a console reads to decide which of its screens to render, and to
surface a version it was not built against.

### Stats

`GET /api/v1/ops/stats` is the runtime health of **one node**. Everything in
it comes from the VM or from presence, so it stays answerable when Postgres
is the thing that is unwell.

```json
{
  "data": {
    "node": "asobi@10.0.1.7",
    "online_players": 412,
    "process_count": 8134,
    "process_limit": 262144,
    "memory_total": 184549376,
    "memory_processes": 71303168,
    "memory_ets": 12582912,
    "memory_binary": 33554432,
    "run_queue": 0,
    "scheduler_count": 8,
    "uptime_ms": 864000000
  }
}
```

`node` is in the response because every node serves its own copy of this
endpoint and the numbers are per node. Behind a load balancer a reading
without a node name is a reading you cannot act on: poll every node and key
the results on this field.

`online_players` is the one fleet-wide figure here, and it is `null` rather
than an error if presence is momentarily unavailable. Memory gauges are
bytes; `uptime_ms` is wall-clock milliseconds since this node booted.

There is no push variant. The console polls.

### Extension actions

`/api/v1/ops/ext/:extension/:action` is the one ops route core owns on behalf
of extensions, and the one route on the plane that can mutate. Everything
about it comes from the installed extension's manifest: which actions exist,
which HTTP method each answers, which capability class it needs, and what it
does.

An action nobody declared has no class, and an untagged route is denied, so
an unknown extension, an unknown action and a method the action does not
answer are all **403**, never 404. Enumerating which extensions are installed
is not something an unauthorised caller gets to do. `GET /api/v1/ops/features`
is where an authorised caller reads the installed set.

A `get` action receives the parsed query string; any other method receives the
decoded JSON body. Both arrive as a map with string keys. On success the
handler's own object is the response body verbatim, with no `data` envelope
around it, so this route does not share the shape the lists above use. A
failure is the shared error object, carrying a code the extension declared -
an undeclared code is refused and answered `internal`.

Every method other than `get` is wrapped in the audit path, so an extension
cannot write on this plane without core recording who asked. Declaring a
method other than `get` is what opts an action in; there is nothing to
configure.

That recording is currently incomplete. Only a failure returned without
details reaches `ops_audit_entries`; a successful call, and a failure carrying
details, raise inside the audit path and are logged at error level as
`ops audit row not written`, carrying the action but not the row's own
fields. The call itself still runs and still answers normally. Ship your logs
and treat them as part of the audit trail until that is fixed.

While the node is still running migrations the route answers **503**
`not_ready`, before the extension's handler runs.

### Ops authentication

Ops routes sit behind an operator credential, never a player token. Send the
configured operator secret as a bearer token:

```
GET /api/v1/ops/players
Authorization: Bearer <ops_secret>
```

There is **no default** secret. A deployment that has not set one rejects
every ops request, so the plane is closed until an operator opens it. A player
or guest token is rejected the same way: the ops plane never consults the
player token store at all.

The `console` setting gates the `/console` routes, not this one. An ops secret
alone makes `/api/v1/ops/*` answerable without the console being on. For
setting both, see [Operator console](console.md).

Every rejection is **403** with the same body every other failure on this API
returns:

```json
{"error": {"code": "forbidden", "message": "The caller may not perform this action.", "details": {}}}
```

That is the body whatever the cause. An unconfigured deployment, a wrong
secret and a credential that lacks the route's capability class are
indistinguishable to the caller, deliberately.

A bearer token wins when both it and a console cookie are present.

Each route carries exactly one capability class - `read`, `player_data`,
`config` or `erasure` - and a request is admitted only if the credential holds
that class. Every core route is `read` except the two account-lifecycle ones;
an extension action's class comes from its manifest. Role names never appear
on the wire.

`erasure` is separate from `player_data` for one reason, and it is not
sensitivity: it is the only class whose actions cannot be undone by a later
call. The operator secret sent as a bearer token holds all four. A console
session holds every class **but** `erasure` unless `console_erasure` is set to
`true` - same secret, different transport, different blast radius.

### Erasing and exporting a player

```
GET  /api/v1/ops/players/:id/export
POST /api/v1/ops/players/:id/erase
```

`export` returns everything core holds about one player, keyed by table, each
row through a positive allowlist. Credentials are never in it: no
`hashed_password`, and a session is reported as having existed without its
bearer token. Class `player_data`, not `read` - a leaderboard view is one
thing, and the whole of one identified person's record is another.

The payload also names every installed extension under an `extensions` key:
the data its `export_player/1` returned, or a `skipped` marker when the
extension does not export one - a skipped extension is visible in the
artefact, never silently absent. An extension that fails to export fails the
whole request with `500 ops.export_incomplete`, and no partial artefact is
returned. See [Extensions](extensions.md).

`erase` deletes the player and every row core holds for them, in one
transaction, and it cannot be undone. The body must echo the player's username
and the server checks it against the row:

```bash
curl -X POST \
  -H "Authorization: Bearer $ASOBI_OPS_SECRET" \
  -H 'Content-Type: application/json' \
  -d '{"username": "kaito"}' \
  https://game.example.com/api/v1/ops/players/019f.../erase
```

```json
{"data": {"player_id": "019f...", "erased": true}}
```

A missing echo is `ops.confirmation_required` and a wrong one is
`ops.confirmation_mismatch`, both 400. Neither reaches the deletion.

Two tables survive with the player reference set to `NULL` rather than being
deleted: `iap_transactions`, because a refund or chargeback dispute needs the
real-money receipt, and `groups.creator_id`, because deleting the group would
destroy every other member's data. Everything else goes, including the wallet,
its ledger, saves, storage, chat messages, friendships and identities.

Three columns hold player ids with no foreign key, and they keep them:
`match_records.players`, `votes.votes_cast` and `zone_snapshots.entities`. The
ids no longer resolve to anybody - the schema stores bare uuids and nothing
else about the person, so deleting `players` and `player_identities` *is* the
anonymisation. `zone_snapshots.entities` is opaque game-defined state, so a
game that puts personal data in it owns erasing that itself; see
[Extensions](extensions.md).

The erasure writes its own audit row inside the same transaction, so "erased"
and "recorded as erased" are one commit (ADR 0007). Installed extensions erase
first, in that transaction; one refusing aborts the whole deletion and the
player survives intact.

You do not need the ops plane for this. A self-hoster with a release and a
remote shell can call the same function, and it is the same code path:

```erlang
1> asobi_player_erase:run(~"019f...").
{ok,#{player_id => <<"019f...">>,erased => true}}
2> asobi_player_export:run(~"019f...").
{ok,#{player => #{...}, wallets => [...], ...}}
```

There is no player-facing self-delete. Whether players may erase themselves is
a support-load and abuse decision belonging to the game - it turns an account
takeover into an account destruction - so asobi gives the operator the
primitive and the game decides whether to expose it.

### Console session

A browser has a second transport for the same credential. These three routes
are outside `/api/v1` and are not themselves behind the ops credential - the
login endpoint cannot require the credential it exists to accept.

```
GET    /console/session   Who this browser is, if anyone
POST   /console/session   Exchange a credential for a session
DELETE /console/session   End the session
```

`POST` takes `{"secret": "..."}` and an optional `"label"`, the display name
the audit trail carries for this session. It defaults to `operator`, it is
self-asserted, and it is held to the same shape as the `x-asobi-operator`
header.

```bash
curl -X POST http://localhost:8084/console/session \
  -H 'Content-Type: application/json' \
  -d '{"secret": "'"$ASOBI_OPS_SECRET"'", "label": "kaito"}'
```

```json
{"data": {"display": "kaito", "expires_at": 1785355200, "csrf": "..."}}
```

Two cookies come back. `asobi_console` holds the session id and is `HttpOnly`,
so page script cannot read it. `asobi_console_csrf` holds the CSRF token and
is deliberately **not** `HttpOnly`, because the page has to send it back as an
`x-csrf-token` header and holding it only in memory would end the session on
every reload. Every later ops request carries the cookie plus that header
instead of the bearer token; a cookie without a matching header is refused, so
a cross-site request that arrives with the browser's cookies attached gets
403. `DELETE` is the exception and needs the cookie only, since it can only
ever destroy authority.

Both cookies are `SameSite=Lax`, path `/`, and `Secure` whenever the request
looks like TLS directly or through a proxy that says so. The `x-csrf-token`
header, not the cookie attribute, is what stops a cross-site write.

`GET` returns the actor behind the session and requires both the cookie and
the header, like any other ops read.

```json
{"data": {"display": "kaito", "source": "local_user", "caps": ["read", "player_data", "config"], "attested": false}}
```

A session resolves only on the node that minted it: the store is an ETS table
owned by one process on that node, and the secret the CSRF token is derived
from is generated at boot. Restarting the node ends every session in flight,
and a round-robin load balancer 403s most console requests. Pin the console to
one node. Sessions expire absolutely, after 12 hours by default, and reading
one does not extend it.

Every route in this group answers **404** when the console is switched off,
which is the same 404 an unknown path gets. For the model, the environment
variables and the credentials, see [Operator console](console.md).

**One secret means one privilege level.** The static secret resolves to all
three classes, so anyone holding it holds `config`. A studio cannot hand a
community manager `player_data` without handing over everything else. Restrict
who reaches the console at all with a reverse proxy. Per-person capabilities
need the second credential shape the plane accepts: a minted token carrying an
explicit capability list and a short expiry, issued by a control plane rather
than configured on the node.

Optionally send `x-asobi-operator: <name>` to name the human behind a shared
secret. It is attribution only: it is read after the credential is accepted,
it never affects what a request may do, and it is recorded unattested. A
label that is empty, multi-valued, over 64 bytes, or not printable ASCII is
dropped rather than trusted.

### Ops audit

Every ops-plane mutation is wrapped so it writes a row to `ops_audit_entries`,
carrying the acting operator (`actor_id`, `actor_display`, `actor_source`,
`actor_attested`), the action, its subject, and when it happened. Reads are
not audited.

Three things go through the audit path: player erasure, an extension action
reached over `/api/v1/ops/ext/:extension/:action`, and the in-process
notification broadcast entry point. The player export is a read and is not
audited.

`actor_attested` is the important column. A name that came from
`x-asobi-operator` is self-declared, so it is stored `false`; only a verified
identity is stored `true`. Treat an unattested name as a hint, not evidence.

`outcome` is `ok`, `partial` or `error`, with `succeeded_count` and
`failed_count` beside it, so a fan-out that reached some of its subjects is
never recorded as a success. Per-subject reasons sit in `details` and are
diagnostic only; the counts are what you query.

Rows are append-only and core never prunes them, so retention is yours to set.
No index leads on `occurred_at`: it is the second column of the
`(actor_id, occurred_at)` and `(action, occurred_at)` composites, and the only
other index is on `target_id`. A delete scoped to time alone therefore scans
the table. Prune in batches, off-peak, or add an index on `occurred_at` if you
intend to prune by time on a schedule.

Nothing cascades into the table, so erasing a player does not erase the record
of what was done to them - `actor_id` and `target_id` are plain strings with no
foreign key. That is what lets an erasure's own row outlive its subject.

Erasure is the one exception to "the audit never fails the operation". Its row
is written **inside** the erasure transaction, so a failed audit insert rolls
the deletion back: the data is gone by definition, so the row is the only
surviving evidence the request was honoured. Every other mutation audits after
the fact and cannot be failed by it (ADR 0007).

A guest-retention sweep writes no rows. It is the machine's own housekeeping
over up to 500 accounts a pass, and it logs a count instead.

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
  `social.`, `chat.`, `dm.`, `tournament.`, `notification.`, `vote.`, `ops.`,
  `rpc.`, `console.`, `ws.`) or bare when it is cross-cutting
  (`internal`, `rate_limited`, `join_rate_limited`, `payload_too_large`,
  `invalid_json`, `invalid_message`, `invalid_payload`, `missing_field`,
  `unknown_type`, `unauthenticated`, `forbidden`, `validation_failed`,
  `length_required`, `client_gate_denied`, `not_ready`). Branch on this. The
  whole set is one list in `asobi_error`, and an extension may add codes only
  in its own domain.
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

Every route returns this shape, as does every WebSocket `error` frame. No
route is left on the older, flat body (`{"error": "some_string"}`), and none
answers a failure with an empty body.

A route that already sent more than `error` still sends it, unchanged and in
the same place: `fields` and `errors` on a 422, `retry_after` on a 429,
`field` or `order` on an ops sort rejection, `reason` on a
`client_gate_denied` 403. Each is repeated inside `details`, so new code reads
one place. Statuses are unchanged; a route that answered 403 or 404 with no
body answers the same status with the object in it.

## Next steps

- [WebSocket protocol](websocket-protocol.md) - the push side of the API.
- [Authentication](authentication.md) - obtaining and refreshing the bearer token.
- [Economy & IAP](economy.md) - wallets, the store, and receipt validation.
