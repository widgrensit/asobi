# Migrating from PlayFab to asobi

For studios who have been through the PlayFab v2 migration, watched features
get removed, or watched the Azure bill climb while the product got thinner. The
[Imperium42 write-up](https://medium.com/@imperium42/the-silent-death-of-playfab-29614f5b9f15)
catalogues the situation.

Nobody has migrated a shipped PlayFab title to asobi end to end yet. The
asobi-side endpoints and events below are verified against this repository;
PlayFab-side names come from Microsoft's public documentation. Pair with us in
the [Discord](https://discord.gg/vYSfYYyXpu) `#migrations` channel.

## What asobi is

One Erlang/OTP node containing the game backend, the Lua runtime and the
operator console. Two ways in: run `ghcr.io/widgrensit/asobi` and write Lua, or
depend on the Hex package and write Erlang. Same node either way. Apache-2.0,
self-hostable, and the [exit guide](exit.md) is the runbook for keeping your
game alive if we disappear.

## The shape of the move

1. Your Unity, Unreal or JS game keeps shipping. You do not touch the client on
   day one.
2. Stand up asobi in parallel.
3. Port one PlayFab API domain at a time.
4. When every domain is ported, flip a feature flag and retire the PlayFab
   Title.

## Concept map

| PlayFab | asobi | Notes |
|---|---|---|
| Title | Deployment | One container per environment. |
| TitleId plus SDK config | Base URL of your deployment | No opaque ID; you point the SDK at a URL. |
| Entity (`master_player_account`) | Player | Durable ID plus profile. |
| Virtual currency | Economy | `game.economy.grant`, `debit`, `balance`, `purchase` in Lua; `/api/v1/wallets` over REST. Multiple named currencies, per-player ledgers. |
| Catalog | Store plus item definitions | `GET /api/v1/store`, `POST /api/v1/store/purchase`. |
| Inventory | Inventory | `GET /api/v1/inventory` and `POST /api/v1/inventory/consume`, or Kura queries against the `asobi_player_item` schema (table `player_items`). There is no Lua binding for inventory. |
| CloudScript (JS functions) | Lua callbacks, or an extension RPC method | Per-match logic goes in `match.lua`. Anything a client calls by name goes over the WebSocket as `rpc.call` - see below the table. No separate Functions runtime, no cold starts. |
| Matchmaking (queue) | `POST /api/v1/matchmaker` | Modes plus pluggable strategies (`fill`, `skill_based`, or your own via the `asobi_matchmaker_strategy` behaviour). |
| Multiplayer Server (build) | Match process | No container per match. One container hosts thousands of matches as BEAM processes. |
| Data, player key-value | `/api/v1/storage/:collection/:key` | Per-player rows. Permissions are `read_perm` and `write_perm`, each `public` or `owner`. There is no `none`. |
| Data, Title Data | Lua `game.storage.get/set` | The HTTP storage routes are scoped to per-player rows, so writing to a collection called `global` gives every player their own copy. The shared, owner-less namespace is reachable from Lua only. |
| Data, Title Internal Data | Erlang `sys.config` or a Kura schema | Sensitive config stays off the player-facing API. |
| Leaderboards and statistics | `/api/v1/leaderboards/:id` | ETS for reads, PostgreSQL for persistence. |
| Friends list | `/api/v1/friends` | Request, approve, block, update status. |
| Player groups | `/api/v1/groups` | Roles, member management, a chat channel per group. |
| Push notifications | Notifications plus a WebSocket push | `GET /api/v1/notifications`, or the `notification.new` frame on the socket. This is in-game delivery, not APNs or FCM. |
| PlayFab Party (voice and chat) | Chat channels plus DMs | Text only. For voice, pair asobi with a voice service. |
| Receipt validation (IAP) | `POST /api/v1/iap/apple`, `/api/v1/iap/google` | Verifies an Apple or Google receipt and records it once per transaction. |
| Granting from a receipt | Your game's job | Nothing is granted by the IAP endpoints. Turn a verified receipt into currency or items yourself through the economy or inventory API. |
| Automation rules and webhooks | Shigoto jobs | Written as an Erlang callback. |
| Insights and analytics | `asobi_telemetry` plus your own pipeline | Telemetry is emitted; there is no hosted analytics. |
| Game Manager (web console) | Built-in operator console at `/console` | Off by default, and reads plus player erasure/export. See the note below the table. |

Custom server-side logic that is not tied to a match goes over the WebSocket:
frame type `rpc.call` with `{protocol: 1, method, params}`, answered by
`rpc.ok` `{result}` or `rpc.error` `{error: {code, message, details}}`,
correlated by `cid`. All seven client SDKs support it. That is the CloudScript
replacement. See [Extensions](extensions.md).

A stock node serves neither the console nor the ops API; you turn them on - see
[Operator console](console.md). When you do, the plane is reads plus player
erasure and export, apart from actions an extension declares. If you use Game Manager to ban a player, refund a
purchase or edit a catalogue item, budget for building that yourself.

## Migration path

### Phase 1 - stand up asobi alongside PlayFab (1 day)

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
      ASOBI_CORS_ORIGINS: "https://play.my-game.com"
      ASOBI_CONSOLE: "true"
      ASOBI_OPS_SECRET_FILE: /run/secrets/ops_secret
    secrets: [ops_secret]

secrets:
  ops_secret:
    file: ./ops_secret.txt
```

`./lua` must contain a `match.lua` before the matchmaker has anything to match
on - [Getting started](getting-started.md) has a complete one. Without it,
`POST /api/v1/matchmaker` answers `matchmaker.unknown_mode`.

`ASOBI_CORS_ORIGINS` is not optional for a browser build: unset, the node sends
an empty `Access-Control-Allow-Origin` and every fetch from a page is blocked.

```bash
docker compose up -d
curl -s localhost:8084/api/v1/auth/register \
  -H 'content-type: application/json' \
  -d '{"username":"alice","password":"hunter2"}'
# { "player_id": "019de3...", "access_token": "...", "refresh_token": "...", "username": "alice" }
```

There is no `session_token`. `access_token` is the Bearer credential;
`refresh_token` buys a new pair from `POST /api/v1/auth/refresh`. Requirements
and the production compose are in [Self-hosting](self-hosting.md).

### Phase 2 - port auth (2-5 days)

`LoginWithCustomID` maps to guest auth. The client generates a random
`device_secret` of at least 32 bytes on first launch and posts it with a stable
`device_id`; the server creates the player, or resumes it on later launches:

```bash
curl -s localhost:8084/api/v1/auth/guest \
  -H 'content-type: application/json' \
  -d '{"device_id":"<stable device id>","device_secret":"<base64 of >= 32 random bytes>"}'
```

Treat `device_secret` as that account's password and keep it in secure device
storage; every SDK does this for you. Claim the account later with
`POST /api/v1/auth/guest/upgrade`.

Guest auth is opt-in and off until two things are true: the game declares
`guest_auth` in its Lua config, and the operator supplies a pepper of at least
32 bytes. Either one missing and the endpoint answers `guest.disabled`. See
[Authentication](authentication.md).

OAuth providers go through `POST /api/v1/auth/oauth`, replacing
`LoginWithGoogleAccount` and friends.

### Phase 3 - port the data domains one at a time (1-2 weeks)

Run PlayFab and asobi in parallel. Per domain:

- Migrate the PlayFab snapshot into asobi's Postgres schema with a one-off
  script.
- Dual-write: the client hits both for the same action.
- Read from asobi, diff against PlayFab for a day.
- Switch reads to asobi, keep the PlayFab write for rollback.
- After a week of clean reads, stop writing to PlayFab.

Order: leaderboards, inventory, virtual currency, storage, friends, groups,
matchmaking. Matchmaking last, because it is the most stateful handoff.

### Phase 4 - port CloudScript (2 days to 2 weeks)

Each CloudScript function becomes one of three things:

- A Lua callback in `match.lua`, for per-match logic.
- An extension RPC method, for anything a client calls by name. This is the
  closest equivalent and the one most CloudScript functions map onto. See
  [Extensions](extensions.md).
- A Shigoto job, for scheduled work such as a daily reset.

The upside is that live Lua reload replaces the CloudScript deploy loop.

### Phase 5 - cut over (1 day)

Flip the SDK base URL behind a feature flag. Monitor for 24h. Retire the
PlayFab Title.

## What asobi does not do

- No hosted analytics dashboard. Telemetry is emitted; you pipe it somewhere.
  This is the biggest gap against PlayFab Insights.
- No A/B testing or segmentation framework.
- No push notification service. Use APNs, FCM or a third party directly; the
  built-in notifications are in-game only.
- No hosted voice.
- Little player-support tooling. The console erases and exports a player;
  refunds, bans and grants are your own code.
- No Entity model. `player_id` is the primary key and you are not required to
  model everything as an entity with objects.

## What asobi does that PlayFab does not

- Live Lua reload without dropping players.
- Open source: read it, fork it, run it.
- Linux servers throughout.
- One matchmaker rather than several overlapping services.
- Friends, groups, chat, votes, tournaments and phases as first-class
  primitives; seasons ship as the
  [`asobi_seasons`](https://github.com/widgrensit/asobi_seasons) extension.
- Built-in voting: plurality, ranked, approval, weighted.
- First-class Godot, Defold and LÖVE SDKs alongside Unity, Unreal, JS and
  Dart, plus a Flame bridge on top of the Dart one.

## Cost

PlayFab bills tiers, metered analytics and VM-minute multiplayer servers. asobi
is a container whose cost you choose, plus a Postgres. A single node holds
3,000-7,000 concurrent WebSocket connections in measurement - see
[Benchmarks](benchmarks.md) - so most studios' first deployment is one small
machine.

If you plan to run more than one node, read [Clustering](clustering.md) first:
the matchmaker queue is per node, so players queuing against different nodes
never match each other, rate limits are per node, and the console needs a
sticky route.

## Do this today

- Run the Phase 1 compose locally and register a player.
- Pick the smallest PlayFab API your game calls, usually leaderboards or one
  CloudScript function, and port it behind a feature flag.
- Join the [Discord](https://discord.gg/vYSfYYyXpu) `#migrations` channel.

## Getting help

- Discord: [#migrations](https://discord.gg/vYSfYYyXpu)
- Email: hello@asobi.dev
- GitHub Discussions:
  [widgrensit/asobi/discussions](https://github.com/widgrensit/asobi/discussions)

## See also

- [Migrating from Hathora](migrate-from-hathora.md)
- [Migrating from Nakama self-host](migrate-from-nakama.md)
- [Exit guarantee](exit.md)
- [Comparison](comparison.md)
