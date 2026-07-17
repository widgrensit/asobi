# World Server

Build large-session multiplayer games with spatial partitioning. The world
server handles 1--500+ players in a shared continuous space, automatically
splitting the world into zone processes for parallelized tick simulation
and interest-based state broadcasting.

Use the world server when your game has players moving through a shared
space (co-op dungeons, open worlds, large-scale survival). For arena-style
games with smaller player counts, use the standard [match server](matchmaking.md).

For massive tile-based worlds (10K+ zones), see [Large Worlds](large-worlds.md)
for lazy zone loading, terrain data, and scaling configuration.

## How It Works

A world is divided into a grid of **zones** -- each zone is a separate
Erlang process that owns the entities in its region. Players only receive
updates from zones they can see (interest management), and each zone runs
its tick in parallel across CPU cores.

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

### Supervision Tree

Each world instance is its own supervisor:

```
asobi_world_sup (one_for_one)
├── asobi_world_registry         — tracks active worlds
└── asobi_world_instance_sup     — dynamic, one per world
    └── asobi_world_instance     — one_for_all per world
        ├── asobi_zone_sup       — dynamic, one per zone cell
        │   └── asobi_zone       — gen_server per grid cell
        ├── asobi_world_ticker   — coordinates ticks across zones
        └── asobi_world_server   — gen_statem: world lifecycle
```

### Tick Cycle

Every tick (default 20 Hz / 50ms):

1. Ticker sends `tick(N)` to all zones in parallel
2. Each zone: applies queued player inputs, runs `zone_tick/2`, computes
   deltas from previous state, broadcasts deltas to subscribers
3. Each zone acks back to the ticker
4. When all zones ack, ticker calls `post_tick/2` on the world server
   for global game events (boss phases, quest triggers, vote requests)

### Delta Compression

Zones only send what changed since the last tick:

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

- `u` -- updated (only changed fields)
- `a` -- added (full entity state)
- `r` -- removed

## Lua Implementation

Most games write world logic in Lua and run the asobi_lua Docker image - no
Erlang needed. The [Erlang behaviour](#erlang-implementation) below is the same
model for teams embedding asobi as a library.

World scripts follow the same pattern as match scripts but with
zone-specific callbacks. Set `game_type = "world"` in your mode globals.

> **Gotcha**: the global is **`game_type`**, not `type`. The Erlang
> `sys.config` form uses the key `type`, but the Lua loader
> reads `game_type`. A Lua script that sets `type = "world"` is
> silently ignored — the script registers as a *match* mode and
> `world.find_or_create` returns `mode_not_found`.

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

    -- Boss defeated: trigger a vote
    if state.boss_hp <= 0 then
        state.boss_hp = 10000
        state.dungeon_level = state.dungeon_level + 1
        state._vote = {
            template = "boon_pick",
            options = {
                { id = "shield", label = "Shield Boost" },
                { id = "speed",  label = "Speed Boost" },
                { id = "damage", label = "Damage Boost" }
            },
            method = "plurality",
            window_ms = 15000
        }
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

### Lua Callbacks

| Function | Required | Description |
|----------|----------|-------------|
| `init(config)` | yes | Return initial global game state |
| `join(player_id, state)` | yes | Handle player join, return state |
| `leave(player_id, state)` | yes | Handle player leave, return state |
| `spawn_position(player_id, state)` | yes | Return `{x=N, y=N}` table |
| `post_tick(tick, state)` | yes | Global tick logic. Set `_finished`/`_result` or `_vote` on state |
| `generate_world(seed, config)` | no | Return table keyed by `"x,y"` strings |
| `get_state(player_id, state)` | no | Player-visible state |
| `vote_resolved(template, result, state)` | no | Handle vote result |

### Finishing a World

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

### Triggering Votes

Set `_vote` on your state in `post_tick()`:

```lua
function post_tick(tick, state)
    if state.boss_hp <= 0 then
        state._vote = {
            template = "choose_path",
            options = {
                { id = "cave", label = "Dark Cave" },
                { id = "forest", label = "Enchanted Forest" }
            },
            method = "plurality",
            window_ms = 20000
        }
        state.boss_hp = nil  -- clear so vote doesn't re-trigger
    end
    return state
end
```

## Erlang Implementation

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
    %% Boss defeated -- trigger an upgrade vote
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
| `init/1` | yes | Initialize global game state |
| `join/2` | yes | Player joined the world |
| `leave/2` | yes | Player left the world |
| `spawn_position/2` | yes | Return `{ok, {X, Y}}` for new player placement |
| `zone_tick/2` | yes | Per-zone simulation: `(Entities, ZoneState) -> {Entities, ZoneState}` |
| `handle_input/3` | yes | Process player input within a zone's entities |
| `post_tick/2` | yes | Global post-tick: return `{ok, State}`, `{vote, Config, State}`, or `{finished, Result, State}` |
| `generate_world/2` | no | Procedural generation: `(Seed, Config) -> {ok, #{Coords => ZoneState}}` |
| `get_state/2` | no | Per-player state view |
| `vote_resolved/3` | no | Handle vote result (inherited from match voting) |

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
|--------|---------|-------------|
| `type` | `match` | Must be `world` for world server mode |
| `grid_size` | 10 | Number of zones per axis (total = grid_size^2) |
| `zone_size` | 200 | Units per zone side (world size = grid_size * zone_size) |
| `tick_rate` | 50 | Milliseconds between ticks (50 = 20 Hz) |
| `view_radius` | 1 | Zones visible in each direction from player's zone |
| `max_players` | 500 | Maximum concurrent players per world |
| `zone_idle_timeout` | 30000 | Milliseconds an empty zone lingers before it is released |
| `empty_grace_ms` | 0 | Milliseconds a world with no players lingers before it finishes (0 = finish immediately) |
| `snapshot_interval` | 600 | Ticks between zone snapshots (see [Snapshots](#snapshots)) |

### Procedural Generation

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

- `type` -- the entity type applied to every spawned instance.
- `base_state` -- a map merged into every entity spawned from the template.
- `respawn` -- optional respawn policy: `strategy` (currently `timer`),
  `delay` (milliseconds), `jitter` (milliseconds of random spread added to
  the delay), and `max_respawns` (cap, or `infinity`).
- `persistent` -- whether a spawned entity survives a zone snapshot/restore.
  Lua entities default to `true`.

At runtime, Lua scripts spawn from a template with
`game.zone.spawn("goblin", x, y, {overrides})`, where the optional table
overrides fields from the template's `base_state`.

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

`asobi_zone_snapshotter` periodically persists each zone's entities and
restores them on restart, before the zone accepts new subscribers. Tune the
cadence with the `snapshot_interval` config key (default 600, measured in
**ticks**, not milliseconds).

## Subscriptions

A player subscribes to the 3x3 neighbourhood of zones around their entity.
Membership is recomputed as the player moves: entering a zone streams a
snapshot of that zone's currently-visible entities, and leaving a zone stops
its updates.

## WebSocket Protocol

World messages use the `world.*` namespace. See the full
[WebSocket Protocol](websocket-protocol.md) for envelope format.

### Client to Server

| Type | Payload | Description |
|------|---------|-------------|
| `world.join` | `{"world_id": "..."}` | Join a specific world |
| `world.leave` | `{}` | Leave current world |
| `world.input` | `{"action": "move", "x": 100, "y": 200}` | Send input to your zone |

### Server to Client

| Type | Payload | Description |
|------|---------|-------------|
| `world.joined` | `{world_id, status, player_count, grid_size}` | Join confirmed |
| `world.left` | `{success: true}` | Leave confirmed |
| `world.tick` | `{tick, updates: [{op, id, ...}]}` | Zone delta broadcast |
| `world.finished` | `{world_id, result}` | World ended |

### Input Routing

When you send `world.input`, the message is routed to the zone process
that currently owns your player entity. You don't need to specify which
zone -- the server tracks your position and routes automatically.

## Chat Channels

World chat is configuration-driven. Enable the channel types you need per
game mode:

```erlang
{asobi, [
    {game_modes, #{
        ~"galaxy" => #{
            type => world,
            module => my_game,
            chat => #{
                world => true,       %% global channel for everyone in the world
                zone => true,        %% auto-join/leave as players move between zones
                proximity => 2       %% chat with players within N zones of you
            }
        }
    }}
]}
```

Lua equivalent:

```lua
-- In your world script globals
chat_world     = true
chat_zone      = true
chat_proximity = 2
```

### Channel Types

| Type | Scope | Lifecycle |
|------|-------|-----------|
| **World** | All players in the world instance | Join on world join, leave on world leave |
| **Zone** | Players in the same zone cell | Auto-swap when crossing zone boundaries |
| **Proximity** | Players within N zones | Follows your interest radius, updates on zone change |
| **Federation** | Federation members only | Managed by the social system (works automatically) |

### How It Works

Chat channels use the existing `asobi_chat_channel` system. The world
server automatically manages subscriptions:

- **On join**: player is added to world chat and their spawn zone's chat
- **On zone change**: old zone chat is left, new zone chat is joined.
  Proximity channels diff the old and new interest areas so only the
  delta is updated
- **On leave**: all world/zone/proximity channels are cleaned up

No extra client code needed. Chat messages arrive via the same WebSocket
as `chat.message` events. Clients just need to know the channel IDs,
which follow a predictable format:

- World: `world:{world_id}`
- Zone: `zone:{world_id}:{x},{y}`
- Proximity: `prox:{world_id}:{x},{y}`

### No Chat Config

If you omit the `chat` key entirely, no chat channels are created. The
world server runs without any chat overhead. Add channels later by
updating your mode config.

## Clustering

Zones are regular Erlang processes. In a multi-node cluster, they
distribute across nodes automatically via `pg`. A player on Node A can
be subscribed to a zone on Node B -- Erlang distribution handles the
message routing transparently.

For large worlds, zones are distributed round-robin across cluster nodes:

```
Node A: zones {0,0}..{4,4}  (25 zones)
Node B: zones {5,0}..{9,4}  (25 zones)
Node C: zones {0,5}..{4,9}  (25 zones)
Node D: zones {5,5}..{9,9}  (25 zones)
```

## Next Steps

- [Lua Scripting](lua-scripting.md) -- match-based Lua scripting
- [Voting](voting.md) -- in-game voting system
- [Matchmaking](matchmaking.md) -- how players enter worlds
- [Clustering](clustering.md) -- multi-node deployment
