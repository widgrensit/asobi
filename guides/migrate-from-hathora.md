# Migrating from Hathora to asobi

Hathora's game-hosting service shut down on 2026-05-05. This guide takes you
from "we need a new backend" to a running asobi deployment.

Nobody has migrated a Hathora game to asobi end to end yet. The asobi-side
endpoints and events below are verified against this repository; the
Hathora-side method names are from memory of the pre-shutdown SDK and may have
drifted. The fastest route is pairing with us in the
[Discord](https://discord.gg/vYSfYYyXpu) `#migrations` channel.

This guide targets studios on Hathora's managed service. Self-hosted
`hathora-core` users have a different problem - skip to
[Self-hosted Hathora users](#self-hosted-hathora-users).

## What asobi is

One Erlang/OTP node containing the game backend, the Lua runtime and the
operator console. Two ways in: run `ghcr.io/widgrensit/asobi` and write Lua, or
depend on the Hex package and write Erlang. Same node either way.

## Today, in 15 minutes

Four steps. They unblock you even if the full port takes a week.

**1. Write a minimal game.** asobi loads Lua from `/app/game`, and without a
mode declared there the matchmaker has nothing to match on. In an empty
directory:

```lua
-- lua/match.lua

match_size = 2

function init(_config)
    return { players = {} }
end

function join(player_id, state)
    state.players[player_id] = { score = 0 }
    return state
end

function leave(player_id, state)
    state.players[player_id] = nil
    return state
end

function handle_input(_player_id, _input, state)
    return state
end

function tick(state)
    return state
end

function get_state(_player_id, state)
    return { players = state.players }
end
```

**2. Stand the backend up.** Next to `lua/`:

```yaml
services:
  postgres:
    image: postgres:17
    environment:
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: postgres
      POSTGRES_DB: my_game
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 5s

  asobi:
    image: ghcr.io/widgrensit/asobi:latest
    depends_on:
      postgres: { condition: service_healthy }
    ports: ["8084:8084"]
    volumes: ["./lua:/app/game:ro"]
    environment:
      ASOBI_DB_HOST: postgres
      ASOBI_DB_NAME: my_game
      ASOBI_CORS_ORIGINS: "http://localhost:5173"
      ASOBI_CONSOLE: "true"
      ASOBI_OPS_SECRET_FILE: /run/secrets/ops_secret
    secrets: [ops_secret]

secrets:
  ops_secret:
    file: ./ops_secret.txt
```

`openssl rand -hex 32 > ops_secret.txt`, then `docker compose up -d`. HTTP is on
`:8084`, the WebSocket is on `/ws`, the console is on `/console`.

`ASOBI_CORS_ORIGINS` is not optional for a browser client: unset, the node
sends an empty `Access-Control-Allow-Origin` and every fetch from a page is
blocked.

**3. Register one player.**

```bash
curl -s localhost:8084/api/v1/auth/register \
  -H 'content-type: application/json' \
  -d '{"username":"test","password":"test1234"}'
# { "player_id": "019de3...", "access_token": "...", "refresh_token": "...", "username": "test" }
```

`access_token` is what the client passes as `Authorization: Bearer ...` from
here on. `refresh_token` buys a new pair from `POST /api/v1/auth/refresh`.
There is no `session_token` anywhere in asobi.

**4. Queue for matchmaking.**

```bash
curl -s localhost:8084/api/v1/matchmaker \
  -H 'content-type: application/json' \
  -H 'authorization: Bearer <access_token>' \
  -d '{"mode":"default","properties":{}}'
# { "ticket_id": "019de3...", "status": "pending" }
```

A 400 with `matchmaker.unknown_mode` means the node found no mode called
`default`, which almost always means `lua/match.lua` is not mounted where step
2 puts it.

Then open a tracking issue at
[github.com/widgrensit/asobi/issues](https://github.com/widgrensit/asobi/issues)
and say hello in the [Discord](https://discord.gg/vYSfYYyXpu) `#migrations`
channel with your setup: engine, language, lobby versus matchmaker,
server-authoritative versus P2P. We will tell you which sections below apply to
you.

## The full port, in outline

1. Your game-server logic keeps running in its own process while you migrate.
2. asobi comes up alongside it. Your game server talks to it over WebSocket
   like any other auth, matchmaker or leaderboard service.
3. You port the Hathora-specific calls to the equivalents in the concept map.
4. Once asobi owns auth, matchmaking and lobbies, you drop Hathora and either
   keep your game server in a plain container, or fold its logic into a
   `match.lua` and delete the container.

For most Hathora games the game server is a few hundred lines of state
mutation, which is well within the scope of one Lua file.

## Concept map

| Hathora | asobi | Notes |
|---|---|---|
| Application | asobi deployment | One container per environment. |
| Room | Match | One process per match; state lives in the process heap. |
| Process | No equivalent | asobi does not spin a container per match. One container hosts thousands of matches as BEAM processes. |
| Lobby | Matchmaker ticket plus a match in its waiting phase | `POST /api/v1/matchmaker`; when `match_size` is reached the match starts. |
| Region | Deployment location | One container per region, chosen by you. There is no region abstraction. |
| Matchmaker 2.0 | `asobi_matchmaker` | Strategies `fill` and `skill_based`, or your own via the `asobi_matchmaker_strategy` behaviour. |
| `HathoraClient.loginAnonymous` | `POST /api/v1/auth/guest` | Device-backed anonymous auth: `device_id` plus `device_secret`, and you get a real player back. Claim it later with `POST /api/v1/auth/guest/upgrade`. Opt-in - see the note below the table. |
| `HathoraClient.loginGoogle` | `POST /api/v1/auth/oauth` | OAuth/OIDC. |
| `createLobby`, `createRoom`, queue | `POST /api/v1/matchmaker` | Body `{"mode": "...", "properties": {}}`, response `{"ticket_id": "...", "status": "pending"}`. |
| Ticket poll | `GET /api/v1/matchmaker/:ticket_id` | |
| Cancel | `DELETE /api/v1/matchmaker/:ticket_id` | |
| `listActivePublicLobbies` | `GET /api/v1/matches/live` | Live, joinable matches; filter with `mode` and `has_capacity`. Matches are unlisted by default and a mode opts in with `listed = true` (a Lua global, or `listed => true` in the operator's `game_modes` config). Not `GET /api/v1/matches`, which is the finished-match record table. |
| `getConnectionInfo(roomId)` | WebSocket upgrade on `GET /ws` | See [WebSocket handshake](#websocket-handshake). The first frame must authenticate. |
| Custom room messages | Extension RPC | Frame `rpc.call` with `{protocol: 1, method, params}`; replies `rpc.ok` `{result}` or `rpc.error` `{error: {code, message, details}}`, correlated by `cid`. All seven client SDKs support it. See [Extensions](extensions.md). |
| `ping` region API | None | Probe each deployment endpoint yourself if you need client-side region selection. |
| Hathora SDK | asobi SDKs | [Unity](https://github.com/widgrensit/asobi-unity), [Unreal](https://github.com/widgrensit/asobi-unreal), [JS/TS](https://github.com/widgrensit/asobi-js), [Godot](https://github.com/widgrensit/asobi-godot), [Defold](https://github.com/widgrensit/asobi-defold), [LÖVE](https://github.com/widgrensit/asobi-love2d), [Dart](https://github.com/widgrensit/asobi-dart), [Flame](https://github.com/widgrensit/flame_asobi). |
| Hathora Console | Built-in operator console at `/console` | Off by default, and reads plus player erasure/export. See the note below the table. |
| `hathora.yml` | `docker-compose.yml` | Plain Compose, no proprietary spec. |

Guest auth is off until two things are true: the game declares `guest_auth` in
its Lua config, and the operator supplies a pepper of at least 32 bytes. Either
one missing and `POST /api/v1/auth/guest` answers `guest.disabled`. See
[Authentication](authentication.md).

A stock node serves neither the console nor the ops API; you turn them on - see
[Operator console](console.md). When you do, the plane is reads plus player
erasure and export, apart from actions an extension declares. Coming from the Hathora console you will look for
a restart-this-process button; there is not one, because there is no process per
match to restart.

## Migration path

### Phase 1 - stand up asobi alongside Hathora (1 day)

Use the compose file from step 2 above, on the same cloud or locally, without
touching the Hathora deployment. Goal: auth, a lobby and a match working end to
end from your client. Requirements and the production compose are in
[Self-hosting](self-hosting.md).

### Phase 2 - port the client SDK calls (2 to 5 days)

Swap the Hathora SDK for the asobi SDK for the same engine. Do it one feature
at a time: auth first, then the WebSocket handshake, then matchmaking, then the
game-session messages. Hathora and asobi coexist in the client during this
phase behind different base URLs.

Matchmaker tickets resolve asynchronously over the WebSocket as `match.matched`
with payload `{match_id, players}`. Polling
`GET /api/v1/matchmaker/:ticket_id` works too.

Each SDK's README carries its own call names; this guide does not restate them
because they differ per language.

### WebSocket handshake

asobi expects every WebSocket client to authenticate with a `session.connect`
frame before any other message type is accepted. The payload field is `token`,
carrying the `access_token` from register, login or guest:

```json
{"type":"session.connect","payload":{"token":"<access_token>"}}
```

The server replies:

```json
{"type":"session.connected","payload":{"player_id":"019de3..."}}
```

A missing or misspelled `token` field is not a shape error - it is treated as a
token that did not resolve, so the reply is an error frame carrying the wire
code `unauthenticated`:

```json
{"type":"error","payload":{"reason":"invalid_token","error":{"code":"unauthenticated","message":"The credentials are missing, expired, or invalid.","details":{}}}}
```

After a successful handshake the server routes match, matchmaker, chat and
world events to this player. The message types a client may send are:

`session.connect`, `session.heartbeat`, `matchmaker.add`, `matchmaker.remove`,
`match.join`, `match.leave`, `match.input`, `match.list`, `world.create`,
`world.find_or_create`, `world.join`, `world.leave`, `world.input`,
`world.list`, `chat.send`, `chat.join`, `chat.leave`, `dm.send`,
`presence.update`, `vote.cast`, `vote.veto`, `rpc.call`.

Server-pushed types follow `{domain}.{event}`: `match.matched`, `match.state`,
`match.finished`, `world.tick`, `world.terrain`, `chat.message`, `dm.message`,
`notification.new`, `error`, plus any leaf name your script broadcasts under
`match.` or `world.`. The full reference is
[WebSocket protocol](websocket-protocol.md).

### Phase 3 - port the game logic (2 days to 2 weeks)

**Option A - keep your existing game server.** If you have a lot of C# or Go
server code you would rather not rewrite, keep running it in its own container.
Use asobi for auth, matchmaking, lobbies, leaderboards and persistence. When
the matchmaker fires `match.matched`, the client has an `access_token` from
asobi; pass it, plus `player_id` and `match_id`, to your game server over your
own connection, and have your game server check the token with asobi before
accepting input.

There is no dedicated server-to-server token-introspection route. Check a token
by calling any authenticated GET with it (`GET /api/v1/friends` is a cheap one)
and treating 200 as accepted, 401 as not. Two caveats before you build on it:
no core route reliably reports the caller's own `player_id` - a friends,
notifications or saves response carries it only on rows the player already has,
and is empty otherwise - so a 200 proves the token is valid, not whose it is.
And do not use `POST /api/v1/auth/refresh` for the check. That endpoint takes a
`refresh_token`, not an access token, so an access token simply fails there;
and a refresh token rotates the pair, with a second presentation of a rotated
token revoking the whole token family and logging the player out. If you
need real introspection, an extension can add it: an RPC handler receives the
caller's `player_id` in its context. See [Extensions](extensions.md).

**Option B - fold the game logic into Lua.** Rewrite your tick, input and state
logic as a `match.lua`, using the six callbacks from step 1:

- `init(config)` - once per match, returns the initial state
- `join(player_id, state)` and `leave(player_id, state)`
- `handle_input(player_id, input, state)` - one client `match.input` frame
- `tick(state)` - every 100ms
- `get_state(player_id, state)` - the per-player view

Matches tick every 100ms and that is fixed; `tick_rate` is a world-mode
setting. You get live reload for free - edit, save, and the next tick
re-evaluates the file against the running state - and you delete a container.
See [Lua scripting](lua-scripting.md).

### Phase 4 - cut over (1 day)

Point the client at the asobi endpoint behind a feature flag. Monitor for 24h.
Shut Hathora down.

## Deploy story

asobi runs anywhere Docker runs. The managed version is
[asobi.dev/cloud](https://asobi.dev/cloud), the same open-source core.

A single node holds 3,000-7,000 concurrent WebSocket connections in
measurement, at 4.4ms p50 round-trip with 3,500 of them - see
[Benchmarks](benchmarks.md). Most games' first deployment is one small machine
plus a Postgres, which is where the saving against process-hour billing comes
from.

If you plan on more than one node, read [Clustering](clustering.md) first: the
matchmaker queue is per node, so players queuing against different nodes never
match each other, rate limits are per node, and the console needs a sticky
route.

## Self-hosted Hathora users

If you run `hathora-core` on your own infrastructure you still own the stack
and can keep running it as long as it works. The same migration strategy
applies when you decide to move.

## Things asobi does not do

- **No UDP transport.** WebSocket over TCP only. The cost is the retransmission
  tail on a lossy path, not the median RTT: TCP will not deliver the next state
  frame until it has redelivered the lost one. A twitch FPS, fighting game or
  racer should run the simulation over its own UDP netcode and use asobi for
  auth, matchmaking, economy, leaderboards and social.
- **Guest auth is opt-in and off by default.** It exists and it is device-backed
  rather than a throwaway username, but it stays off until the game declares
  `guest_auth` and the operator supplies a pepper of at least 32 bytes.
- **No server-to-server token introspection route.** See Option A above.
- **No automatic multi-region.** One container per region, deployed by you.
- **No rollback netcode or lag compensation.** No server-side replay, no hitbox
  rewind; over TCP (above) asobi is not for twitch shooters. But the server half
  of *client-side prediction* is a first-class primitive: the client stamps each
  `world.input` with an increasing `seq`, and the server returns the highest one
  it has consumed as a `world.ack` on that connection for the client to
  reconcile against. See
  [Client-side prediction](websocket-protocol.md#client-side-prediction).
- **Pre-1.0 API.** Minor breaking changes are possible until 1.0.

## Do this today

- Run the compose from step 2 locally and register a player.
- Pick one SDK call in your client to port first, usually `loginAnonymous`.
- Join the [Discord](https://discord.gg/vYSfYYyXpu).
- Decide Option A or Option B and open a thread in
  [Discussions](https://github.com/widgrensit/asobi/discussions).

## Getting help

- Discord: [#migrations](https://discord.gg/vYSfYYyXpu)
- Email: hello@asobi.dev
- GitHub Discussions:
  [widgrensit/asobi/discussions](https://github.com/widgrensit/asobi/discussions)

## See also

- [Migrating from PlayFab](migrate-from-playfab.md)
- [Migrating from Nakama self-host](migrate-from-nakama.md)
- [Exit guarantee](exit.md)
- [Comparison](comparison.md)
