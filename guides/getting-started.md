# Getting started

asobi is one Erlang/OTP node holding the game backend, the Lua runtime and the
operator console. There are two front doors onto it:

- **[Lua + Docker](#lua--docker)** - run the image, write game logic in Lua. The default path.
- **[Erlang OTP](#erlang-otp)** - depend on the Hex package and write game logic in Erlang.

Command blocks that differ per OS are shown for both bash (Linux, macOS, Git
Bash, or WSL on Windows) and PowerShell (Windows). Docker and rebar3 commands
are identical on every platform and are shown once.

## Lua + Docker

You need [Docker](https://docs.docker.com/get-docker/) and nothing else. On
Windows and macOS that is Docker Desktop; on Windows enable the WSL2 backend.
`localhost` reaches the server the same way on all three.

### 1. Create your project

bash (Linux, macOS, Git Bash, WSL):

```bash
mkdir my_game && cd my_game
mkdir -p lua/bots
```

PowerShell (Windows):

```powershell
mkdir my_game; cd my_game
mkdir lua/bots
```

### 2. Write your match logic

```lua
-- lua/match.lua

match_size = 2
max_players = 4
strategy = "fill"
bots = { script = "bots/wanderer.lua" }

function init(config)
    return { players = {} }
end

function join(player_id, state)
    state.players[player_id] = { x = 400, y = 300, hp = 100 }
    return state
end

function leave(player_id, state)
    state.players[player_id] = nil
    return state
end

function handle_input(player_id, input, state)
    local p = state.players[player_id]
    if not p then return state end
    if input.right then p.x = p.x + 5 end
    if input.left  then p.x = p.x - 5 end
    if input.down  then p.y = p.y + 5 end
    if input.up    then p.y = p.y - 5 end
    return state
end

function tick(state)
    return state
end

function get_state(player_id, state)
    return { players = state.players }
end
```

### 3. Add a bot (optional)

```lua
-- lua/bots/wanderer.lua

names = {"Spark", "Blitz", "Volt"}

function think(bot_id, state)
    return {
        right = math.random(2) == 1,
        left  = math.random(2) == 1,
        down  = math.random(2) == 1,
        up    = math.random(2) == 1,
        shoot = false
    }
end
```

### 4. Create docker-compose.yml

```yaml
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
      ASOBI_CORS_ORIGINS: "*"
```

The image was renamed from `ghcr.io/widgrensit/asobi_lua`. That name is no
longer rebuilt - tags already published keep working and are not going away,
but they will not get fixes - so change your compose file.

`ASOBI_CORS_ORIGINS` has no default. Left unset, the node answers with an empty
`Access-Control-Allow-Origin` and every browser request fails with nothing in
the logs to explain it. `*` is right for local development; narrow it to your
game's origins in production.

### 5. Start it

```bash
docker compose up -d
```

The node reads your Lua scripts, runs the database migrations, and listens for
REST and WebSocket traffic on port 8084.

### 6. Verify it works

Register a player:

bash (Linux, macOS, Git Bash, WSL):

```bash
curl -s localhost:8084/api/v1/auth/register \
  -H 'content-type: application/json' \
  -d '{"username":"alice","password":"hunter2"}'
```

PowerShell (Windows), no `curl` install needed, `Invoke-RestMethod` parses the response:

```powershell
Invoke-RestMethod -Uri http://localhost:8084/api/v1/auth/register `
  -Method Post -ContentType application/json `
  -Body '{"username":"alice","password":"hunter2"}'
```

A 200 with:

```json
{
  "player_id": "550e8400-e29b-41d4-a716-446655440000",
  "access_token": "...",
  "refresh_token": "...",
  "username": "alice"
}
```

That means auth, the database, REST and the Lua runtime are all live.

`access_token` is what the WebSocket handshake sends (see
[Connect via WebSocket](#connect-via-websocket)) and what goes in the
`Authorization: Bearer` header on REST calls. It is valid for 60 minutes.
`refresh_token` buys a new pair from `POST /api/v1/auth/refresh` and is valid
for 30 days. Neither TTL is configurable today.

Failures use one error object throughout:

```json
{"error": {"code": "missing_field", "message": "...", "details": {}}}
```

Branch on `code`, never on `message`. The ones you are likely to hit:

- `missing_field` (400) - `username` or `password` absent, or not a string.
- `auth.username_taken` (409) - a second run of the same command hits this.
- `validation_failed` (422) - the username or password failed a field rule; `details.fields` names them.

Connection refused means the node has not finished booting. Give it 10s, then
check `docker compose logs asobi` for migration errors.

### 7. Turn on the operator console (optional)

Set `ASOBI_CONSOLE: "true"` and `ASOBI_OPS_SECRET_FILE` (pointing at a mounted
secret file) on the `asobi` service, then browse to <http://localhost:8084/console>.
Enabled without a secret, the console stays off and logs an error; the node
still starts. See [Operator console](console.md).

### Hot-reloading Lua

Edit `lua/match.lua`, a world script, or anything they `require`, and save. A
running match re-executes the new script body on its next tick, in place: only
globals and functions are reassigned, so players, counters and every other
table already in the Lua state survive. A syntax error logs a warning and the
match keeps running the old code until you fix the file.

Two things behave differently:

- Mode-shape config (`match_size`, `max_players`, `strategy`, `bots`) is
  re-read by a config watcher and applies to matches formed after the edit.
  Matches already running consumed those values at formation.
- A bot script is loaded when the bot process starts, so an edit reaches bots
  spawned after it, not bots already in a match.

See [Lua scripting](lua-scripting.md) for the full callback reference and
[Lua API](lua-api.md) for the host functions available inside a script.

## Erlang OTP

### Prerequisites

rebar3, Erlang/OTP 28 or later, and PostgreSQL 16 or later. CI builds on OTP
29.0.2 against Postgres 17.

### 1. Create a new project

```bash
rebar3 new app my_game
cd my_game
```

Add asobi to your dependencies in `rebar.config`:

```erlang
{deps, [
    {asobi, "~> 0.68"}
]}.
```

Point rebar3 at a `sys.config` for the shell (added below):

```erlang
{shell, [{config, "./config/sys.config"}]}.
```

### 2. Configure the database

Create a PostgreSQL database:

```bash
createdb my_game_dev
```

Create `config/sys.config`. asobi is hosted by Nova, so Nova needs to be told
to bootstrap the `asobi` application, which plugins to run, and which `pg`
scopes to register. `shigoto` (background jobs) needs to know which DB pool to
use, and `kura` needs the connection details and its dialect.

The plugin list below mirrors the one the shipped release uses
(`config/prod_sys.config.src`). The order matters: the body cap runs before
anything buffers a body, and the rate limiter runs before the client gate so
a flood is shed before any external call.

```erlang
[
    {nova, [
        {environment, dev},
        {dev_mode, true},
        {bootstrap_application, asobi},
        {json_lib, json},
        {cowboy_configuration, #{port => 8084}},
        {plugins, [
            {pre_request, asobi_body_cap_plugin, #{
                max_body => 1048576,
                require_content_length => true
            }},
            {pre_request, nova_request_plugin, #{
                decode_json_body => true,
                parse_qs => true
            }},
            {pre_request, nova_cors_plugin, #{allow_origins => ~"*"}},
            {pre_request, nova_correlation_plugin, #{}},
            {pre_request, asobi_rate_limit_plugin, #{}},
            {pre_request, asobi_client_gate_plugin, #{}},
            {post_request, asobi_security_headers_plugin, #{}}
        ]}
    ]},
    {kura, [
        {repo, asobi_repo},
        {backend, kura_backend_postgres},
        {host, "localhost"},
        {port, 5432},
        {database, "my_game_dev"},
        {user, "postgres"},
        {password, "postgres"},
        {pool_size, 10}
    ]},
    {shigoto, [
        {pool, asobi_repo},
        {poll_interval, 200},
        {queues, [{~"default", 10}]}
    ]},
    {asobi, [
        {game_modes, #{
            ~"my_mode" => my_game
        }},
        {matchmaker, #{
            tick_interval => 1000,
            max_wait_seconds => 60
        }}
    ]},
    {pg, [{scope, [nova_scope, asobi_presence, asobi_chat]}]}
].
```

Two keys people leave out and then debug for an hour:

`{bootstrap_application, asobi}` tells Nova which application owns the router.
Without it the release dies at boot with `{error, no_nova_app_defined}`.

`{backend, kura_backend_postgres}` tells kura which SQL dialect to compile to.
Without it the node boots fine and then dies on its first query with
`{no_dialect_configured, asobi_repo}`.

### 3. Start the server

```bash
rebar3 shell
```

Database migrations run automatically on startup. The server is now listening
on the configured port.

## Register a player

bash (Linux, macOS, Git Bash, WSL):

```bash
curl -X POST http://localhost:8084/api/v1/auth/register \
  -H 'Content-Type: application/json' \
  -d '{"username": "player1", "password": "secret123"}'
```

PowerShell (Windows):

```powershell
Invoke-RestMethod -Uri http://localhost:8084/api/v1/auth/register `
  -Method Post -ContentType application/json `
  -Body '{"username": "player1", "password": "secret123"}'
```

Response:

```json
{
  "player_id": "550e8400-e29b-41d4-a716-446655440000",
  "access_token": "...",
  "refresh_token": "...",
  "username": "player1"
}
```

## Connect via WebSocket

Connect to `ws://localhost:8084/ws` and send the `access_token`:

```json
{
  "type": "session.connect",
  "payload": {
    "token": "..."
  }
}
```

A connection that never sends `session.connect` is closed by the idle-auth
timer (1008, `idle_auth_timeout`).

## Implement your game

Create a module implementing the `asobi_match` behaviour:

```erlang
-module(my_game).
-behaviour(asobi_match).

-export([init/1, join/2, leave/2, handle_input/3, tick/1, get_state/2]).

init(_Config) ->
    {ok, #{players => #{}}}.

join(PlayerId, State = #{players := Players}) ->
    {ok, State#{players => Players#{PlayerId => #{x => 0, y => 0}}}}.

leave(PlayerId, State = #{players := Players}) ->
    {ok, State#{players => maps:remove(PlayerId, Players)}}.

handle_input(PlayerId, #{~"type" := ~"move", ~"x" := X, ~"y" := Y}, State) ->
    #{players := Players} = State,
    {ok, State#{players => Players#{PlayerId => #{x => X, y => Y}}}}.

tick(State) ->
    %% Called every tick - advance your simulation
    {ok, State}.

get_state(_PlayerId, State) ->
    %% Return the state visible to this player
    maps:get(players, State).
```

Register it in your config:

```erlang
{asobi, [
    {game_modes, #{~"my_mode" => my_game}}
]}
```

## Next steps

- [Lua scripting](lua-scripting.md) - write game logic in Lua (Docker or Erlang)
- [Lua API](lua-api.md) - the host functions a script can call
- [Bots](lua-bots.md) - add AI-controlled players
- [Configuration](configuration.md) - all configuration options
- [Self-hosting](self-hosting.md) - requirements, production compose, operating notes
- [REST API](rest-api.md) - full API reference
- [WebSocket protocol](websocket-protocol.md) - real-time message types
- [Matchmaking](matchmaking.md) - query-based player matching
- [Economy](economy.md) - wallets, items, and store
