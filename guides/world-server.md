# World server

Large-session multiplayer with spatial partitioning. The world server holds
players in a shared continuous space and splits that space into zone processes
for parallelised tick simulation and interest-based state broadcasting.

Use it when players move through a shared space: co-op dungeons, open worlds,
large-scale survival. For arena-style games with smaller player counts, use the
[match server](matchmaking.md).

For massive tile-based worlds, see [Large worlds](large-worlds.md) for lazy zone
loading, terrain data and scaling configuration.

## How it works

A world is divided into a grid of **zones**, each a separate Erlang process
owning the entities in its region. A player receives updates only from the
zones they can see (interest management), and each zone runs its tick in
parallel across CPU cores.

```
World (2000x2000 units, 10x10 grid)
┌─────┬─────┬─────┬─────┬ ...
│ z0,0│ z1,0│ z2,0│ z3,0│
│     │  P1 │     │     │
├─────┼─────┼─────┼─────┼ ...
│ z0,1│ z1,1│ z2,1│ z3,1│
│     │     │ P2  │     │
├─────┼─────┼─────┼─────┼ ...
│ z0,2│ z1,2│ z2,2│ z3,2│
│     │     │     │     │
```

P1 subscribes to the 9 zones around z1,0. P2 subscribes to the 9 zones
around z2,1. They only overlap on 2 zones, so most of their traffic is
independent.

### Supervision tree

Each world instance is its own supervisor:

```
asobi_world_sup (one_for_one)
├── asobi_zone_snapshotter       - batched snapshot writer, one per node
├── asobi_world_registry         - tracks active worlds on this node
└── asobi_world_instance_sup     - dynamic, one child per world
    └── asobi_world_instance     - one_for_all per world
        ├── asobi_zone_sup       - dynamic, one child per live zone cell
        │   └── asobi_zone       - gen_server per grid cell
        ├── asobi_zone_manager   - owns which cells are live and reaps idle ones
        ├── asobi_world_ticker   - coordinates ticks across zones
        └── asobi_world_server   - gen_statem, world lifecycle
```

The top three are node-wide singletons. Everything under
`asobi_world_instance` is per world, which is why a world costs six processes
before a single zone beyond the first.

### Tick cycle

Every tick (default 20 Hz, 50ms):

1. The ticker sends `tick(N)` in parallel to every zone that has acked its
   previous tick. A zone still working on the last one is skipped for this
   tick rather than sent another - see below.
2. Each zone applies queued player inputs, runs `zone_tick/2`, computes deltas
   from the previous state and broadcasts them to its subscribers.
3. Each zone acks back to the ticker.
4. When every zone sent this tick has acked, the ticker calls `post_tick/2` on
   the world server for global events: boss phases, quest triggers, vote
   requests. `post_tick/2` runs at most once per tick and never runs
   backwards, so a zone acking late cannot replay an earlier tick's global
   events.

A zone whose `zone_tick/2` takes longer than `tick_rate` is skipped, not
queued. Sending it another tick would only grow its mailbox: it cannot catch
up by definition, the zone tick is idempotent upkeep, and the next tick
carries the same work. Without this a slow zone accumulates ticks without
bound until the node runs out of memory. Each skip increments
`[asobi, zone, tick_skipped]`; see [Observability](observability.md#the-events)
for what to alert on.

### Delta compression

Zones send only what changed since the last tick:

```json
{
  "type": "world.tick",
  "payload": {
    "tick": 1042,
    "updates": [
      {"op": "u", "id": "p_abc", "x": 451, "y": 312, "hp": 80},
      {"op": "a", "id": "npc_7", "x": 400, "y": 300, "type": "goblin"},
      {"op": "r", "id": "item_3"}
    ]
  }
}
```

- `u` - updated, only the changed fields
- `a` - added, full entity state
- `r` - removed

## In Lua

Run `ghcr.io/widgrensit/asobi` and write a world script. The
[Erlang behaviour](#in-erlang) below is the same model on the other surface of
the same node, for a release that depends on the Hex package.

World scripts follow the same pattern as match scripts, with zone-specific
callbacks. Set `game_type = "world"` in your mode globals.

The global is `game_type`, not `type`. The Erlang `sys.config` form uses the
key `type`, but the Lua loader reads `game_type`. A Lua script setting
`type = "world"` is silently ignored: it registers as a match mode, so
`world.find_or_create` hands the match bridge to the world server, which then
crashes on the world callbacks that bridge does not export (`spawn_position/2`,
`zone_tick/2`, `post_tick/2`). There is no clean error for this - check
`game_type` first.

```lua
-- lua/world.lua

-- World mode config
game_type   = "world"
match_size  = 10            -- required by the loader for every mode,
                            -- including worlds. Use 1 for worlds that
                            -- don't gate on a minimum player count.
max_players = 500
grid_size   = 5
zone_size   = 400
tick_rate   = 50
view_radius = 1
strategy    = "fill"

function init(config)
    return {
        dungeon_level = 1,
        boss_hp = 10000,
        tick_count = 0
    }
end

function join(player_id, state)
    return state
end

function leave(player_id, state)
    return state
end

function spawn_position(player_id, state)
    return {
        x = 100 + math.random(200),
        y = 100 + math.random(200)
    }
end

function post_tick(tick, state)
    state.tick_count = tick

    -- Boss defeated: next level, and tell every client
    if state.boss_hp <= 0 then
        state.boss_hp = 10000
        state.dungeon_level = state.dungeon_level + 1
        game.broadcast("level_up", { level = state.dungeon_level })
    end

    -- Time limit: 30 minutes at 20 Hz
    if tick >= 36000 then
        state._finished = true
        state._result = { reason = "time_up" }
    end

    return state
end

-- Optional: procedural generation
function generate_world(seed, config)
    local zones = {}
    for x = 0, 4 do
        for y = 0, 4 do
            local key = x .. "," .. y
            zones[key] = {
                biome = pick_biome(x, y, seed),
                spawners = {}
            }
        end
    end
    return zones
end

function get_state(player_id, state)
    return {
        dungeon_level = state.dungeon_level,
        boss_hp = state.boss_hp
    }
end
```

### Lua callbacks

| Function | Required | Description |
|---|---|---|
| `init(config)` | yes | Return the initial global game state |
| `join(player_id, state)` | yes | Player joined; return state |
| `join(player_id, state, ctx)` | no | Same, plus the client's join context. Declare the third parameter and it is used instead - see [Join context](websocket-protocol.md#join-context) |
| `leave(player_id, state)` | yes | Player left; return state |
| `spawn_position(player_id, state)` | yes | Return a `{x=N, y=N}` table |
| `post_tick(tick, state)` | yes | Global tick logic. Set `_finished` and `_result` on state to end the world |
| `zone_tick(entities, zone_state)` | no | Per-zone simulation; return both |
| `handle_input(player_id, input, entities)` | no | Apply one player's input to that zone's entities |
| `generate_world(seed, config)` | no | Return a table keyed by `"x,y"` strings |
| `get_state(player_id, state)` | no | Player-visible state |
| `spawn_templates(config)` | no | See [Spawn templates](#spawn-templates) |
| `phases(config)` | no | See [Phases](phases.md) |
| `on_phase_started(name, state)` / `on_phase_ended(name, state)` | no | Phase transitions |
| `on_zone_loaded(cx, cy, state)` / `on_zone_unloaded(cx, cy, state)` | no | See [Large worlds](large-worlds.md) |
| `terrain_provider(config)` | no | See [Large worlds](large-worlds.md) |
| `on_world_recovered(snapshot, state)` | no | The world process restarted and a snapshot was recovered |

`vote_resolved` is not on this list on purpose. The world bridge does not
export it, so a Lua world script defining `vote_resolved` is never called. See
[Voting](voting.md) for what does and does not reach a Lua world today.

### Finishing a world

Set `_finished` and `_result` on your state in `post_tick()`:

```lua
function post_tick(tick, state)
    if all_quests_complete(state) then
        state._finished = true
        state._result = {
            status = "completed",
            dungeon_level = state.dungeon_level,
            survivors = count_alive(state)
        }
    end
    return state
end
```

### Triggering votes

Setting `state._vote` in `post_tick` is the world's vote trigger, and the
server does read it every tick. It does not start a vote today: the decoded
table reaches the vote server with the wrong key type and the failure is
swallowed. [Voting](voting.md) has the detail and the Erlang route that works.

## In Erlang

Implement the `asobi_world` behaviour:

```erlang
-module(my_dungeon).
-behaviour(asobi_world).

-export([init/1, join/2, leave/2, spawn_position/2]).
-export([zone_tick/2, handle_input/3, post_tick/2]).

init(_Config) ->
    {ok, #{dungeon_level => 1, boss_hp => 10000}}.

join(PlayerId, State) ->
    {ok, State}.

leave(PlayerId, State) ->
    {ok, State}.

spawn_position(_PlayerId, _State) ->
    %% Random position in the first zone
    {ok, {50.0 + rand:uniform(100), 50.0 + rand:uniform(100)}}.

zone_tick(Entities, ZoneState) ->
    %% Run NPC AI, move projectiles, apply effects
    Entities1 = maps:map(fun(Id, E) ->
        case maps:get(type, E, ~"player") of
            ~"goblin" -> ai_wander(E);
            _ -> E
        end
    end, Entities),
    {Entities1, ZoneState}.

handle_input(PlayerId, #{~"action" := ~"move", ~"x" := X, ~"y" := Y}, Entities) ->
    case Entities of
        #{PlayerId := Entity} ->
            {ok, Entities#{PlayerId => Entity#{x => X, y => Y}}};
        _ ->
            {error, not_found}
    end;
handle_input(_PlayerId, _Input, Entities) ->
    {ok, Entities}.

post_tick(TickN, #{boss_hp := HP} = State) when HP =< 0 ->
    %% Boss defeated - trigger an upgrade vote
    {vote, #{
        template => ~"boon_pick",
        options => [
            #{id => ~"shield", label => ~"Shield Boost"},
            #{id => ~"speed", label => ~"Speed Boost"},
            #{id => ~"damage", label => ~"Damage Boost"}
        ],
        method => ~"plurality",
        window_ms => 15000
    }, State#{boss_hp => 10000, dungeon_level => maps:get(dungeon_level, State) + 1}};
post_tick(TickN, State) when TickN >= 36000 ->
    %% 30 minutes at 20 Hz
    {finished, #{reason => ~"time_up"}, State};
post_tick(_TickN, State) ->
    {ok, State}.
```

### Callbacks

| Callback | Required | Description |
|----------|----------|-------------|
| `init/1` | yes | Initialise global game state |
| `join/2` | yes | Player joined the world |
| `leave/2` | yes | Player left the world |
| `spawn_position/2` | yes | Return `{ok, {X, Y}}` for new player placement |
| `zone_tick/2` | yes | Per-zone simulation: `(Entities, ZoneState) -> {Entities, ZoneState}` |
| `handle_input/3` | yes | Process player input within a zone's entities |
| `post_tick/2` | yes | Global post-tick: return `{ok, State}`, `{vote, Config, State}`, or `{finished, Result, State}` |
| `generate_world/2` | no | Procedural generation: `(Seed, Config) -> {ok, #{Coords => ZoneState}}` |
| `get_state/2` | no | Per-player state view |
| `vote_resolved/3` | no | Handle vote result. Not declared on the `asobi_world` behaviour: the world server looks for it with `erlang:function_exported/3`, so exporting it works but the compiler will not tell you if the arity is wrong |

### Entity keys

Entity maps are yours: asobi stores whatever a callback returns and only
reads `x`, `y`, `type` and `persistent` from them, for zone crossings,
spatial queries, hibernation and snapshots. Those four are read under either
an atom key (`x`) or a binary one (`~"x"`), so a scripting bridge that hands
entities back binary-keyed works the same as a native Erlang module. Mixing
shapes within one entity is not supported - keep an entity's keys consistent.

### Configuration

Register your world mode in `sys.config`:

```erlang
{asobi, [
    {game_modes, #{
        ~"dungeon" => #{
            type => world,
            module => my_dungeon,
            match_size => 10,
            max_players => 500,
            grid_size => 10,        %% 10x10 = 100 zones
            zone_size => 200,       %% each zone covers 200x200 units
            tick_rate => 50,        %% 50ms = 20 Hz
            view_radius => 1,       %% subscribe to 1 zone in each direction (3x3 = 9 zones)
            strategy => fill
        }
    }}
]}
```

| Option | Default | Description |
|---|---|---|
| `type` | `match` | Must be `world` for world server mode |
| `module` | required | The game module, or `{lua, "path.lua"}` |
| `grid_size` | 10 | Zones per axis; total zones = `grid_size^2` |
| `zone_size` | 200 | Units per zone side; world size = `grid_size * zone_size` |
| `tick_rate` | 50 | Milliseconds between ticks (50 = 20 Hz) |
| `broadcast_interval` | 3 | Simulation ticks per wire delta; deltas go out every `tick_rate * broadcast_interval` ms. Set to 1 for a delta every tick, which client-side prediction wants |
| `view_radius` | 1 | Zones visible in each direction from the player's zone |
| `max_players` | 500 | Concurrent players per world |
| `persistent` | `false` | Keep the world alive with no players in it |
| `empty_grace_ms` | 0 | Milliseconds an empty world lingers before finishing. 0 finishes immediately |
| `player_ttl_ms` | 0 | Milliseconds a disconnected player's entity is held for reconnection |
| `listed` | `true` | Whether worlds of this mode appear in `world.list` and `GET /api/v1/worlds` |
| `quick_play` | `true` | Whether `world.find_or_create` may place a player into an existing world of this mode |
| `chat` | `#{}` | See [Chat channels](#chat-channels) |

Using a world as a persistent hub is covered in [Lobbies](lobbies.md).

### Four values you cannot set

These four look like mode options and are not: the mode config never reaches
the process that would read them, so every world runs on the built-in value.
Plan around them as facts of the deployment, not knobs.

| Value | What every world gets |
|---|---|
| Active zones per world | 10,000. See [Large worlds](large-worlds.md) for what happens at that ceiling |
| Zone idle timeout | 30 seconds before an empty zone is released |
| Rehome margin | 0.15 of `zone_size` (described below) |
| Zone snapshot interval | 600 ticks, and moot - see [Snapshots](#snapshots) |

An entity, player or NPC, must clear its zone's edge by the rehome margin (a
fraction of `zone_size`) before re-homing to the neighbouring zone, so an
entity parked on or jittering across a boundary does not re-home every tick.
An entity's tracked zone can therefore lag its true position by up to that
margin near a boundary: an entity in a zone's entity map is not necessarily
strictly inside that zone's rectangle.

The zone-based `game.spatial.query_radius(x, y, radius)` and
`game.spatial.query_rect(x1, y1, x2, y2)` search only the calling zone's own
entity map, so this lag has a direction that matters: an area geometrically
inside zone A's rectangle can be occupied by an entity zone B still owns,
because it has not cleared the margin yet. A query issued from zone A over that
area misses it entirely, and the gap persists - an NPC parked just past its
zone's edge stays invisible to the neighbour's queries indefinitely, not only
for the tick it takes to cross. Account for that if your NPC AI queries by
position near zone edges.

The margin bounds this slack only for positions inside the world rectangle. An
entity outside it entirely is clamped into the edge zone by `pos_to_zone` and
stays owned by that zone at any distance past the edge, so validate positions
in your movement handler if your game trusts the zone rectangle as a hard
bound. A band-parked NPC also stays visible to a neighbouring zone's
*subscribers* only while `view_radius >= 1` keeps that neighbour touched every
tick; at `view_radius = 0` the owning zone can idle out under coordinates a
player standing metres away never loads.

See [Configuration](configuration.md) for the `rehome` rate limit on how often
a player may re-home at all. NPCs re-home directly without going through that
limiter, since `asobi_zone` owns them outright.

## Visibility

`listed` and `quick_play` are independent axes, so a mode can be browsable
but out of quick-play rotation, or reachable by quick-play while hidden from
the browser.

In Lua, as globals on the mode script:

```lua
game_type  = "world"
listed     = false    -- never shows up in the browser
quick_play = false    -- and never absorbs a quick-play request
```

Or in an operator `game_modes` entry:

```erlang
~"tutorial" => #{
    type => world,
    module => my_tutorial,
    listed => false,      %% never shows up in the browser
    quick_play => false   %% and never absorbs a quick-play request
}
```

Both default to `true` for a world, so a mode that says nothing is browsable
and quick-playable. A match mode is the inverse for `listed`: unlisted until
it opts in.

Neither flag gates joining. A client that already knows a `world_id` can
still `world.join` it. Both flags control discovery only.

Both are properties of the **mode**, not of a world instance, so a player
cannot host a private world at runtime. A mode is either discoverable or it
is not, for every world it spawns. Player-hosted private games need join
authorisation, which does not exist yet.

With `quick_play => false`, `world.find_or_create` returns
`quick_play_disabled` rather than creating a world, since it could never
find the one it just made.

### Procedural generation

Implement `generate_world/2` to provide initial state for each zone:

```erlang
generate_world(Seed, _Config) ->
    rand:seed(exsss, {Seed, Seed, Seed}),
    ZoneStates = maps:from_list([
        {{X, Y}, #{
            biome => pick_biome(X, Y),
            npcs => generate_npcs(X, Y),
            loot => generate_loot(X, Y)
        }}
     || X <- lists:seq(0, 9), Y <- lists:seq(0, 9)
    ]),
    {ok, ZoneStates}.
```

Each zone receives its state via the `zone_state` field in `zone_tick/2`.

## Spawn templates

Worlds seed non-player entities (NPCs, resources, objects) from **spawn
templates**. Implement the optional `spawn_templates/1` callback to return a
map of template id to template definition.

A template has:

- `type` - the entity type applied to every spawned instance.
- `base_state` - a map merged into every entity spawned from the template.
- `respawn` - optional respawn policy: `strategy` (currently `timer`),
  `delay` (milliseconds), `jitter` (milliseconds of random spread added to
  the delay), and `max_respawns` (cap, or `infinity`).
- `persistent` - whether a spawned entity would survive a zone snapshot and
  restore (see [Snapshots](#snapshots) for why none is taken today).
  Lua entities default to `true`.

At runtime, Lua scripts spawn from a template with
`game.zone.spawn("goblin", x, y, {overrides})`, where the optional table
overrides fields from the template's `base_state`.

If `template_id` doesn't match a key returned by `spawn_templates`, nothing
spawns: `game.zone.spawn` has no return value to report the failure. The zone
logs a `zone_spawn_failed` warning with the `world_id` and `coords`, and
emits `[asobi, error]` with `kind => unknown_spawn_template`.

### Updating templates in an already-running zone

`spawn_templates/1` is only ever called once, at zone creation - a template
added later (e.g. via a script hot-reload) never reaches a zone that's
already running; it stays invisible to that zone until the zone is recreated.

The optional `spawn_templates_hint/1` Erlang callback closes this: it runs
every tick, and returning `{changed, NewTemplates}` pushes an updated
template set into the live zone immediately. Return `unchanged` in the
common case - this runs on the hot path, so a game module implementing it
owns the cost of deciding whether anything actually changed (e.g. only doing
real work right after its own hot-reload check fires), not this callback
being a place to unconditionally re-derive templates every tick.

`NewTemplates` **replaces** the zone's whole template set, the same as
`spawn_templates/1`'s result does at creation - it is not a delta. Include
every template that should still be spawnable, not only the ones that
changed, or the rest silently stop being spawnable.

```erlang
spawn_templates_hint(ZoneState) ->
    case just_reloaded(ZoneState) of
        false -> unchanged;
        true -> {changed, current_templates(ZoneState)}
    end.
```

```lua
function spawn_templates(config)
    return {
        goblin = {
            type       = "npc",
            base_state = { health = 100, ai = "patrol" },
            respawn    = { delay = 5000, jitter = 1000, max_respawns = 3 }
        },
        chest = {
            type       = "object",
            base_state = { loot = "common" }
        }
    }
end

function zone_tick(entities, zone_state)
    game.zone.spawn("goblin", 500, 500)
    game.zone.spawn("chest", 620, 600, { loot = "rare" })
    return entities, zone_state
end
```

See the `examples/world-spawns` demo for a complete world script.

## Snapshots

`asobi_zone_snapshotter` is a batched writer that persists a zone's entities,
zone state, entity timers and spawner state to the `zone_snapshots` table, and
loads them back when a zone starts blank.

**No world writes one today.** The zone reads a `persistence` flag, and the
mode config that would set it emits `persistent` instead, so the flag is always
false and both the periodic write and the restore-on-start are skipped. Setting
`persistent = true` in a mode keeps a world alive when it empties; it does not
survive a node restart.

What does still work is a per-zone ETS backup written every 20 ticks. It is
crash recovery for a zone process inside a running node, not durability across
a restart.

Do not build on cross-restart world state until this is fixed. A world's
entities are in memory only.

## Subscriptions

A player subscribes to the 3x3 neighbourhood of zones around their entity.
Membership is recomputed as the player moves: entering a zone streams a
snapshot of that zone's currently visible entities, and leaving a zone stops
its updates.

## WebSocket protocol

World messages use the `world.*` namespace. See
[WebSocket protocol](websocket-protocol.md) for the envelope.

### Client to server

| Type | Payload | Description |
|---|---|---|
| `world.create` | `{"mode": "..."}` | Create a world of this mode and join it |
| `world.find_or_create` | `{"mode": "..."}` | Join an existing world of this mode, or create one |
| `world.join` | `{"world_id": "..."}` | Join a specific world |
| `world.list` | `{"mode": "...", "has_capacity": true}` | Browse listed worlds |
| `world.leave` | `{}` | Leave the current world |
| `world.input` | `{"action": "move", "x": 100, "y": 200}` | Send input to your zone |

### Server to client

| Type | Payload | Description |
|---|---|---|
| `world.joined` | `{world_id, status, player_count, grid_size, ...}` | Join confirmed |
| `world.left` | `{success: true}` | Leave confirmed |
| `world.tick` | `{tick, updates: [{op, id, ...}]}` | Zone delta broadcast |
| `world.phase_changed` | the phase info block | See [Phases](phases.md) |
| `world.terrain` | `{coords, data}` | See [Large worlds](large-worlds.md) |
| `world.finished` | `{world_id, result}` | World ended |

A player already in a world who sends `world.join` for a different one is
refused with `world.already_joined`; leave first.

### Input routing

`world.input` is routed to the zone process that currently owns your player
entity. You do not name a zone: the server tracks your position and routes
automatically.

## Chat channels

World chat is configuration-driven. Enable the channel types you need per
game mode:

```erlang
{asobi, [
    {game_modes, #{
        ~"galaxy" => #{
            type => world,
            module => my_game,
            chat => #{
                global => [~"general", ~"trade"], %% game-wide, spans every world
                world => true,       %% one channel for everyone in this world
                zone => true,        %% auto-join/leave as players move between zones
                proximity => 2       %% chat with players within N zones of you
            }
        }
    }}
]}
```

There is no Lua equivalent: the loader reads no chat globals, so a script
cannot turn a channel on. Chat is an operator `game_modes` entry, and that
entry replaces the script's mode config for that name rather than merging into
it - so a Lua world with chat needs the whole mode declared in `sys.config`,
`module => {lua, "world.lua"}` included.

### Channel types

| Type | Scope | Lifecycle |
|---|---|---|
| Global | Every player in the game, across all worlds | Join on world join, leave on world leave |
| World | All players in the world instance | Join on world join, leave on world leave |
| Zone | Players in the same zone cell | Auto-swap when crossing zone boundaries |
| Proximity | Players within N zones | Follows your interest radius, updates on zone change |

### How it works

Chat channels use the `asobi_chat_channel` system. The world server manages
subscriptions:

- **On join**: player is added to world chat and their spawn zone's chat
- **On zone change**: old zone chat is left, new zone chat is joined.
  Proximity channels diff the old and new interest areas so only the
  delta is updated
- **On leave**: all world/zone/proximity channels are cleaned up

No extra client code needed. Chat messages arrive via the same WebSocket
as `chat.message` events. Clients just need to know the channel IDs,
which follow a predictable format:

- Global: `global:{name}`
- World: `world:{world_id}`
- Zone: `zone:{world_id}:{x},{y}`
- Proximity: `prox:{world_id}:{x},{y}`

A global channel carries no world id on purpose: every world of every mode
that declares the same name resolves the same channel process, so one message
is one broadcast and one row of history, not one per world. Only names
declared in a mode's `chat.global` are authorised, so a client cannot mint
new ones; names are up to 64 bytes of `a-z A-Z 0-9 _ - .` and anything else
is dropped with a warning at join time.

### No chat config

Omit the `chat` key and no channels are created. The world server then runs
with no chat overhead. Add channels later by updating your mode config.

## Clustering

A world lives entirely on the node that created it. Its zones are local
processes under that world's instance supervisor; nothing distributes them
across nodes and there is no zone placement to configure. `pg` carries the
registrations - world server pids by world id, zone pids by coordinates, player
sessions, and the per-player and global world caps - but it registers
processes, it never moves them.

Horizontal scale therefore means more worlds, never a bigger one. If a single
world is the thing that is full, shard it in your game design - regions,
instances, shards. See [Clustering](clustering.md).

## Inspecting a world

The console has no worlds screen. Three things stand in for one:

```bash
# Every listed world, with player counts and phase blocks. Player-facing, so
# it needs a player token, and unlisted modes never appear.
curl http://localhost:8084/api/v1/worlds -H 'Authorization: Bearer <token>'

# One world by id, including unlisted ones.
curl http://localhost:8084/api/v1/worlds/<world_id> -H 'Authorization: Bearer <token>'

# Node pressure: process count against the limit, run queue, memory, uptime.
curl -H 'Authorization: Bearer <ops-secret>' \
  http://localhost:8084/api/v1/ops/stats
```

`/ops/stats` is the one to watch when zones are the concern: every zone is a
process, so a world grid and its idle-zone churn show up in `process_count` and
`run_queue` before they show up anywhere else. A stock node serves neither the
console nor the ops API - see [Operator console](console.md).

## Next steps

- [Large worlds](large-worlds.md) - lazy zones, terrain, and the zone ceiling.
- [Lua scripting](lua-scripting.md) - the match-side scripting model.
- [Voting](voting.md) - in-session voting.
- [Phases](phases.md) - the phase clock and `world.phase_changed`.
- [Clustering](clustering.md) - multi-node deployment.
