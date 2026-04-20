# Getting Started

This guide walks you through setting up Asobi and creating your first game backend.

Choose your path:

- **[Lua + Docker](#lua--docker)** -- write game logic in Lua, no Erlang needed
- **[Erlang OTP](#erlang-otp)** -- add asobi as a dependency to your Erlang project

## Lua + Docker

The fastest way to start. You need [Docker](https://docs.docker.com/get-docker/) and nothing else.

### 1. Create your project

```bash
mkdir my_game && cd my_game
mkdir -p lua/bots
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
    image: postgres:16
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

### 5. Start it

```bash
docker compose up -d
```

Your game backend is running. Asobi reads your Lua scripts, sets up the
database, and starts listening for WebSocket connections on port 8080.

Edit your Lua files and restart to pick up changes:

```bash
docker compose restart asobi
```

See the [Lua Scripting](lua-scripting.md) guide for the full callback
reference and advanced patterns.

## Erlang OTP

For Erlang developers who want full control.

### Prerequisites

- Erlang/OTP 27+
- PostgreSQL 15+
- [rebar3](https://rebar3.org)

### 1. Create a New Project

```bash
rebar3 new app my_game
cd my_game
```

Add asobi to your dependencies in `rebar.config`:

```erlang
{deps, [
    {asobi, "~> 0.25"}
]}.
```

Point rebar3 at a `sys.config` for the shell (added below):

```erlang
{shell, [{config, "./config/sys.config"}]}.
```

### 2. Configure the Database

Create a PostgreSQL database:

```bash
createdb my_game_dev
```

Create `config/sys.config`. Asobi is hosted by Nova, so Nova needs to be
told to bootstrap the `asobi` application, which plugins to run, and
which `pg` scopes to register. `shigoto` (background jobs) needs to know
which DB pool to use, and `kura` needs the connection details:

```erlang
[
    {nova, [
        {environment, dev},
        {dev_mode, true},
        {bootstrap_application, asobi},
        {json_lib, json},
        {cowboy_configuration, #{port => 8080}},
        {plugins, [
            {pre_request, nova_request_plugin, #{
                decode_json_body => true,
                parse_qs => true
            }},
            {pre_request, nova_cors_plugin, #{allow_origins => <<"*">>}},
            {pre_request, nova_correlation_plugin, #{}}
        ]}
    ]},
    {kura, [
        {repo, asobi_repo},
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
        }},
        {session, #{
            token_ttl => 900,
            refresh_ttl => 2592000
        }}
    ]},
    {pg, [{scope, [nova_scope, asobi_presence, asobi_chat]}]}
].
```

> **Why `{bootstrap_application, asobi}`?** Nova is a web framework that
> hosts one or more applications. Without this key Nova doesn't know
> which app owns its router, and the release dies at boot with
> `{error, no_nova_app_defined}`.

### 3. Start the Server

```bash
rebar3 shell
```

Asobi runs all database migrations automatically on startup. The server
is now listening on the configured port.

## Register a Player

```bash
curl -X POST http://localhost:8080/api/v1/auth/register \
  -H 'Content-Type: application/json' \
  -d '{"username": "player1", "password": "secret123"}'
```

Response:

```json
{
  "player_id": "550e8400-e29b-41d4-a716-446655440000",
  "session_token": "SFMyNTY...",
  "username": "player1"
}
```

## Connect via WebSocket

Connect to `ws://localhost:8080/ws` and authenticate:

```json
{
  "type": "session.connect",
  "payload": {
    "token": "SFMyNTY..."
  }
}
```

## Implement Your Game

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
    %% Called every tick -- advance your simulation
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

## Next Steps

- [Lua Scripting](lua-scripting.md) -- write game logic in Lua (Docker or Erlang)
- [Bots](lua-bots.md) -- add AI-controlled players
- [Configuration](configuration.md) -- all configuration options
- [REST API](rest-api.md) -- full API reference
- [WebSocket Protocol](websocket-protocol.md) -- real-time message types
- [Matchmaking](matchmaking.md) -- query-based player matching
- [Economy](economy.md) -- wallets, items, and store
