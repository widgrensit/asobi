# Matchmaking

Asobi ships a periodic-tick matchmaker (`asobi_matchmaker` gen_server) that
groups tickets into matches using a per-mode strategy module.

## How It Works

1. Player submits a matchmaking ticket with a mode, optional properties, and an optional party.
2. Matchmaker ticks periodically (default every 1 second).
3. Each tick groups tickets by mode, and the mode's strategy module decides which tickets form a match.
4. When a group is formed, a match is spawned.
5. Players are notified via WebSocket (`matchmaker.matched`).

## Submitting a Ticket

### Via REST

```bash
curl -X POST http://localhost:8080/api/v1/matchmaker \
  -H 'Authorization: Bearer <token>' \
  -H 'Content-Type: application/json' \
  -d '{
    "mode": "arena",
    "properties": {"skill": 1200, "region": "eu-west"}
  }'
```

### Via WebSocket

```json
{
  "type": "matchmaker.add",
  "payload": {
    "mode": "arena",
    "properties": {"skill": 1200, "region": "eu-west"}
  }
}
```

A ticket currently supports `mode`, `properties`, and `party`. A
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

## Custom Strategies

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

## Configuration

```erlang
{asobi, [
    {matchmaker, #{
        tick_interval => 1000,       %% ms between matchmaker ticks
        max_wait_seconds => 60       %% max wait before timeout
    }}
]}
```

## Party Support

Players can queue as a party. All party members are placed in the same match:

```json
{
  "type": "matchmaker.add",
  "payload": {
    "mode": "arena",
    "party": ["player_id_2", "player_id_3"],
    "properties": {"skill": 1200}
  }
}
```

## Cancelling

```json
{"type": "matchmaker.remove", "payload": {"ticket_id": "..."}}
```

Or via REST:

```bash
curl -X DELETE http://localhost:8080/api/v1/matchmaker/<ticket_id> \
  -H 'Authorization: Bearer <token>'
```
