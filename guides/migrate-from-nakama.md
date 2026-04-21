# Migrating from Nakama self-host to asobi

You're running Nakama self-hosted on your own infra. It works. But maybe:

- You're tired of Nakama requiring **CockroachDB** (vs plain PostgreSQL
  everywhere else in your stack)
- You want **hot-reload of Lua** that doesn't drop sessions on deploy
  (Nakama issue [#192](https://github.com/heroiclabs/nakama/issues/192) has
  been open since 2018)
- You're bumping into **spatial / MMO** use cases Nakama wasn't designed
  for
- You prefer **BEAM's fault-tolerance** over Go's recovery-from-panic
  model for a stateful realtime server
- You want **Apache-2** without the BSL-adjacent ambiguity in some
  Heroic Cloud components

This guide walks you from a working Nakama deployment to an equivalent
asobi deployment. It's the most straightforward of the three migration
guides — Nakama and asobi are structurally the closest cousins in the
OSS backend space.

> **Draft notice.** This guide is a starting point, not a playbook —
> nobody has yet migrated a shipped Nakama title to asobi. The asobi-side
> endpoints and events below are verified against the current code.
> Nakama-side method names come from Nakama's public docs. **Pair with us
> in the [Discord](https://discord.gg/vYSfYYyXpu) `#migrations` channel
> if you hit an API gap.**

## Why migrate at all

Nakama is a fine product. We respect Heroic Labs. You should only migrate
if one of these reasons applies to you:

- **You need hot-reload.** Editing a Lua runtime module in Nakama requires
  a full server restart, which drops connections. asobi does it live via
  Luerl module swap.
- **Your infra is Postgres-only.** Moving CockroachDB off your ops plate
  is worth real money.
- **You're building an MMO / large-world game.** asobi has spatial zones,
  lazy-zone loading, terrain chunks, and adaptive tick rates as first-class
  primitives. Nakama's match handler is room-centric.
- **You want truly-free OSS.** Nakama is Apache-2 at the core but Heroic
  Cloud has commercial-only components (Satori, Hiro) that ease adoption.
  If you're committed to OSS-only, asobi is structurally simpler.

If none of those apply, stay on Nakama. Honestly.

## Concept map

Nakama and asobi agree on most of the vocabulary:

| Nakama | asobi | Notes |
|---|---|---|
| **Match** (authoritative) | Match | Same: a BEAM/goroutine process owning state. |
| **Match handler** (Lua / TS / Go) | `asobi_match` behaviour / `match.lua` | Callbacks: init, join, leave, handle_input, tick, get_state. |
| **Match Handler's LoopTick** | `tick(state)` | Same cadence (configurable). |
| **Parties** | Matchmaker tickets with `party` field | Send a list of player_ids in the ticket body. |
| **MatchmakerAdd** | `POST /api/v1/matchmaker` | Body: `{mode, properties, party}`. |
| **Storage Engine** | `/api/v1/storage/:collection/:key` | Collection+key+owner model is the same. Public/Owner/None permissions. |
| **Leaderboards** | Leaderboards (`/api/v1/leaderboards/:id`) | Submit/top/around queries. |
| **Tournaments** | Tournaments (`/api/v1/tournaments`) | Scheduled, entry fees, rewards. |
| **Friends** | Friends (`/api/v1/friends`) | Request/approve/block. |
| **Groups** | Groups (`/api/v1/groups`) | Roles, join/leave/kick. |
| **Chat channels** | Chat channels + WS `chat.send` / `chat.join` | Per-channel history. |
| **Notifications** | Notifications (`/api/v1/notifications`) | Plus WS push. |
| **Wallets** | Economy wallets (`/api/v1/wallets`) | Multi-currency ledgers. |
| **Purchases** | Economy store (`/api/v1/store/purchase`) | Integrates with IAP verification. |
| **Authentication (Custom / Device / Email)** | `/api/v1/auth/register` + `/login` | Username + password (you generate creds client-side for "custom" flows). |
| **Authentication (Google / Apple / Steam / ...)** | `/api/v1/auth/oauth` | OAuth/OIDC. |
| **RPC endpoints** | Nova controllers (Erlang) or Lua callbacks | For per-match logic, use Lua in `match.lua`. For cross-match workflows, write a Nova controller. |
| **Hooks (`before_authenticate`, `after_friendAdd`)** | Nova plugins + match lifecycle callbacks | Pre- and post-request middleware in Nova. |
| **Runtime Lua / TS / Go** | Luerl Lua (for match logic), Erlang/OTP (for the engine) | One scripting language (Lua); the engine is all OTP. |
| **Nakama Console** | [asobi_admin](https://github.com/widgrensit/asobi_admin) | Pre-1.0 admin surface. |
| **`sessiontoken`** | `session_token` | Same concept, returned from `/register` or `/login`. |
| **WebSocket** | `/ws` with `session.connect` first frame | See the Hathora guide's [WebSocket handshake](migrate-from-hathora.md#websocket-handshake) section for the protocol. |

## Migration path

### Phase 1 — stand up asobi alongside Nakama (0.5 days)

```yaml
# docker-compose.yml
services:
  postgres:
    image: postgres:17
    environment:
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: postgres
      POSTGRES_DB: my_game

  asobi:
    image: ghcr.io/widgrensit/asobi_lua:latest
    depends_on: [postgres]
    ports: ["8080:8080"]
    volumes: ["./lua:/app/game:ro"]
    environment:
      ASOBI_DB_HOST: postgres
      ASOBI_DB_NAME: my_game
```

Note: plain PostgreSQL, no CockroachDB. If you currently run Nakama
against Postgres-compatible Cockroach, you already have a backup strategy
that works here.

### Phase 2 — port the Lua runtime (1-3 days)

Nakama's Lua API:

```lua
local nk = require("nakama")
local function foo(context, payload)
  nk.logger_info("hello")
  local users = nk.storage_read({...})
  return nk.json_encode({ok = true})
end
nk.register_rpc(foo, "my_rpc")
```

asobi's Lua API differs in key ways — the match is the first-class unit,
not an RPC:

```lua
-- match.lua
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

For cross-match logic (leaderboards, global state, scheduled jobs):

- `game.leaderboard.submit("global", player_id, score)` in Lua
- Shigoto background jobs in Erlang for scheduled cross-match workflows
- Nova controllers in Erlang for custom REST endpoints (equivalent to
  Nakama RPCs)

If you have a lot of RPC-shaped logic (not per-match), budget Phase 2 for
closer to a week.

### Phase 3 — migrate the storage schema (1-2 days)

```bash
# Export from Nakama's Postgres (or CockroachDB):
pg_dump -U nakama -t storage -d nakama > storage-export.sql

# Transform storage rows to asobi's asobi_storage schema
psql -U postgres -d my_game -c "
  INSERT INTO asobi_storage (player_id, collection, key, value, permissions)
  SELECT user_id::uuid, collection, key, value::jsonb, 'owner'
  FROM old_nakama_storage;
"
```

The same pattern applies to leaderboards, friends, groups, and wallets.
Column names differ slightly (see the [Kura schemas](https://hexdocs.pm/asobi)
for the target shape) but the data is 1:1 translatable.

### Phase 4 — port the client (2-5 days)

Nakama client SDKs and asobi client SDKs map cleanly:

| Nakama SDK | asobi SDK |
|---|---|
| `nakama-unity` | [asobi-unity](https://github.com/widgrensit/asobi-unity) |
| `nakama-godot` | [asobi-godot](https://github.com/widgrensit/asobi-godot) |
| `nakama-defold` | [asobi-defold](https://github.com/widgrensit/asobi-defold) |
| `nakama-unreal` | [asobi-unreal](https://github.com/widgrensit/asobi-unreal) |
| `nakama-js` | [asobi-js](https://github.com/widgrensit/asobi-js) |

The Unity example:

```csharp
// Before (Nakama)
var client = new Client("defaultkey", "127.0.0.1", 7350, false);
var session = await client.AuthenticateCustomAsync(deviceId);
var socket = client.NewSocket();
await socket.ConnectAsync(session);

// After (asobi)
var client = new AsobiClient("https://api.my-game.com");
await client.Auth.RegisterAsync(deviceId, localPassword);   // or LoginAsync
await client.WebSocket.ConnectAsync();
client.WebSocket.SendSessionConnect(client.Session.Token);
```

### Phase 5 — cut over (1 day)

Flip the client's base URL via a feature flag. Monitor for 24h. Shut
down the Nakama server.

## Things Nakama has that asobi doesn't (yet)

- **Satori** (LiveOps platform). asobi's LiveOps story is rougher.
- **Hiro** (progression system). asobi has tournaments, seasons, and
  phases but nothing as opinionated as Hiro.
- **Go and TypeScript runtimes** as alternatives to Lua. asobi is Lua or
  Erlang — no JS/TS runtime.
- **Nakama Console** is further along than asobi_admin today.
- **Published case studies from AAA studios.** asobi is newer.

If you're deeply reliant on Satori, you'll need to build the equivalent
in asobi or accept the feature loss.

## Things asobi has that Nakama doesn't

- **Hot-reload Lua** — the [Nakama issue #192](https://github.com/heroiclabs/nakama/issues/192)
  that's been open since 2018
- **Plain PostgreSQL** — no CockroachDB requirement
- **Spatial zones / terrain** — purpose-built for large-world games
- **Built-in voting** (plurality / ranked / approval / weighted)
- **Phases and seasons** as first-class primitives
- **Per-match process isolation** via OTP supervision — crashes never
  leak between matches, no shared GC pauses

## Cost comparison

Self-hosted Nakama and self-hosted asobi have similar infrastructure
costs at the low end. The main operational difference:

| | Nakama self-host | asobi self-host |
|---|---|---|
| Database | CockroachDB (3-node recommended) | PostgreSQL (1 node is fine) |
| Hot ops | Restart on deploy | Live module swap |
| Clustering | Nakama's cluster mode + Consul | OTP `pg` / distributed Erlang |
| Typical idle cost | €30-60/mo (Cockroach is memory-hungry) | €5-15/mo |

If you're already running Postgres for other services, consolidating onto
one DB flavour is a meaningful win.

## Do this today

- [ ] `git clone` [asobi_lua](https://github.com/widgrensit/asobi_lua),
  `docker compose up`, register a test player.
- [ ] Port one Nakama RPC or match handler to `match.lua`. Compare the
  feel.
- [ ] Join the [Discord](https://discord.gg/vYSfYYyXpu) `#migrations`
  channel — tell us what your Lua runtime does and we'll sketch the port.

## Getting help

- **Discord**: [#migrations](https://discord.gg/vYSfYYyXpu) channel
- **Email**: hello@asobi.dev
- **GitHub Discussions**: [widgrensit/asobi_lua/discussions](https://github.com/widgrensit/asobi_lua/discussions)

## See also

- [Migrating from Hathora](migrate-from-hathora.md)
- [Migrating from PlayFab](migrate-from-playfab.md)
- [Exit guarantee](exit.md)
- [Comparison vs Nakama, Colyseus, SpacetimeDB](comparison.md)
