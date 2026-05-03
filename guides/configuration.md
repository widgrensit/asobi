# Configuration

Asobi supports two configuration paths depending on how you use it.

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
| `ASOBI_PORT` | `8080` | HTTP/WebSocket port |
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
| `bots` | `#{}` | Bot configuration (see [Bots](lua-bots.md)) |

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
    auth => #{limit => 10, window => 60000},    %% 10 req/min for auth
    iap  => #{limit => 300, window => 1000},    %% 300 req/sec for IAP
    api  => #{limit => 300, window => 1000}     %% 300 req/sec for API
}}
```

Default: 300 requests per second for all groups.

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
        client_id => ~"...",
        client_secret => ~"...",
        discovery_url => ~"https://accounts.google.com/.well-known/openid-configuration"
    },
    discord => #{
        client_id => ~"...",
        client_secret => ~"...",
        authorize_url => ~"https://discord.com/api/oauth2/authorize",
        token_url => ~"https://discord.com/api/oauth2/token",
        userinfo_url => ~"https://discord.com/api/users/@me"
    }
}}
```

### Steam

```erlang
{steam_api_key, ~"your-steam-web-api-key"},
{steam_app_id, ~"480"}
```

### Apple/Google IAP

```erlang
{apple_bundle_id, ~"com.example.mygame"},
{google_package_name, ~"com.example.mygame"},
{google_service_account_key, ~"/path/to/service-account.json"}
```

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

## Database (Kura)

Database configuration is under the `kura` application key:

```erlang
{kura, [
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
      - "8080:8080"
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
