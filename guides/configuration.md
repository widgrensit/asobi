# Configuration

Asobi supports two configuration paths depending on how you use it.

> #### Do you even need this file? {: .info}
>
> On Asobi Cloud (`asobi deploy`) and the `asobi_lua` Docker image you write
> no config file at all - the platform supplies sane defaults and you tune the
> few knobs that matter through environment variables. You only edit
> `sys.config` when you build the release from source and embed asobi as an
> Erlang dependency.

## Lua (Docker)

For Lua game developers using the Docker image, configuration lives in
your Lua scripts. No Erlang syntax needed.

### Game Mode Config

Declare settings as globals at the top of your match script:

```lua
-- match.lua
match_size = 4
max_players = 10
strategy = "fill"
bots = { script = "bots/arena_bot.lua" }
```

| Global | Required | Default | Description |
|--------|----------|---------|-------------|
| `match_size` | yes | -- | Minimum players to start a match |
| `max_players` | no | `match_size` | Maximum players per match |
| `strategy` | no | `"fill"` | `"fill"`, `"skill_based"`, or custom |
| `bots` | no | none | `{ script = "path/to/bot.lua" }` |

### Multiple Game Modes

Add a `config.lua` manifest mapping mode names to scripts:

```lua
-- config.lua
return {
    arena = "arena/match.lua",
    ctf   = "ctf/match.lua"
}
```

### Infrastructure Config

Infrastructure settings come from environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `ASOBI_PORT` | `8084` | HTTP/WebSocket port |
| `ASOBI_DB_HOST` | `db` | PostgreSQL host |
| `ASOBI_DB_NAME` | `asobi` | Database name |
| `ASOBI_DB_USER` | `postgres` | Database user |
| `ASOBI_DB_PASSWORD` | `postgres` | Database password |
| `ASOBI_DB_SOCKET_OPTS` | `inet` (set by asobi_lua image; empty when consuming asobi directly) | Erlang term fragment spliced into the kura `socket_options` list. Examples: `inet`, `inet6`, `inet, {nodelay, true}`. Set to `inet6` for IPv6-only Postgres networks. |
| `ASOBI_CORS_ORIGINS` | `*` | Allowed CORS origins |
| `ASOBI_NODE_HOST` | `127.0.0.1` | Erlang node hostname |
| `ERLANG_COOKIE` | `asobi_cookie` | Erlang distribution cookie |

## Erlang (sys.config)

For Erlang OTP projects that add asobi as a dependency, all configuration
lives in `sys.config` under the `{asobi, [...]}` key.

### Game Modes

```erlang
{game_modes, #{
    ~"arena" => #{
        module => my_arena_game,
        match_size => 4,
        max_players => 8,
        strategy => fill
    }
}}
```

Lua scripts work too:

```erlang
{game_modes, #{
    ~"arena" => #{
        module => {lua, "game/match.lua"},
        match_size => 4,
        max_players => 8,
        strategy => fill
    }
}}
```

`{lua, ...}` needs a scripting runtime in the release. asobi itself has no Lua
dependency: [asobi_lua](https://github.com/widgrensit/asobi_lua) registers the
modules that run scripted modes (`asobi_game_modes:register_game_mode/2`) when it
starts. Consume asobi directly without it and every `{lua, _}` mode fails with
`{error, lua_runtime_unavailable}` — matchmaking rejects the mode as unknown and
world creation refuses it. Erlang-module modes are unaffected.

Shorthand (Erlang module only):

```erlang
{game_modes, #{
    ~"arena" => my_arena_game
}}
```

### Mode Options

| Option | Default | Description |
|--------|---------|-------------|
| `module` | required | Erlang module or `{lua, "path.lua"}` |
| `match_size` | `2` | Players needed to start a match |
| `max_players` | `10` | Maximum players per match |
| `strategy` | `fill` | Matchmaking strategy: `fill`, `skill_based`, or custom module |
| `skill_window` | `200` | Initial skill difference allowed (skill_based only) |
| `skill_expand_rate` | `50` | Window expansion per 5 seconds (skill_based only) |
| `bots` | `#{}` | Bot configuration. Read by [asobi_lua](https://github.com/widgrensit/asobi_lua), not by asobi — see [Bots](lua-bots.md) |
| `listed` | `false` for matches, `true` for worlds | Whether instances of this mode appear in discovery (`match.list` / `world.list`). **Matches are unlisted by default** — a matchmaker-spawned match is already assigned to its players, so opt in explicitly. |
| `quick_play` | `true` | Worlds only. Whether `world.find_or_create` may place a player into an existing world of this mode. Independent of `listed` — see [World Server](world-server.md#visibility). |

### Operator Modes vs Game-Declared Modes

Modes come from two independent places and asobi keeps them apart (ADR 0006):

- **Operator modes** are the ones above, in your `sys.config` `game_modes`.
  asobi never rewrites that key.
- **Game-declared modes** are what a Lua game declares in its `match.lua` or
  `config.lua` manifest. Loading a game replaces that set wholesale, so a mode
  you delete from `config.lua` is gone the next time the config loads instead
  of lingering until a restart.

The effective registry is the game-declared set with the operator set on top:
an operator mode wins a name clash and a game bundle can never drop or
redefine it. Read it with `asobi_game_config:modes/0` - the raw `game_modes`
app-env key is only the operator half.

## Matchmaker

```erlang
{matchmaker, #{
    tick_interval => 1000,     %% ms between matchmaker ticks (default 1000)
    max_wait_seconds => 60     %% ticket expiry (default 60)
}}
```

## Sessions

Session token lifetime is handled by Nova's `nova_auth_session` — configure
there (not under `asobi`). See the Nova docs for token/refresh TTL settings.

## Rate Limiting

Per-route-group rate limits using sliding window algorithm via
[Seki](https://github.com/Taure/seki).

```erlang
{rate_limits, #{
    auth => #{limit => 5, window => 1000},      %% 5 req/sec for login/refresh
    iap  => #{limit => 10, window => 1000},     %% 10 req/sec for IAP
    api  => #{limit => 300, window => 1000}     %% 300 req/sec for API
}}
```

Each route group has its own per-IP default (window in ms): `auth` 5/1000,
`register` 3/1000, `iap` 10/1000, `api` 300/1000, `ws_connect` 60/1000, and the
global (not per-IP) guest-create bound `guest_global` 100/1000. Override any
group under `rate_limits`; unset groups keep their default.

## WebSocket Origin allowlist

By default the `/ws` upgrade accepts any `Origin` — web builds are served from
arbitrary studio and hosting domains, so a strict default would break them.

To harden a deployment against cross-site WebSocket hijacking, set an
allowlist:

```erlang
{ws_allowed_origins, [
    ~"https://play.yourgame.com",
    ~"https://yourstudio.itch.io"
]}
```

When set, a browser upgrade whose `Origin` is not listed is closed with
`1008 origin_rejected` and emits `[asobi, ws, origin_rejected]`. Leaving it
unset (or empty) keeps the open default.

Match is **exact** against the value the browser sends, so copy that verbatim:
scheme + host + non-default port only — **no trailing slash, no path, all
lowercase, punycode (`xn--...`) for internationalised domains**, and each
entry a binary (`~"..."`), not a string. A trailing slash, an explicit `:443`,
or an uppercase host silently matches nothing and locks out real users. A
value that is not a list of binaries is treated as a misconfiguration and
**fails closed** (rejects everything) with a logged error, rather than
silently reverting to allow-all.

This is independent of [CORS](#cors): CORS governs XHR/fetch, not the WebSocket
handshake, so configuring one does not affect the other.

Native clients (Defold, Unity, Unreal, etc.) send no `Origin` header and are
never affected — an absent `Origin` always passes, since a non-browser client
cannot be a CSWSH vector. The socket also does nothing until it presents a
valid token in the first `session.connect` frame, so this is defence in depth,
not the primary auth gate.

## Deprecated `game.*` extension frames

Extension-produced pushes go out as `module.message` and `module.error`. The
pre-rename names `game.message` and `game.error` are emitted alongside them,
with identical payloads, so SDK builds from before the rename keep working.
They are removed at the 1.0 wire break.

```erlang
{ws_legacy_game_frames, false}
```

Set this once every client on the deployment dispatches on `module.*`, and
each extension message drops from two frames to one. `game.message` is
asobi_lua's `game.send/2`, which a script may call per player per tick, so on
a chatty game the compat frame is a real doubling of that path. Any client
still listening for `game.*` goes silent the moment you set it. Default
`true`. See
[the protocol guide](https://asobi.dev/docs/protocols/websocket).

## CORS

CORS is handled by `nova_cors_plugin` in the Nova plugin chain — configure
it under `{nova, [{plugins, [...]}]}`:

```erlang
{nova, [
    {plugins, [
        {pre_request, nova_cors_plugin, #{allow_origins => ~"https://mygame.com"}}
    ]}
]}
```

## Clustering

Optional multi-node clustering via Erlang distribution.

### DNS Strategy (recommended for Fly.io/Kubernetes)

```erlang
{cluster, #{
    strategy => dns,
    dns_name => "my-game.internal",
    poll_interval => 10000
}}
```

### EPMD Strategy (for static hosts)

```erlang
{cluster, #{
    strategy => epmd,
    hosts => ['node1@host1', 'node2@host2']
}}
```

## Authentication Providers

### OAuth/OIDC

```erlang
{oidc_providers, #{
    google => #{
        issuer => ~"https://accounts.google.com",
        client_id => ~"...",
        client_secret => ~"..."
    },
    apple => #{
        issuer => ~"https://appleid.apple.com",
        client_id => ~"...",
        client_secret => ~"..."
    }
}}
```

Every provider needs `issuer`, `client_id`, and `client_secret` - asobi discovers
the rest (authorize/token/JWKS endpoints) from the issuer's
`.well-known/openid-configuration` document. A provider entry missing
`issuer` fails asobi's boot - see [Authentication](authentication.md) for
the full supported-provider table and per-provider setup notes.

`base_url` is the public origin asobi uses to build OAuth/OIDC redirect URIs
(defaults to `~"http://localhost:8082"`). Set it to your deployed URL so the
redirect that providers call back to matches what you registered:

```erlang
{base_url, ~"https://mygame.com"}
```

### Steam

```erlang
{steam_api_key, ~"your-steam-web-api-key"},
{steam_app_id, ~"480"}
```

### Apple/Google IAP

```erlang
{apple_bundle_id, ~"com.example.mygame"},
{apple_root_cert_path, ~"/path/to/AppleRootCA-G3.pem"},
{google_package_name, ~"com.example.mygame"},
{google_service_account_key, ~"/path/to/service-account.json"}
```

`apple_root_cert_path` points at the Apple Root CA (PEM or DER) that
`asobi_iap:verify_apple/1` validates the StoreKit 2 receipt chain against.
Without it Apple receipt verification is refused.

## Guest (anonymous) auth

Guest auth lets a device create a throwaway player without credentials and
upgrade it to a real account later. It is **opt-in and fails closed**: the guest
endpoints return `403 guest_auth_disabled` until the **game** declares
`guest_auth = true` in its Lua config **and** the **operator** sets a
`guest_verifier_pepper` (ADR 0004). The toggle is a game global, not a
`sys.config` key - see [Authentication](authentication.md#guest-anonymous). This
page covers the operator half: the pepper and abuse controls.

```erlang
%% Required. A key-id -> pepper map (>= 32 bytes each). Keep old key ids for the
%% guest retention window so existing guests can still resume after rotation.
{guest_verifier_pepper, #{~"v1" => ~"a-32-byte-or-longer-secret......"}},
{guest_verifier_key_id, ~"v1"},

%% Optional abuse control: max unclaimed guests, or `infinity`.
{guest_unlinked_cap, 100000},

%% Optional retention. Unset = permanent guests (never reaped). Seconds after
%% which unclaimed guests are deleted by the reaper.
{guest_reap_after, 2592000}
```

| Key | Default | Description |
|-----|---------|-------------|
| `guest_verifier_pepper` | none | Key-id -> pepper map (each pepper >= 32 bytes) or a single >= 32-byte binary. Presence is the operator's on switch |
| `guest_verifier_key_id` | `~"v1"` | Which pepper key id to use when minting new verifiers |
| `guest_unlinked_cap` | `100000` | Soft ceiling on unclaimed guests, or `infinity` |
| `guest_reap_after` | unset | Seconds; unset disables the reaper (guests are permanent) |

The pepper is a server-side secret kept **outside** the database - store it in
an env var or secret manager, never in source. To rotate, add a new key id and
point `guest_verifier_key_id` at it; keep the old key ids for at least the
retention window so existing guests can still resume. Guest creation is bounded
by the per-IP auth limiter plus the global `guest_global` create limit.

## Ops plane

The `/api/v1/ops` routes are for a game-operations console, not a game client,
and they carry their own credential. **Fails closed**: unset the key and every
ops request is rejected, so a deployment that never reads this page is closed
rather than open. There is no default credential.

```erlang
%% Required to use /api/v1/ops at all. Random, >= 32 bytes.
{ops_secret, ~"a-32-byte-or-longer-random-secret"}
```

| Key | Default | Description |
|-----|---------|-------------|
| `ops_secret` | none | Operator bearer token for `/api/v1/ops`. Unset rejects every ops request |

Send it as `Authorization: Bearer <ops_secret>`. It is compared in constant
time and never leaves the server, so keep it in an env var or secret manager,
never in source. Player and guest tokens are rejected here - the ops plane
never consults the player token store.

One secret is one privilege level: whoever holds it holds every ops capability
class, including `config`. Restrict who can reach the console with a reverse
proxy, and set `x-asobi-operator` per person for attribution in the audit
trail - it is a label, never authority. See
[REST API](rest-api.md#ops-authentication).

## Vote Templates

Define reusable vote configurations:

```erlang
{vote_templates, #{
    ~"map_vote" => #{
        method => ~"plurality",
        window_ms => 15000,
        visibility => ~"live"
    },
    ~"boon_pick" => #{
        method => ~"plurality",
        window_ms => 15000,
        visibility => ~"live"
    }
}}
```

Templates are merged with per-vote config from your game module.

## World capacity

Bounds on persistent world creation, enforced as a DoS backstop:

```erlang
{world_max_per_player, 5},   %% default 5
{world_max, 1000}            %% default 1000
```

## Join rate

Joins are bounded per player, not per IP:

```erlang
{rate_limits, #{
    join => #{algorithm => sliding_window, limit => 10, window => 60000}
}}
```

Joining is how a client reaches a world's roster and leaving is free, so an
unbounded join rate lets one account enumerate every live world by joining,
reading `world.joined`, and leaving. The default (10 per minute) is generous
for real play and turns a sweep of a full deployment from seconds into hours
per identity. Exceeding it returns `join_rate_limited` and emits
`[asobi, join, rate_limited]`.

This bounds the cost of a sweep; it does not make worlds private. For that,
implement `join/3` in your game module and reject unauthorised joins - see
[WebSocket Protocol](websocket-protocol.md).

A player at the per-player cap gets `429`; once the global cap is reached
further creates get `503`.

## Zone crossing rate

For `world`-mode games, re-homing a player across a zone boundary is bounded
per player, not per IP:

```erlang
{rate_limits, #{
    rehome => #{algorithm => sliding_window, limit => 5, window => 1000}
}}
```

Each crossing updates part of the player's interest ring and resends a full
zone snapshot to any newly-subscribed zone, so an unbounded rate lets one
client force that work every tick by parking on (or jittering across) a zone
boundary. The default (5/sec) bounds the worst case on top of the crossing's
own hysteresis margin (see [World Server](world-server.md)); it caps sustained
crossing speed at `limit * zone_size` units/sec, so a fast-moving game (a
vehicle, flight sim, or racer) on a small `zone_size` may need to raise this.
Denied crossings are not dropped input - the player's position still updates
within their current zone, they just don't re-home that tick. Exceeding the
limit emits `[asobi, rehome, rate_limited]`.

## Terrain provider allowlist

For Lua large-world games, only allowlisted terrain generators can be named
from Lua. This is an `asobi_lua` key (not `asobi`):

```erlang
{asobi_lua, [
    {terrain_providers, [asobi_terrain_flat, asobi_terrain_perlin]}
]}
```

The default allows `asobi_terrain_flat` and `asobi_terrain_perlin`.

## Per-call upper bounds

These runtime limits bound the cost of a single request. They are not
configurable - they are documented here so you can size clients accordingly:

| Limit | Value |
|-------|-------|
| Cloud save body | 256 KB |
| Save slots per player | 10 |
| Inventory consume quantity | 1 .. 1000000 |
| Leaderboard `top` `?limit` | 1 .. 100 |
| Leaderboard `around` `?range` | 1 .. 50 |
| Chat history `?limit` | 1 .. 200 |
| DM content | 2000 bytes |
| WS chat channels per connection | 32 |
| Idle channel timeout | 60s |
| Lua table decode depth | 64 |

## Database (Kura)

Database configuration is under the `kura` application key:

```erlang
{kura, [
    {backend, kura_backend_postgres},
    {repo, asobi_repo},
    {host, "localhost"},
    {port, 5432},
    {database, "my_game_dev"},
    {user, "postgres"},
    {password, "postgres"},
    {pool_size, 10}
]}
```

## Background Jobs (Shigoto)

```erlang
{shigoto, [
    {pool, asobi_repo}
]}
```

## Full Example (Erlang sys.config)

```erlang
[
    {kura, [
        {backend, kura_backend_postgres},
        {repo, asobi_repo},
        {host, "localhost"},
        {database, "my_game_dev"},
        {user, "postgres"},
        {password, "postgres"},
        {pool_size, 20}
    ]},
    {shigoto, [
        {pool, asobi_repo}
    ]},
    {asobi, [
        {rate_limits, #{
            auth => #{limit => 10, window => 60000},
            api => #{limit => 300, window => 1000}
        }},
        {matchmaker, #{
            tick_interval => 1000,
            max_wait_seconds => 60
        }},
        {game_modes, #{
            ~"arena" => #{
                module => {lua, "game/match.lua"},
                match_size => 4,
                max_players => 8,
                strategy => fill,
                bots => #{
                    enabled => true,
                    fill_after_ms => 8000,
                    min_players => 4,
                    script => <<"game/bots/chaser.lua">>
                }
            }
        }}
    ]}
].
```

## Full Example (Lua Docker)

```yaml
# docker-compose.yml
services:
  postgres:
    image: postgres:17
    environment:
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: postgres
      POSTGRES_DB: my_game_dev
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 5s
      timeout: 5s
      retries: 5

  asobi:
    image: ghcr.io/widgrensit/asobi_lua:latest
    depends_on:
      postgres: { condition: service_healthy }
    ports:
      - "8084:8084"
    volumes:
      - ./lua:/app/game:ro
    environment:
      ASOBI_DB_HOST: postgres
      ASOBI_DB_NAME: my_game_dev
```

```lua
-- lua/match.lua
match_size = 4
max_players = 8
strategy = "fill"
bots = { script = "bots/chaser.lua" }

function init(config)
    return { players = {} }
end

-- ... rest of callbacks
```

```lua
-- lua/bots/chaser.lua
names = {"Spark", "Blitz", "Volt", "Neon"}

function think(bot_id, state)
    -- AI logic
end
```

## Next steps

- [Self-hosting](https://github.com/widgrensit/asobi_lua/blob/main/guides/self-hosting.md) - running the image.
- [Clustering](clustering.md) - multi-node config.
- [Performance tuning](performance-tuning.md) - the tick and BEAM knobs.
