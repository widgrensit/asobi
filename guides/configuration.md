# Configuration

All Asobi configuration lives in your `sys.config` file under the `{asobi, [...]}` key.

## Game Modes

Define one or more game modes. Each mode maps a name to a module and match settings.

### Erlang Module

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

### Lua Script

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

### Shorthand (Erlang only)

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

```erlang
{session, #{
    token_ttl => 900,          %% access token lifetime in seconds (default 15 min)
    refresh_ttl => 2592000     %% refresh token lifetime in seconds (default 30 days)
}}
```

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

```erlang
{cors_allow_origins, ~"https://mygame.com"}
```

Default: `"*"` (allow all origins). Set to your domain in production.

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

## Full Example

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
        {cors_allow_origins, ~"*"},
        {session, #{
            token_ttl => 900,
            refresh_ttl => 2592000
        }},
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
                    script => "game/bots/chaser.lua",
                    names => [~"Spark", ~"Blitz", ~"Volt", ~"Neon"]
                }
            }
        }}
    ]}
].
```
