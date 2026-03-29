# Getting Started

This guide walks you through setting up Asobi and creating your first game backend.

## Prerequisites

- Erlang/OTP 27+
- PostgreSQL 15+
- [rebar3](https://rebar3.org)

## Create a New Project

Use the Nova generator to scaffold your project:

```bash
rebar3 new nova my_game
cd my_game
```

Add asobi to your dependencies in `rebar.config`:

```erlang
{deps, [
    {asobi, {git, "https://github.com/widgrensit/asobi.git", {branch, "main"}}}
]}.
```

## Configure the Database

Create a PostgreSQL database:

```bash
createdb my_game_dev
```

Add configuration to your `sys.config`:

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
    ]}
].
```

Kura defaults: `host` = `"localhost"`, `port` = `5432`, `user` = `"postgres"`,
`pool_size` = `10`.

## Start the Server

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

- [REST API](rest-api.md) -- full API reference
- [WebSocket Protocol](websocket-protocol.md) -- real-time message types
- [Matchmaking](matchmaking.md) -- query-based player matching
- [Economy](economy.md) -- wallets, items, and store
