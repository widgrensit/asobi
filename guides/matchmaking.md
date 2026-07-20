# Matchmaking

Asobi ships a periodic-tick matchmaker (`asobi_matchmaker` gen_server) that
groups tickets into matches using a per-mode strategy module.

## How It Works

1. Player submits a matchmaking ticket with a mode and optional properties.
2. Matchmaker ticks periodically (default every 1 second).
3. Each tick groups tickets by mode, and the mode's strategy module decides which tickets form a match.
4. When a group is formed, a match is spawned.
5. Players are notified via WebSocket (`match.matched`).

## Submitting a Ticket

### Via REST

```bash
curl -X POST http://localhost:8084/api/v1/matchmaker \
  -H 'Authorization: Bearer <token>' \
  -H 'Content-Type: application/json' \
  -d '{
    "mode": "arena",
    "properties": {"skill": 1200, "region": "eu-west"}
  }'
```

### Via WebSocket

<!-- tabs -->
**WebSocket (JSON)**
```json
{
  "type": "matchmaker.add",
  "payload": {
    "mode": "arena",
    "properties": {"skill": 1200, "region": "eu-west"}
  }
}
```
**Erlang**
```erlang
{ok, TicketId} = asobi_matchmaker:add(PlayerId, #{mode => <<"arena">>, properties => #{skill => 1200, region => <<"eu-west">>}}).
```
<!-- /tabs -->

A ticket supports `mode` and `properties`. A
query-language extension (numeric ranges, required keys, automatic skill
window expansion) is on the roadmap but not shipped — do that filtering
inside your strategy module instead.

## Strategies

Strategy is selected per mode via the `strategy` key in `game_modes`. Two
are built in:

- `fill` (default) — first-come-first-matched, groups players in submission
  order until `match_size` is reached.
- `skill_based` — sorts tickets by `properties.skill` and pairs within an
  expanding window (configurable via `skill_window` and
  `skill_expand_rate`).

Select one with the `strategy` global in your mode script:

```lua
-- ranked.lua
match_size = 4
strategy   = "skill_based"   -- "fill" (default) or "skill_based"
```

The built-in strategies map to modules: `fill` is `asobi_matchmaker_fill`
and `skill_based` is `asobi_matchmaker_skill`. Strategy is configured per
game mode only - there is no top-level `matchmaker_strategy` key.

**Writing a new strategy is Erlang only.** `strategy` takes either a
built-in name or an Erlang module name, and there is no Lua callback for
grouping tickets. If your matching rules do not fit `fill` or
`skill_based`, you need an Erlang module in the release alongside your Lua
scripts.

## Custom Strategies (Erlang)

Implement `asobi_matchmaker_strategy` (a single `match/2` callback):

```erlang
-module(my_matchmaker).
-behaviour(asobi_matchmaker_strategy).

-export([match/2]).

-spec match([map()], map()) -> {[[map()]], [map()]}.
match(Tickets, Config) ->
    Size = maps:get(match_size, Config, 4),
    %% Return {Matched, Unmatched}, where Matched is a list of
    %% groups (each group a list of tickets that form a match).
    group_by_size(Tickets, Size).
```

Wire it up per mode:

<!-- tabs -->
**Lua**

A Lua game declares its mode as script globals. Point `strategy` at your
Erlang module by name:

```lua
-- ranked.lua
match_size = 4
strategy   = "my_matchmaker"
```

**Erlang**
```erlang
{asobi, [
    {game_modes, #{
        ~"ranked" => #{
            module     => my_arena,
            match_size => 4,
            strategy   => my_matchmaker
        }
    }}
]}
```
<!-- /tabs -->

## Configuration

```erlang
{asobi, [
    {matchmaker, #{
        tick_interval => 1000,       %% ms between matchmaker ticks
        max_wait_seconds => 60       %% max wait before timeout
    }}
]}
```

## Playing With Friends

> Gathering players before a game starts is covered in [Lobbies](lobbies.md).


The matchmaker has no party grouping. It queues individual players, and a
ticket cannot bring other players with it.

To play with someone specific, skip the queue: create a match or world,
share its id or a join code out of band, and have them join directly. Gate
entry by implementing `join/3` in your game module and checking the join
context - see [WebSocket Protocol](websocket-protocol.md#join-context). To
let friends find your session in a browser instead, see
[World Server](world-server.md).

Matchmaker-mediated party grouping would mean weighting tickets by party
size, which changes what `match_size` means for every strategy module. It
is not shipped, and a `party` field on a ticket is not accepted.

## Cancelling

<!-- tabs -->
**WebSocket (JSON)**
```json
{"type": "matchmaker.remove", "payload": {"ticket_id": "..."}}
```
**Erlang**
```erlang
asobi_matchmaker:remove(PlayerId, TicketId).
```
<!-- /tabs -->

Or via REST:

```bash
curl -X DELETE http://localhost:8084/api/v1/matchmaker/<ticket_id> \
  -H 'Authorization: Bearer <token>'
```

## Next steps

- [WebSocket protocol](websocket-protocol.md) - the `matchmaker.*` and `match.matched` messages.
- [Configuration](configuration.md) - per-mode matchmaker tuning.
