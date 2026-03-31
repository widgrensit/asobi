# Asobi

[![Hex.pm](https://img.shields.io/hexpm/v/asobi.svg)](https://hex.pm/packages/asobi)
[![CI](https://github.com/widgrensit/asobi/actions/workflows/ci.yml/badge.svg)](https://github.com/widgrensit/asobi/actions/workflows/ci.yml)

Open-source game backend platform built on Erlang/OTP and the [Nova](https://github.com/novaframework/nova) ecosystem.

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

## Quick Start

### Prerequisites

- Erlang/OTP 27+
- PostgreSQL 15+
- [rebar3](https://rebar3.org)

### Setup

Add asobi as a dependency:

```erlang
{deps, [
    {asobi, "~> 0.1"}
]}.
```

Configure your `sys.config`:

```erlang
[
    {kura, [
        {repo, asobi_repo},
        {host, "localhost"},
        {database, "my_game_dev"},
        {user, "postgres"},
        {password, "postgres"}
    ]},
    {shigoto, [
        {pool, asobi_repo}
    ]},
    {asobi, [
        {plugins, [
            {pre_request, nova_request_plugin, #{
                decode_json_body => true,
                parse_qs => true
            }},
            {pre_request, nova_cors_plugin, #{allow_origins => <<"*">>}},
            {pre_request, nova_correlation_plugin, #{}}
        ]},
        {game_modes, #{
            ~"my_mode" => my_game_module
        }},
        {matchmaker, #{
            tick_interval => 1000,
            max_wait_seconds => 60
        }},
        {session, #{
            token_ttl => 900,
            refresh_ttl => 2592000
        }}
    ]}
].
```

Start the database and run:

```bash
rebar3 shell
```

Asobi runs migrations automatically on startup.

## Implementing a Game

Implement the `asobi_match` behaviour to define your game logic:

```erlang
-module(my_arena_game).
-behaviour(asobi_match).

-export([init/1, join/2, leave/2, handle_input/3, tick/1, get_state/2]).

init(Config) ->
    {ok, #{players => #{}, round => 1}}.

join(PlayerId, State) ->
    {ok, State#{players => maps:put(PlayerId, #{score => 0}, maps:get(players, State))}}.

leave(PlayerId, State) ->
    {ok, State#{players => maps:remove(PlayerId, maps:get(players, State))}}.

handle_input(PlayerId, #{~"action" := ~"shoot"} = Input, State) ->
    %% Process player input, update game state
    {ok, State}.

tick(State) ->
    %% Called every tick (default 10/sec) -- advance game simulation
    {ok, State}.

get_state(PlayerId, State) ->
    %% Return the state visible to this player
    maps:get(players, State).
```

Register your game mode in config:

```erlang
{asobi, [
    {game_modes, #{~"arena" => my_arena_game}}
]}
```

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

- [Getting Started](guides/getting-started.md)
- [REST API](guides/rest-api.md)
- [WebSocket Protocol](guides/websocket-protocol.md)
- [Matchmaking](guides/matchmaking.md)
- [Economy](guides/economy.md)
- [Architecture](docs/ARCHITECTURE.md)

## License

Apache-2.0
