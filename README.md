# Asobi

[![Hex.pm](https://img.shields.io/hexpm/v/asobi.svg)](https://hex.pm/packages/asobi)
[![CI](https://github.com/widgrensit/asobi/actions/workflows/ci.yml/badge.svg)](https://github.com/widgrensit/asobi/actions/workflows/ci.yml)

Open-source game backend platform built on Erlang/OTP and the [Nova](https://github.com/novaframework/nova) ecosystem.

<p align="center">
  <a href="https://play.asobi.dev">
    <img src="docs/arena-demo.gif" alt="Asobi Arena Demo" width="600">
  </a>
  <br>
  <em><a href="https://play.asobi.dev">Try the live demo</a></em>
</p>

Asobi provides everything you need to build and run multiplayer games:
authentication, player management, real-time multiplayer, matchmaking,
leaderboards, virtual economy, social features, and background jobs -- all
in a single BEAM release.

## Features

- **Authentication** -- register, login, session tokens via [nova_auth](https://github.com/novaframework/nova_auth)
- **Player Management** -- profiles, stats, metadata
- **Real-Time Multiplayer** -- WebSocket transport, server-authoritative game loop with configurable tick rate
- **Matchmaking** -- query-based matching with skill windows and party support
- **Leaderboards** -- ETS-backed for microsecond reads, PostgreSQL for persistence
- **Virtual Economy** -- wallets, transactions, item definitions, store, inventory
- **Social** -- friends, groups/guilds, chat channels, presence, notifications
- **Tournaments** -- scheduled competitions with entry fees and rewards
- **Cloud Saves** -- per-slot save data with optimistic concurrency
- **Generic Storage** -- key-value storage with permissions (public/owner/none)
- **Background Jobs** -- powered by [Shigoto](https://github.com/Taure/shigoto)
- **Admin Dashboard** -- real-time LiveView console via [Arizona](https://github.com/novaframework/arizona_core)

## Quick Start with Lua (Docker)

No Erlang needed. Just Lua scripts and Docker.

```bash
mkdir my_game && cd my_game
mkdir -p lua/bots
```

Write your game logic in Lua:

```lua
-- lua/match.lua
match_size = 2
max_players = 4
strategy = "fill"

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
    return state
end

function tick(state)
    return state
end

function get_state(player_id, state)
    return { players = state.players }
end
```

Add a `docker-compose.yml`:

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
    image: ghcr.io/widgrensit/asobi:latest
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

```bash
docker compose up -d
```

That's it. Your game backend is running with authentication, matchmaking,
WebSocket transport, and everything else handled by Asobi.

## Quick Start with Erlang

For Erlang/OTP developers who want full control, add asobi as a dependency:

```erlang
{deps, [
    {asobi, "~> 0.1"}
]}.
```

Implement the `asobi_match` behaviour:

```erlang
-module(my_arena_game).
-behaviour(asobi_match).

-export([init/1, join/2, leave/2, handle_input/3, tick/1, get_state/2]).

init(_Config) ->
    {ok, #{players => #{}}}.

join(PlayerId, #{players := Players} = State) ->
    {ok, State#{players => Players#{PlayerId => #{x => 0, y => 0}}}}.

leave(PlayerId, #{players := Players} = State) ->
    {ok, State#{players => maps:remove(PlayerId, Players)}}.

handle_input(_PlayerId, _Input, State) ->
    {ok, State}.

tick(State) ->
    {ok, State}.

get_state(_PlayerId, #{players := Players}) ->
    Players.
```

Register it in `sys.config` and start with `rebar3 shell`.
See the [Getting Started](guides/getting-started.md) guide for the full walkthrough.

## Stack

| Layer | Technology |
|-------|-----------|
| HTTP / REST | [Nova](https://github.com/novaframework/nova) (Cowboy) |
| WebSocket | Nova WebSocket (Cowboy) |
| Database / ORM | [Kura](https://github.com/Taure/kura) (PostgreSQL via pgo) |
| Real-time UI | [Arizona](https://github.com/novaframework/arizona_core) |
| Authentication | [nova_auth](https://github.com/novaframework/nova_auth) |
| Background Jobs | [Shigoto](https://github.com/Taure/shigoto) |
| Pub/Sub | OTP `pg` module |

## Why BEAM?

The BEAM VM is uniquely suited for game backends:

- **Per-process GC** -- no global pauses; one match collecting garbage never affects another
- **Fault tolerance** -- OTP supervision restarts crashed matches without affecting others
- **Hot code upgrade** -- deploy game logic changes without disconnecting players
- **Native clustering** -- distributed Erlang handles cross-node messaging with no external coordination
- **500K+ connections per node** -- dramatically lower infrastructure costs
- **No external state stores** -- ETS replaces Redis, `pg` replaces pub/sub services

## Documentation

Full documentation is available on [HexDocs](https://hexdocs.pm/asobi).

- [Getting Started](guides/getting-started.md) -- Lua (Docker) or Erlang setup
- [Lua Scripting](guides/lua-scripting.md) -- write game logic in Lua
- [Bots](guides/lua-bots.md) -- add AI-controlled players
- [Configuration](guides/configuration.md) -- all configuration options
- [REST API](guides/rest-api.md) -- full API reference
- [WebSocket Protocol](guides/websocket-protocol.md) -- real-time message types
- [Matchmaking](guides/matchmaking.md) -- query-based player matching
- [Economy](guides/economy.md) -- wallets, items, and store
- [Architecture](docs/ARCHITECTURE.md) -- system design

## License

Apache-2.0
