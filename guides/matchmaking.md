# Matchmaking

asobi ships a periodic-tick matchmaker (`asobi_matchmaker`) that groups tickets
into matches using a per-mode strategy module.

## How it works

1. A player submits a ticket with a mode and optional properties.
2. The matchmaker ticks every `tick_interval` (1 second by default).
3. Each tick groups tickets by mode, and the mode's strategy decides which
   tickets form a match.
4. When a group forms, a match or a world is spawned.
5. Players are notified over the WebSocket as `match.matched`.

## Submitting a ticket

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
{ok, TicketId, Meta} = asobi_matchmaker:add(PlayerId, #{mode => ~"arena", properties => #{skill => 1200, region => ~"eu-west"}}).
```
<!-- /tabs -->

The reply - the `matchmaker.queued` frame over WS, the JSON body over REST -
carries `ticket_id`, `status: "pending"` and `players_needed`: the mode's
`match_size`, or `null` if the mode declares none. Show it as "waiting for N
players" so a queued client is not staring at silence. The `Meta` map in the
Erlang return holds the same `players_needed`.

### Testing solo

A match forms only once `match_size` players have queued, and a mode that
declares no `match_size` groups in twos: `fill` falls back to 2, and
`players_needed` comes back `null` because the mode itself declared nothing.
One client queuing alone therefore waits.

It does not wait forever. After `max_wait_seconds` (60 by default) the ticket
expires and that player receives

```json
{"type": "match.matchmaker_expired", "payload": {"ticket_id": "..."}}
```

Handle that frame - a client that only listens for `match.matched` looks hung
for a minute and then stays hung. To match instantly by yourself, set
`match_size = 1` in your mode script; the change is picked up within about a
second and a half (see [Configuration](#configuration)).

### Always pass `mode` as a named field

`{mode = "arena"}` in Lua, `mode: "arena"` in JSON/TS, a typed `mode` parameter
elsewhere. A malformed options shape - Lua's `{"arena"}`, which sets index `1`
rather than a `mode` field - silently falls back to `"default"`.

A multi-mode game gets `matchmaker.unknown_mode` for it: `default` is just
another key, and a `config.lua` manifest never maps it. A single-mode game does
not, because its loader registers `default` automatically, so the malformed call
silently queues for the only mode there is. The Lua SDKs (asobi-defold,
asobi-love2d) raise a loud error on this exact mistake; the typed SDKs (Dart,
Unity, Unreal, Godot) prevent it at compile time via a required `mode`
parameter. asobi-js's WS transport is intentionally schema-less, so a
hand-rolled `matchmaker.add` payload there is not protected by any SDK.

A ticket supports `mode` and `properties` only. There is no query language for
numeric ranges, required keys or automatic skill-window expansion - do that
filtering inside your strategy module.

The matchmaker holds one live ticket per player per mode: submitting again while
already queued returns the existing ticket rather than a second one, so a
double-tapped "find match" cannot match you with yourself. An unregistered mode
is rejected with `matchmaker.unknown_mode`, and a full queue with
`matchmaker.queue_full`.

## Checking a ticket

```bash
curl http://localhost:8084/api/v1/matchmaker/<ticket_id> \
  -H 'Authorization: Bearer <token>'
```

```json
{"id": "...", "mode": "arena", "status": "pending", "properties": {}, "submitted_at": 1711700000000}
```

The lookup is owner-scoped: another player's ticket id answers `403 forbidden`,
an unknown one `404 matchmaker.ticket_not_found`.

## When formation fails

Two different stories, because matches and worlds are spawned differently.

A **match** that fails to spawn - the game's Lua `init` crashed, say - is
re-queued and retried. After three attempts the group is given up on and each
player receives `match.matchmaker_failed`.

A **world** spawn is detached from the matchmaker tick so a slow world cannot
stall the queue, which leaves no handle to re-queue the group. Worlds therefore
fail fast: the first error or crash notifies the players once, with no retry.

Both paths use one of two coarse reasons, and neither ever carries the raw
crash:

| `reason` | Meaning |
|---|---|
| `match_start_failed` | The match or world could not be started, or the join fan-out crashed |
| `no_game_module` | The mode resolves to no game module - unconfigured, or a Lua mode in a release with no scripting runtime |

```json
{"type": "match.matchmaker_failed", "payload": {"reason": "match_start_failed"}}
```

Handle `match.matchmaker_failed` in your client alongside
`match.matchmaker_expired`.

## Strategies

Strategy is selected per mode via the `strategy` key. Two are built in:

- `fill` (default) - first-come-first-matched, grouping players in submission
  order until `match_size` is reached.
- `skill_based` - sorts tickets by `properties.skill` and pairs within an
  expanding window (`skill_window`, `skill_expand_rate`).

```lua
-- ranked.lua
match_size = 4
strategy   = "skill_based"   -- "fill" (default) or "skill_based"
```

The names map to `asobi_matchmaker_fill` and `asobi_matchmaker_skill`. Strategy
is per game mode only; there is no top-level `matchmaker_strategy` key.

Writing a new strategy is Erlang only. `strategy` takes either a built-in name
or an Erlang module name, and there is no Lua callback for grouping tickets. If
your rules fit neither built-in, you need a module in the release alongside your
Lua scripts.

### In Erlang

Implement `asobi_matchmaker_strategy`, a single `match/2` callback:

```erlang
-module(my_matchmaker).
-behaviour(asobi_matchmaker_strategy).

-export([match/2]).

-spec match([map()], map()) -> {[[map()]], [map()]}.
match(Tickets, Config) ->
    Size = maps:get(match_size, Config, 4),
    %% {Matched, Unmatched}, where Matched is a list of groups and each
    %% group is a list of tickets that form one match.
    group_by_size(Tickets, Size).
```

Wire it up per mode, from Erlang:

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

A Lua `strategy` global resolves `"fill"` and `"skill_based"` and nothing else.
Any other name stays a string, misses the module lookup and falls back to
`fill` without a word, so a custom strategy cannot be named from a mode
script.

A group that repeats the same player is dropped back to the queue rather than
spawning a degenerate self-match, whatever a strategy returns.

## Configuration

```erlang
{asobi, [
    {matchmaker, #{
        tick_interval => 1000,       %% ms between matchmaker ticks
        max_wait_seconds => 60,      %% ticket lifetime before it expires
        max_queue => 10000           %% live tickets before add returns queue_full
    }}
]}
```

`match_size`, `strategy` and the rest of a mode's shape are read into
`game_modes` at boot, and a config watcher polls the manifest and each mode
script for changes. With the default reload mode, editing `match_size` in a
mode script is picked up for **new** matches within about 1.5 seconds. Matches
already running keep the `match_size` they formed with.

A restart is needed in two cases: a sealed bundle, where `reload_mode` is `off`
or `ASOBI_LUA_RELOAD=off` and the watcher never polls at all; and a game whose
`game_modes` live in an Erlang `sys.config` rather than in Lua, which nothing
rescans.

## Per node

The matchmaker queue is per node. Tickets live in one gen_server's own state -
there is no ticket table in Postgres - so players queuing against different
nodes never match each other, and a restart drops every waiting ticket. Behind a
load balancer this is the fact that decides whether matchmaking works at all;
see [Clustering](clustering.md).

## Backfill

The matchmaker builds matches out of the queue. It never routes a queued player
into a match that is already running, and there is no backfill strategy to
enable.

Backfill is a discovery flow instead: the client calls `match.list` with
`has_capacity` and `joinable`, picks one, and joins it by id with `match.join`.
A `running` match accepts joins exactly as a `waiting` one does. Your `join`
callback runs mid-match, so it has to cope with a player arriving into a live
game state, and the script decides when to stop taking them with
[`game.match.set_joinable(false)`](lua-api.md#match). See
[Lobbies](lobbies.md#joining-a-match-already-in-progress).

## Playing with friends

Gathering players before a game starts is covered in [Lobbies](lobbies.md).

The matchmaker has no party grouping. It queues individual players, a ticket
cannot bring others with it, and a `party` field on a ticket is not accepted.
Party weighting would change what `match_size` means for every strategy module,
which is why it is not shipped. A game that needs it can add the grouping call
as an extension method and reach it over the `rpc.call` frame - see
[Extensions](extensions.md).

To play with someone specific, skip the queue. **Worlds are the only session a
client can create**: `world.create` over the WebSocket, or
`POST /api/v1/worlds`. Share the returned `world_id` or a join code out of band
and have them `world.join` it. Matches are created by the matchmaker or by an
Erlang caller inside the release, and by nothing else - there is no
`match.create` frame and no `POST /api/v1/matches`.

Gate entry by implementing `join/3` in your game module and checking the join
context - see [WebSocket protocol](websocket-protocol.md#join-context). To let
friends find your session in a browser instead, see
[World server](world-server.md).

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

Or over REST:

```bash
curl -X DELETE http://localhost:8084/api/v1/matchmaker/<ticket_id> \
  -H 'Authorization: Bearer <token>'
```

## Watching the queue

The console has a Matchmaker screen: one row per mode, deepest queue first. It
reads the queue and cannot act on it - there is no cancel-ticket button, and the
numbers are this node's queue only. See [Operator console](console.md).

## Next steps

- [Testing with multiple players](testing-multiple-players.md) - why your two
  test clients are one player, and why they land in separate matches.
- [WebSocket protocol](websocket-protocol.md) - the `matchmaker.*` and `match.*` frames.
- [Configuration](configuration.md) - per-mode matchmaker tuning.
- [Clustering](clustering.md) - what a second node does to the queue.
