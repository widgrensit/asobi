# Configuration

asobi is one node with two surfaces. Run the image and configure it from the
environment plus your Lua scripts, or depend on the Hex package and configure it
in `sys.config`. This page is the reference for both.

Version floors, supported Postgres and the image's architecture live in
[Self-hosting](self-hosting.md#requirements).

## Lua (Docker)

For Lua game developers using the image, configuration lives in your Lua
scripts. No Erlang syntax needed.

### Game mode config

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
| `match_size` | yes | none | Minimum players to start a match |
| `max_players` | no | `match_size` | Maximum players per match |
| `strategy` | no | `"fill"` | `"fill"`, `"skill_based"`, or a custom module |
| `bots` | no | none | `{ script = "path/to/bot.lua" }` - see [Bots](lua-bots.md) |
| `game_type` | no | `"match"` | `"match"` or `"world"` |
| `listed` | no | `false` for matches, `true` for worlds | Whether instances appear in discovery (`match.list` / `world.list`). Never gates joining |
| `quick_play` | no | `true` | Whether `world.find_or_create` may place a player into an existing instance of this mode |
| `state_strategy` | no | none | `"shared"` selects the encode-once broadcast path |
| `guest_auth` | no | `false` | Declares that this game offers anonymous play. The operator still has to supply a pepper |
| `registration` | no | none | `"open"`, `"oauth_only"` or `"closed"`. The operator's `sys.config` wins when it sets one |

World-mode games (`game_type = "world"`) read a further set of globals -
`tick_rate`, `grid_size`, `zone_size`, `view_radius`, `persistent`,
`lazy_zones`, `zone_idle_timeout`, `max_active_zones`,
`spatial_grid_cell_size`, `cold_tick_divisor`, `empty_grace_ms`,
`player_ttl_ms`. [World server](world-server.md) documents those.

**Where you put `guest_auth` and `registration` matters.** They are read from
`match.lua` in single-mode and from `config.lua` in multi-mode. A game with a
`config.lua` manifest that declares `guest_auth = true` in `match.lua` instead
gets nothing, silently: the config loader reads `config.lua` when it exists and
never looks at `match.lua`.

### Multiple game modes

Add a `config.lua` manifest mapping mode names to scripts:

```lua
-- config.lua
return {
    arena = "arena/match.lua",
    ctf   = "ctf/match.lua"
}
```

### Infrastructure config

Infrastructure settings come from environment variables. Every default below is
the image's own `ENV`; consuming asobi as a dependency, these do not exist and
you write `sys.config` instead.

| Variable | Default | Description |
|----------|---------|-------------|
| `ASOBI_PORT` | `8084` | HTTP and WebSocket port |
| `ASOBI_DB_HOST` | `db` | PostgreSQL host |
| `ASOBI_DB_NAME` | `asobi` | Database name |
| `ASOBI_DB_USER` | `postgres` | Database user |
| `ASOBI_DB_PASSWORD` | `postgres` | Database password |
| `ASOBI_DB_SOCKET_OPTS` | `inet` | Erlang term fragment spliced into kura's `socket_options` list. `inet`, `inet6`, `inet, {nodelay, true}`. Set `inet6` for IPv6-only Postgres networks |
| `ASOBI_CORS_ORIGINS` | none | Allowed CORS origin. Effectively required for any browser client: unset renders an empty `Access-Control-Allow-Origin`, which no browser accepts |
| `ASOBI_NODE_HOST` | `127.0.0.1` | Erlang node hostname, in `-name asobi@...`. Not a bind address |
| `ERLANG_COOKIE` | `asobi` | Erlang distribution cookie. The default is the literal string `asobi` |

The database port is **not** a variable. It is fixed at `5432` in the image's
`sys.config`, so a Postgres on another port means supplying your own.

## Erlang (sys.config)

For Erlang OTP projects that add asobi as a dependency, configuration lives in
`sys.config` under the `{asobi, [...]}` key.

### Which application key

Everything below goes under `{asobi, [...]}`.

The Lua runtime used to be its own OTP application, so the keys it owns -
`max_heap_words`, `max_reductions_per_ms`, `reload_mode`,
`config_watch_interval`, `dev_errors`, `terrain_providers`, `lua_gc` and
`rate_limits` -
are still read from `asobi_lua` first and `asobi` second
(`asobi_lua_env:get_env/2`). An existing `{asobi_lua, [...]}` block keeps
working and there is nothing to migrate. Put new configuration under `{asobi,
[...]}`.

Everything else, `game_dir` and `game_modes` included, is an `asobi` key only
and always was.

The module names have not moved either: `asobi_lua_config`, `asobi_lua_api`,
`asobi_lua_loader` and friends are current, and so is `ASOBI_LUA_RELOAD`. Only
the *image* name changed - see [Glossary](glossary.md#asobi).

### Game modes

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

Lua scripts work too, in the same release:

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

Luerl is a hard dependency of asobi and `asobi_app:start/2` registers the Lua
providers itself, so `{lua, _}` modes work in a stock release with no extra
application. `{error, lua_runtime_unavailable}` survives only as the answer for
a mode *kind* that has no registered provider, which a stock release does not
have.

Shorthand (Erlang module only):

```erlang
{game_modes, #{
    ~"arena" => my_arena_game
}}
```

### Mode options

| Option | Default | Description |
|--------|---------|-------------|
| `module` | required | Erlang module or `{lua, "path.lua"}` |
| `match_size` | `2` | Players needed to start a match |
| `max_players` | `match_size` for matches, `500` for worlds | Maximum players per instance |
| `strategy` | `fill` | Matchmaking strategy: `fill`, `skill_based`, or a custom module |
| `skill_window` | `200` | Initial skill difference allowed (`skill_based` only) |
| `skill_expand_rate` | `50` | Window expansion per 5 seconds (`skill_based` only) |
| `bots` | `#{}` | Bot configuration - see [Bots](lua-bots.md) |
| `listed` | `false` for matches, `true` for worlds | Whether instances appear in discovery (`match.list` / `world.list`). Matches are unlisted by default: a matchmaker-spawned match is already assigned to its players, so opt in explicitly |
| `quick_play` | `true` | Whether `world.find_or_create` may place a player into an existing world of this mode. Read on the world entry path for whatever mode name it is handed, so setting it `false` on a match mode is protective rather than inert. Independent of `listed` - see [World server](world-server.md#visibility) |

### Operator modes and game-declared modes

Modes come from two independent places and asobi keeps them apart (ADR 0006):

- **Operator modes** are the ones above, in your `sys.config` `game_modes`.
  asobi never rewrites that key.
- **Game-declared modes** are what a Lua game declares in `match.lua` or a
  `config.lua` manifest. Loading a game replaces that set wholesale, so a mode
  you delete from `config.lua` is gone the next time the config loads instead
  of lingering until a restart.

The effective registry is the game-declared set with the operator set on top:
an operator mode wins a name clash and a game bundle can never drop or redefine
it. Read it with `asobi_game_config:modes/0`. The raw `game_modes` app-env key
is only the operator half.

**The override is whole-entry, not per-key.** The merge happens at the mode
name, so an operator entry replaces the game's entire map for that mode rather
than layering onto it. Writing the minimal-looking

```erlang
{game_modes, #{~"arena" => #{listed => true}}}
```

does not force `listed` on top of the game's config - it replaces the mode with
one that declares no `module`, and the mode then fails to resolve. To override
one key you must restate the whole shape, including
`module => {lua, "..."}`.

## Game directory

```erlang
{game_dir, "/app/game"}
```

Where the Lua loader looks for `config.lua`, `match.lua` and every script a
mode names. `/app/game` is the image's default and the mount point it declares.
There is no environment variable for it.

## Matchmaker

```erlang
{matchmaker, #{
    tick_interval => 1000,     %% ms between matchmaker ticks (default 1000)
    max_wait_seconds => 60     %% ticket expiry (default 60)
}}
```

The queue and its tickets live in this node's own process. Players queuing
against different nodes never match each other - see
[Clustering](clustering.md).

## Sessions

Nothing to configure. Access tokens last 60 minutes and refresh tokens 30 days,
from nova_auth's defaults, and `asobi_auth:config/0` does not override them.
Changing either means editing that function.

## Rate limiting

Per-route-group sliding windows via [Seki](https://github.com/Taure/seki).
**Buckets are per node**, so a 5/s limit is 5 x N across a cluster; size them
for one node and read [Clustering](clustering.md) before you rely on a number.

```erlang
{rate_limits, #{
    auth => #{limit => 5, window => 1000},      %% 5 req/sec for login/refresh
    iap  => #{limit => 10, window => 1000},     %% 10 req/sec for IAP
    api  => #{limit => 300, window => 1000}     %% 300 req/sec for API
}}
```

| Group | Default | Keyed on |
|-------|---------|----------|
| `auth` | 5 / 1000 ms | IP |
| `register` | 3 / 1000 ms | IP |
| `iap` | 10 / 1000 ms | IP |
| `api` | 300 / 1000 ms | IP |
| `ws_connect` | 60 / 1000 ms | IP |
| `join` | 10 / 60000 ms | player |
| `rehome` | 5 / 1000 ms | player |
| `guest_global` | 100 / 1000 ms | a constant (global) |
| `rehome_global` | 200 / 1000 ms | a constant (global) |
| `script_log` | 3 / 10000 ms | the failing call site |

`register` has its own bucket because `/auth/register` runs the password KDF as
its only cost gate. `script_log` bounds log lines from a script that fails on
every tick, not the telemetry counter behind them. `rehome_global` is a
placeholder default: size it from your real concurrent-player target.

Override any group; unset groups keep their default.

## Request body cap

`asobi_body_cap_plugin` runs before Nova buffers a request body, so an
oversized POST is rejected before it reaches the heap.

```erlang
{nova, [
    {plugins, [
        {pre_request, asobi_body_cap_plugin, #{
            max_body => 1048576,
            require_content_length => true
        }}
    ]}
]}
```

| Option | Default | Description |
|--------|---------|-------------|
| `max_body` | `1048576` (1 MiB) | Bodies larger than this get `413 payload_too_large` |
| `require_content_length` | `true` | A body with no `content-length` gets `411 length_required` rather than being streamed |

Per-route checks (cloud save, storage) still apply on top of this floor. The
image configures both values already.

## Pre-auth client gate

An optional gate in front of the anonymous auth-create routes, for a CAPTCHA or
an attestation check. Unset, it is a no-op.

```erlang
{client_gate, my_captcha_gate},
{client_gate_timeout, 5000},
{client_gate_on_error, deny}
```

| Key | Default | Description |
|-----|---------|-------------|
| `client_gate` | unset | Module implementing `asobi_client_gate`. Unset disables the gate entirely |
| `client_gate_timeout` | `5000` | Milliseconds to wait for the gate's verdict |
| `client_gate_on_error` | `deny` | What a crashed or timed-out gate means. Anything but `skip` rejects; `skip` trades the check for availability |

A rejected request gets `403 client_gate_denied`, with the gate's own reason in
`details.reason` (`client_gate_unavailable` when the gate itself failed). It
runs after the rate limiter, so a flood is shed by the cheap in-memory check
before it reaches an external verification service.

## WebSocket origin allowlist

By default the `/ws` upgrade accepts any `Origin`: web builds are served from
arbitrary studio and hosting domains, so a strict default would break them.

To harden a deployment against cross-site WebSocket hijacking, set an
allowlist:

```erlang
{ws_allowed_origins, [
    ~"https://play.yourgame.com",
    ~"https://yourstudio.itch.io"
]}
```

When set, a browser upgrade whose `Origin` is not listed is closed with `1008
origin_rejected` and emits `[asobi, ws, origin_rejected]`. Leaving it unset or
empty keeps the open default.

Match is exact against the value the browser sends, so copy that verbatim:
scheme, host and non-default port only. No trailing slash, no path, all
lowercase, punycode (`xn--...`) for internationalised domains, and each entry a
binary rather than a string. A trailing slash, an explicit `:443` or an
uppercase host silently matches nothing and locks out real users. A value that
is not a list of binaries is treated as a misconfiguration and fails closed,
rejecting everything, with a logged error.

This is independent of [CORS](#cors): CORS governs XHR and fetch, not the
WebSocket handshake.

Native clients (Defold, Unity, Unreal) send no `Origin` header and are never
affected. An absent `Origin` always passes, since a non-browser client cannot
be a CSWSH vector. The socket also does nothing until it presents a valid token
in the first `session.connect` frame, so this is defence in depth, not the
primary auth gate.

## Deprecated `game.*` extension frames

Extension-produced pushes go out as `module.message` and `module.error`. The
pre-rename names `game.message` and `game.error` are emitted alongside them,
with identical payloads, so SDK builds from before the rename keep working.
They are removed at the 1.0 wire break.

```erlang
{ws_legacy_game_frames, false}
```

Set this once every client on the deployment dispatches on `module.*`, and each
extension message drops from two frames to one. `game.message` carries
`game.send/2`, which a script may call per player per tick, so on a chatty game
the compatibility frame doubles that path. Any client still listening for
`game.*` goes silent the moment you set it. Default `true`. See
[WebSocket protocol](websocket-protocol.md).

## CORS

CORS is handled by `nova_cors_plugin` in the Nova plugin chain:

```erlang
{nova, [
    {plugins, [
        {pre_request, nova_cors_plugin, #{allow_origins => ~"https://mygame.com"}}
    ]}
]}
```

In the image this is `ASOBI_CORS_ORIGINS`, and it has no default.

## Clustering

Optional multi-node clustering via Erlang distribution. Both forms below match
[Clustering](clustering.md), which is the guide for this.

### DNS strategy (Fly.io, Kubernetes)

```erlang
{cluster, #{
    strategy => dns,
    dns_name => ~"asobi-headless.default.svc.cluster.local",
    poll_interval => 10000
}}
```

`dns_name` must be a binary. A string crashes the discovery server on every
poll.

### EPMD strategy (static hosts)

```erlang
{cluster, #{
    strategy => epmd,
    hosts => ['host-a', 'host-b']
}}
```

`hosts` are bare hostnames, not node names. asobi derives each peer's node name
by reusing this node's basename, so `'node@host'` in that list produces
`asobi@node@host`, which resolves to nothing.

## Authentication providers

### OAuth and OIDC

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

Every provider needs `issuer`, `client_id` and `client_secret`. asobi discovers
the rest (authorize, token and JWKS endpoints) from the issuer's
`.well-known/openid-configuration` document. A provider entry with no `issuer`,
or an issuer that is not `https://`, is logged and disabled on its own; the node
still boots and the other providers are unaffected - see
[Authentication](authentication.md) for the full supported-provider table and
per-provider notes.

`base_url` is the public origin asobi uses to build redirect URIs (default
`~"http://localhost:8082"`). Set it to your deployed URL so the redirect
providers call back to matches what you registered:

```erlang
{base_url, ~"https://mygame.com"}
```

### Steam

```erlang
{steam_api_key, ~"your-steam-web-api-key"},
{steam_app_id, ~"480"}
```

### Apple and Google IAP

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
upgrade it to a real account later. It is opt-in and fails closed: the guest
endpoints return `403 guest.disabled` until the **game** declares `guest_auth =
true` in its Lua config and the **operator** sets a `guest_verifier_pepper`
(ADR 0004). The game half is a Lua global, not a `sys.config` key - see
[Authentication](authentication.md#guest-anonymous). This page covers the
operator half.

```erlang
%% Required. A key-id -> pepper map (>= 32 bytes each). Keep old key ids for the
%% guest retention window so existing guests can still resume after rotation.
{guest_verifier_pepper, #{~"v1" => ~"a-32-byte-or-longer-secret......"}},
{guest_verifier_key_id, ~"v1"},

%% Optional abuse control: max unclaimed guests, or `infinity`.
{guest_unlinked_cap, 100000},

%% Optional retention. Unset = permanent guests (never reaped). Seconds of
%% inactivity after which an unclaimed guest is deleted by the reaper. The
%% clock restarts every time the device resumes, so this never expires a
%% player who is still playing.
{guest_reap_after, 2592000}
```

| Key | Default | Description |
|-----|---------|-------------|
| `guest_verifier_pepper` | none | Key-id -> pepper map, or a single binary. Each pepper must be at least 32 bytes; a shorter one is treated as absent. Presence is the operator's on switch |
| `guest_verifier_key_id` | `~"v1"` | Which pepper key id to use when minting new verifiers |
| `guest_unlinked_cap` | `100000` | Soft ceiling on unclaimed guests, or `infinity`. Anything else falls back to the default and logs `invalid_guest_unlinked_cap` |
| `guest_reap_after` | unset | Seconds of inactivity since the device last resumed; unset disables the reaper, so guests are permanent |

The cap is a soft ceiling, not an exact one: the count comes from a short-TTL
cache rather than a `COUNT` per create, so it can overshoot by roughly (TTL x
create rate). Reaching it answers `503 guest.capacity_reached`. If the node
cannot run the count at all it refuses too, but under `503 guest.unavailable` -
a different problem with a different fix, and a database fault rather than a
full deployment. Both log `guest_create_denied` with a `reason`; the cap denial
also logs the `count` and `cap` it compared, which is what tells you whether
the ceiling is anywhere near.

Clients can shed guests themselves with `POST /api/v1/players/me/erase`
(see [REST API](rest-api.md#erasing-your-own-account)), which is the only guest
removal available when `guest_reap_after` is not settable.

Measured from the last resume, not from account creation. Under device auth a
guest stays unclaimed for life - there is no password to set - so account age
would say nothing about whether anyone is still playing, and a returning player
would be deleted on schedule.

A reaped guest is erased in full - wallet, ledger, saves, storage, chat,
friendships, identities and any installed extension's rows - through the same
`asobi_player_erase` an operator-initiated erasure uses. This is permanent and
irreversible, it takes up to 500 accounts per sweep, and the sweep writes no
audit rows; it logs a count. Set it deliberately. See
[Erasing and exporting a player](rest-api.md#erasing-and-exporting-a-player).

**In the image today this needs a `sys.config`.** The Dockerfile declares
`ASOBI_GUEST_VERIFIER_PEPPER`, but nothing substitutes it into `sys.config`, so
setting the variable configures nothing and guest auth stays closed. Mount a
`sys.config` with the pepper until that is fixed.

The pepper is a server-side secret kept outside the database: keep it in a
secret manager, never in source. To rotate, add a new key id and point
`guest_verifier_key_id` at it, keeping the old ids for at least the retention
window so existing guests can still resume. Guest creation is bounded by the
per-IP `auth` limiter plus the global `guest_global` limit.

## Ops plane

The `/api/v1/ops` routes are for a game-operations console, not a game client,
and they carry their own credential. Fails closed: unset the key and every ops
request is rejected, so a deployment that never reads this page is closed
rather than open. There is no default credential.

```erlang
%% Required to use /api/v1/ops at all. Random, >= 32 bytes.
{ops_secret, ~"a-32-byte-or-longer-random-secret"}
```

| Key | Default | Description |
|-----|---------|-------------|
| `ops_secret` | none | Operator bearer token for `/api/v1/ops`. Unset rejects every ops request |

32 bytes is a recommendation here, not a rule: `asobi_ops_auth` accepts any
non-empty binary. `ops_token_secret` below and `guest_verifier_pepper` above
*are* length-checked and silently treat a short value as unset, so the three do
not behave alike.

Send it as `Authorization: Bearer <ops_secret>`. It is compared in constant time
and never leaves the server. Player and guest tokens are rejected here: the ops
plane never consults the player token store.

One secret is one privilege level: whoever holds it holds every capability
class, including `config` and `erasure`. Restrict who can reach the plane with
a reverse proxy, and set `x-asobi-operator` per person for attribution in the
audit trail - it is a label, never authority. A console session opened with
this secret is the one exception: it gets every class but `erasure` unless
`console_erasure` is set. See
[REST API](rest-api.md#ops-authentication) for the per-route reference and
[Operator console](console.md) for the operator narrative and for what the plane
can and cannot do.

### Minted tokens (managed environments)

A managed environment takes a second kind of ops credential: a short-lived,
env-scoped token minted by a control plane after it has authenticated the tenant
and checked they own this environment. Self-hosting needs none of this, and
[Cloud](cloud.md#the-console) walks the handoff end to end.

```erlang
{ops_token_secret, ~"${ASOBI_OPS_TOKEN_SECRET}"},
{env_id, ~"${GAME_ID}"}
```

| Key | Default | Description |
|-----|---------|-------------|
| `ops_token_secret` | none | A per-environment secret that signs ops tokens and nothing else. At least 32 bytes; shorter is treated as unset |
| `env_id` | none | This environment's id. A token minted for another one is refused |

It is deliberately not the credential the engine authenticates with. A value
that both proves who the engine is and signs the operator credentials it
accepts is one leak away from doing both for an attacker, and deriving one from
the other prevents confusion but not shared compromise.

Rotating it revokes every ops token outstanding for the environment at once,
which is the only revocation there is.

Both or neither: a node that knows the secret but not which environment it is
cannot check a token's `env` claim, so it refuses every minted token rather
than accepting one issued for somebody else's environment.

Unlike `ops_secret`, a minted token carries only the capability classes it was
minted with, so a tenant whose role maps to `read` and `player_data` cannot
reach a `config` route with it. The role name never arrives here; the control
plane maps it to classes at mint time.

The lifetime is capped at 15 minutes by this node, not by the minter. A token
signed with a longer one is refused, because there is no revocation list to
fall back on if the minting side ever issues a bad one.

## Operator console

A browser console for the ops plane, served by this node at `/console`. Off by
default: Nova starts one listener, so the console shares the game port, and an
operator surface on a public port has to be asked for.

```erlang
{console, true},
{ops_secret, ~"a-32-byte-or-longer-random-secret"}
```

| Key | Default | Description |
|-----|---------|-------------|
| `console` | `false` | Serve the console at `/console`. Anything but `true` is off, and every console route answers 404 |
| `console_session_ttl` | `43200` | Session lifetime in seconds, clamped to 60-86400. Absolute: it is not extended by use |
| `console_secure_cookie` | `false` | Force `Secure` on the session cookies. Set it behind a TLS terminator that does not send `x-forwarded-proto` |
| `console_api_base` | none | Absolute `https://host[:port]` origin the console should call instead of this one. Also widens `connect-src`. Anything that is not a bare origin is ignored |
| `console_label` | none | Names this deployment in the tab title and the console header |
| `console_production` | `false` | Marks a deployment to be careful in. The console colours its label |
| `console_erasure` | `false` | Let a console session erase players. Off because a browser can be clickjacked and an erasure cannot be undone; a bearer secret holds the class regardless |
| `console_bundle_app` | `asobi` | Which application's `priv/console` is served. Point it at the application `rebar3 asobi console` wrote a composed bundle into. An application that is not in the release makes `/console` answer 503 and logs `bundle_app_unavailable`; it never falls back to asobi's own bundle |

`console`, `console_label` and `console_production` also read
`ASOBI_CONSOLE`, `ASOBI_CONSOLE_LABEL` and `ASOBI_CONSOLE_PRODUCTION`, and
`ops_secret` reads `ASOBI_OPS_SECRET_FILE` or `ASOBI_OPS_SECRET`. The other
five - `console_session_ttl`, `console_secure_cookie`, `console_api_base`,
`console_erasure` and `console_bundle_app` - have no environment variable and
need a `sys.config`. A variable overrides `sys.config` only when it is set, so
the two coexist.

`console_bundle_app` is only for a host whose extensions ship their own operator
screens; see [Extending the operator console](console-extensions.md). It has no
environment variable on purpose: it names an application in the release, so it
is decided when the release is built, not when the container starts.

There is no `ASOBI_DB_PASSWORD_FILE`. The database password is substituted into
`sys.config` before any Erlang runs, so it cannot be read from a file the way
the ops secret can.

Sessions live in memory. The session store and the CSRF secret are per node, so
the console needs a sticky route behind a load balancer and a restart signs
everyone out - see [Clustering](clustering.md) and
[Operator console](console.md), which owns turning it on, signing in, what the
screens show and the troubleshooting.

## Storage

Cloud saves and the generic key-value store, served at `/api/v1/saves*` and
`/api/v1/storage*` and exposed to Lua as `game.storage.*`. On by default; set
`storage` to `false` to switch the whole subsystem off - the opposite default
to the console, which is off until asked for.

```erlang
{storage, false}
```

| Key | Default | Description |
|-----|---------|-------------|
| `storage` | `true` | Serve the storage subsystem. When `false` the seven `/saves` and `/storage` routes answer 404 and the `game.storage.*` Lua namespace is withheld at VM install |

It has no environment variable; set it in `sys.config`.

## Vote templates

Reusable vote configurations, merged with the per-vote config from your game
module:

```erlang
{vote_templates, #{
    ~"map_vote" => #{
        method => ~"plurality",
        window_ms => 15000,
        visibility => ~"live"
    }
}}
```

## World capacity

Bounds on persistent world creation, enforced as a DoS backstop:

```erlang
{world_max_per_player, 5},   %% default 5
{world_max, 1000}            %% default 1000
```

A player at the per-player cap gets `429 world.player_limit_reached`; once the
global cap is reached further creates get `503 world.capacity_reached`. The
global cap is checked first.

## Join rate

Joins are bounded per player, not per IP:

```erlang
{rate_limits, #{
    join => #{algorithm => sliding_window, limit => 10, window => 60000}
}}
```

Joining is how a client reaches a world's roster and leaving is free, so an
unbounded join rate lets one account enumerate every live world by joining,
reading `world.joined` and leaving. The default (10 per minute) is generous for
real play and turns a sweep of a full deployment from seconds into hours per
identity. Exceeding it returns `join_rate_limited` and emits `[asobi, join,
rate_limited]`.

This bounds the cost of a sweep; it does not make worlds private. For that,
implement `join/3` in your game module and reject unauthorised joins - see
[WebSocket protocol](websocket-protocol.md).

## Zone crossing rate

For `world`-mode games, re-homing a player across a zone boundary is bounded
per player and, separately, globally:

```erlang
{rate_limits, #{
    rehome => #{algorithm => sliding_window, limit => 5, window => 1000},
    rehome_global => #{algorithm => sliding_window, limit => 200, window => 1000}
}}
```

Each crossing updates part of the player's interest ring and resends a full
zone snapshot to any newly-subscribed zone, so an unbounded rate lets one
client force that work every tick by parking on a zone boundary. The per-player
default (5/sec) bounds the worst case on top of the crossing's own hysteresis
margin (see [World server](world-server.md)); it caps sustained crossing speed
at `limit * zone_size` units/sec, so a fast-moving game on a small `zone_size`
may need to raise it. The global bucket bounds the aggregate load N concurrent
attackers can push into the world's single terrain store.

Denied crossings are not dropped input: the player's position still updates
within their current zone, they just do not re-home that tick. Exceeding the
limit emits `[asobi, rehome, rate_limited]`.

## Terrain provider allowlist

For Lua large-world games, only allowlisted terrain generators can be named
from Lua:

```erlang
{asobi, [
    {terrain_providers, [asobi_terrain_flat, asobi_terrain_perlin]}
]}
```

The default allows `asobi_terrain_flat` and `asobi_terrain_perlin`.

## Per-call upper bounds

These runtime limits bound the cost of a single request. They are not
configurable; they are here so you can size clients accordingly.

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

## Background jobs (Shigoto)

```erlang
{shigoto, [
    {pool, asobi_repo}
]}
```

## Full example (Erlang sys.config)

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
                    min_players => 4,
                    script => ~"game/bots/chaser.lua"
                }
            }
        }}
    ]}
].
```

## Full example (Lua and Docker)

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
    image: ghcr.io/widgrensit/asobi:latest
    depends_on:
      postgres: { condition: service_healthy }
    ports:
      - "8084:8084"
    volumes:
      - ./lua:/app/game:ro
    environment:
      ASOBI_DB_HOST: postgres
      ASOBI_DB_NAME: my_game_dev
      ASOBI_CORS_ORIGINS: https://play.yourgame.com
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

- [Self-hosting](self-hosting.md) - requirements, the production compose, and
  what to check before you go live.
- [Clustering](clustering.md) - multi-node config and what is per node.
- [Operator console](console.md) - turning the console on and using it.
- [Performance tuning](performance-tuning.md) - the tick and BEAM knobs.
