# Migrating from Nakama self-host to asobi

You run Nakama self-hosted on your own infrastructure. It works. Migrate only
if one of these applies:

- You want hot-reload of Lua that does not drop sessions on deploy. Editing a
  Nakama runtime module means restarting the server.
- You are hitting spatial or large-world use cases. asobi has zones, terrain
  chunks and adaptive tick rates as first-class primitives; Nakama's match
  handler is room-centric.
- You prefer the BEAM's supervision model over recovering from panics in a
  stateful realtime server.
- You want a single Apache-2.0 codebase with no commercial-only companions.

If none of those apply, stay on Nakama. Nakama and asobi are structurally the
closest cousins in this space, which makes the port straightforward and also
makes it pointless without a reason.

Nobody has migrated a shipped Nakama title to asobi yet. The asobi-side
endpoints and events below are verified against this repository; the
Nakama-side names come from Nakama's public documentation. Pair with us in the
[Discord](https://discord.gg/vYSfYYyXpu) `#migrations` channel if you hit a
gap.

## What asobi is

One Erlang/OTP node containing the game backend, the Lua runtime and the
operator console. Two ways in: run `ghcr.io/widgrensit/asobi` and write Lua, or
depend on the Hex package and write Erlang. Same node either way.

## Concept map

| Nakama | asobi | Notes |
|---|---|---|
| Match (authoritative) | Match | A process owning state, one per match. |
| Match handler | `match.lua`, or the `asobi_match` behaviour | Callbacks: `init`, `join`, `leave`, `handle_input`, `tick`, `get_state`. |
| Match handler loop tick | `tick(state)` | Matches tick every 100ms and that is fixed. `tick_rate` is a world-mode global; worlds default to 50ms. |
| Parties | Not supported | No matchmaker party grouping. Share a match or world id, or a join code, and join directly; gate entry in `join(player_id, state, ctx)`. |
| MatchmakerAdd | `POST /api/v1/matchmaker` | Body `{"mode": "...", "properties": {}}`. Returns `{"ticket_id": "...", "status": "pending"}`. |
| Storage engine | `GET/PUT/DELETE /api/v1/storage/:collection/:key` | Collection, key and owner, same model. Permissions are `read_perm` and `write_perm`, each `public` or `owner`. There is no `none`. |
| Storage, shared/global rows | Lua `game.storage.get/set` | The HTTP routes only ever touch per-player rows. The global namespace (no owner) is reachable from Lua only. |
| Leaderboards | `/api/v1/leaderboards/:id` | Submit, top, around. |
| Tournaments | `/api/v1/tournaments` | Scheduled, entry fees, rewards. |
| Friends | `/api/v1/friends` | Request, approve, block. |
| Groups | `/api/v1/groups` | Roles, join, leave, kick. |
| Chat channels | Chat channels plus WS `chat.send` / `chat.join` | Per-channel history. |
| Notifications | `/api/v1/notifications` | Plus the `notification.new` WebSocket push. |
| Wallets | Economy wallets (`/api/v1/wallets`) | Multi-currency ledgers. |
| Purchases | Economy store (`/api/v1/store/purchase`) | Spends an in-game wallet balance. |
| IAP receipts | `POST /api/v1/iap/apple`, `/api/v1/iap/google` | Verifies the receipt and records it once per transaction. It grants nothing: turning a verified receipt into currency or items is your game's job, via the economy or inventory API. |
| Authentication (device / custom) | `POST /api/v1/auth/guest` | Create-or-resume from a device-held secret; claim later with `/api/v1/auth/guest/upgrade`. Opt-in - see the note below the table. |
| Authentication (email) | `POST /api/v1/auth/register` and `/login` | Username plus password. |
| Authentication (Google / Apple / Steam) | `POST /api/v1/auth/oauth` | OAuth/OIDC. |
| RPC endpoints | Extension RPC over the WebSocket | Frame `rpc.call` with `{protocol: 1, method, params}`; replies `rpc.ok` `{result}` or `rpc.error` `{error: {code, message, details}}`, correlated by `cid`. All seven client SDKs support it. See [Extensions](extensions.md). |
| Hooks (`before_authenticate`, `after_friendAdd`) | Nova plugins and match lifecycle callbacks | Pre- and post-request middleware in Nova. |
| Runtime Lua / TS / Go | Lua for game logic, Erlang/OTP for the engine | One scripting language. |
| Nakama Console | Built-in operator console at `/console` | Off by default, and reads plus player erasure/export. See the note below the table. |
| Session token | `access_token` plus `refresh_token` | Register and login return `player_id`, `access_token`, `refresh_token` and `username`. There is no `session_token` field. |
| WebSocket | `/ws`, `session.connect` first frame | See the Hathora guide's [WebSocket handshake](migrate-from-hathora.md#websocket-handshake). |

Guest auth is off until two things are true: the game declares `guest_auth` in
its Lua config, and the operator supplies a pepper of at least 32 bytes. Either
one missing and `POST /api/v1/auth/guest` answers `guest.disabled`. See
[Authentication](authentication.md).

A stock node serves neither the console nor the ops API; you turn them on - see
[Operator console](console.md). When you do, the plane is reads plus player
erasure and export, apart from actions an extension declares. If you run Nakama Console to ban and kick, budget
for building that yourself.

## Migration path

### Phase 1 - stand up asobi alongside Nakama (0.5 days)

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

`./lua` must contain a `match.lua` before the matchmaker has anything to match
on - see Phase 2 below, or [Getting started](getting-started.md) for a complete
one. Without it, `POST /api/v1/matchmaker` answers `matchmaker.unknown_mode`.

`ASOBI_CORS_ORIGINS` is not optional for a browser client: unset, the node
sends an empty `Access-Control-Allow-Origin` and every fetch from a page is
blocked.

Requirements and the production compose are in
[Self-hosting](self-hosting.md).

### Phase 2 - port the runtime (1-3 days)

Nakama's Lua API is RPC-first:

```lua
local nk = require("nakama")
local function foo(context, payload)
  nk.logger_info("hello")
  local users = nk.storage_read({...})
  return nk.json_encode({ok = true})
end
nk.register_rpc(foo, "my_rpc")
```

asobi's is match-first. The match is the unit; the file is `match.lua`:

```lua
match_size = 2

function init(_config)
  return { players = {} }
end

function join(player_id, state)
  state.players[player_id] = { score = 0 }
  return state
end

function handle_input(player_id, input, state)
  if input.type == "score" then
    local p = state.players[player_id]
    p.score = p.score + 1
    game.broadcast("score", { player = player_id, score = p.score })
  end
  return state
end
```

Cross-match logic has three homes:

- `game.leaderboard.submit`, `game.economy.*`, `game.storage.*` and
  `game.notify` are callable from any match script. See the
  [Lua API](lua-api.md).
- Anything a client must call by name, that is not tied to a match, becomes an
  extension RPC method. That is the direct replacement for
  `nk.register_rpc`, and it reaches the client as `rpc.call` on the same
  WebSocket. See [Extensions](extensions.md).
- Scheduled work runs as a Shigoto job in Erlang.

If most of your Nakama logic is RPC-shaped rather than per-match, budget closer
to a week and expect to write an extension.

### Phase 3 - migrate the storage schema (1-2 days)

asobi's table is `storage`, not `asobi_storage`. Permissions are two columns,
`read_perm` and `write_perm`, each `public` or `owner`. `id` and `updated_at`
have no database default, so the insert must supply them.

```bash
pg_dump -U nakama -t storage -d nakama > storage-export.sql
```

Load that dump into a staging table, then:

```sql
INSERT INTO storage (id, collection, key, player_id, value, version, read_perm, write_perm, updated_at)
SELECT gen_random_uuid(), collection, key, user_id::uuid, value::jsonb, 1, 'owner', 'owner', now()
FROM nakama_storage_import;
```

asobi mints UUIDv7 for rows it creates; `gen_random_uuid()` gives v4, which is
fine for imported rows because nothing reads ordering off a storage id.

The same one-off-script pattern applies to leaderboards, friends, groups and
wallets. Column names differ; the schemas are in `src/` alongside each domain.

### Phase 4 - port the client (2-5 days)

| Nakama SDK | asobi SDK |
|---|---|
| `nakama-unity` | [asobi-unity](https://github.com/widgrensit/asobi-unity) |
| `nakama-godot` | [asobi-godot](https://github.com/widgrensit/asobi-godot) |
| `nakama-defold` | [asobi-defold](https://github.com/widgrensit/asobi-defold) |
| `nakama-unreal` | [asobi-unreal](https://github.com/widgrensit/asobi-unreal) |
| `nakama-js` | [asobi-js](https://github.com/widgrensit/asobi-js) |
| (none) | [asobi-love2d](https://github.com/widgrensit/asobi-love2d) |
| (none) | [asobi-dart](https://github.com/widgrensit/asobi-dart) |
| (none) | [flame_asobi](https://github.com/widgrensit/flame_asobi) |

`AuthenticateCustom` and `AuthenticateDevice` both become guest auth. On the
wire that is one POST and one WebSocket frame:

```bash
curl -s localhost:8084/api/v1/auth/guest \
  -H 'content-type: application/json' \
  -d '{"device_id":"<stable device id>","device_secret":"<base64 of >= 32 random bytes>"}'
# { "player_id": "019de3...", "access_token": "...", "refresh_token": "...",
#   "username": "...", "guest": true, "created": true }
```

```json
{"type":"session.connect","payload":{"token":"<access_token>"}}
```

Your SDK wraps both. Each SDK's own README carries the call names; this guide
does not restate them because they differ per language.

### Phase 5 - cut over (1 day)

Flip the client's base URL behind a feature flag. Monitor for 24h. Shut the
Nakama server down.

## What Nakama has that asobi does not

- Satori. asobi's LiveOps story is rougher.
- Hiro. asobi has tournaments and phases, and seasons ship as the
  [`asobi_seasons`](https://github.com/widgrensit/asobi_seasons) extension, but
  nothing as opinionated.
- Go and TypeScript runtimes. asobi is Lua or Erlang.
- A mutating operator console. asobi's ops plane erases and exports a player
  and nothing else, so moderation is a database write, a Lua handler or an
  extension action.
- Published case studies from large studios. asobi is newer.

## What asobi has that Nakama does not

- Live Lua reload without dropping players.
- Spatial zones and terrain, purpose-built for large-world games.
- Built-in voting (plurality, ranked, approval, weighted).
- Phases as a first-class primitive.
- Per-match process isolation under OTP supervision: a crash in one match does
  not leak into another, and there is no shared stop-the-world GC.

## Cost

Self-hosted Nakama and self-hosted asobi have similar infrastructure costs.
Both run on PostgreSQL. The operational differences that show up in a bill are
node count and how you deploy game-logic changes.

Node count is where asobi's clustering behaviour matters: the matchmaker queue
is per node, so players queuing against different nodes never match each other,
and rate limits are per node. Adding nodes is not free of design consequences.
[Clustering](clustering.md) has the full list.

## Do this today

- Run the Phase 1 compose locally and register a test player.
- Port one Nakama match handler to `match.lua`. Compare the feel.
- Join the [Discord](https://discord.gg/vYSfYYyXpu) `#migrations` channel and
  tell us what your runtime modules do.

## Getting help

- Discord: [#migrations](https://discord.gg/vYSfYYyXpu)
- Email: hello@asobi.dev
- GitHub Discussions:
  [widgrensit/asobi/discussions](https://github.com/widgrensit/asobi/discussions)

## See also

- [Migrating from Hathora](migrate-from-hathora.md)
- [Migrating from PlayFab](migrate-from-playfab.md)
- [Exit guarantee](exit.md)
- [Comparison](comparison.md)
