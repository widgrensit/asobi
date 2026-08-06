# Large worlds

Running the world server over a big tile map: how zones come and go, and how
terrain is served.

Everything here is game logic and config. It is the same whether you run the
image and write Lua or depend on the Hex package and write Erlang. The one
exception, shipping a custom terrain generator, is called out under
[Terrain data](#terrain-data).

## Zones are created on demand above grid_size 100

A world with `grid_size > 100` creates zones lazily, when a player joins or
moves into one. At or below 100 it pre-warms every zone at startup. That
threshold is the deployment's behaviour and there is no configuration key that
changes it.

Two more numbers are fixed the same way:

- **Zone idle: 30s.** A zone becomes reap-eligible 30s after its last touch, or
  immediately when its last occupant leaves. The sweep that acts on that runs
  every 10s.
- **Active zones: 10,000 per world.** This is a hard ceiling, not a
  recommendation. A world that needs more concurrent zones than that needs
  bigger zones (`zone_size`) or a smaller grid.

A mode script declares the map itself:

```lua
-- lua/world.lua
game_type   = "world"
match_size  = 1
max_players = 200
grid_size   = 2000
zone_size   = 64
view_radius = 1
```

`match_size` is required in every mode script, world modes included; the loader
rejects a script without it. A file named `world.lua` is only loaded when a
`config.lua` maps a mode name to it:

```lua
-- lua/config.lua
return {
    frontier = "world.lua",
}
```

A complete, runnable pair lives in
[`examples/world-walkers`](https://github.com/widgrensit/asobi/tree/main/examples/world-walkers).

In Erlang the same keys are mode config, and the mode declares `module`:

```erlang
{asobi, [
    {game_modes, #{
        ~"frontier" => #{
            type => world,
            module => my_world,
            grid_size => 2000,
            zone_size => 64
        }
    }}
]}.
```

`game_module` is an internal key of the world server, derived from `module`.
Setting it in mode config does nothing.

## Zone lifecycle

```
[not loaded] --ensure_zone--> [active] --last occupant leaves--> [idle]
     ^                                                             |
     |                    reap sweep (every 10s)                   |
     +---<-------------- stop, if empty ------------<--------------+
```

A zone with subscribers resets its idle timer each tick. When subscribers drop
to zero and the zone holds no NPCs, it hibernates to shrink its heap.

A reap is a proposal, not an order. A zone that still holds entities declines
it and re-touches its own timer; only an empty zone stops. A join or crossing
that finds its zone reaped between resolving the pid and placing the player
transparently starts a replacement zone and places them there.

Zone state is **not** snapshotted on the way out. Zone persistence exists in
the zone process but no configuration path reaches it, so entities in a
reaped zone are gone. Do not design a world that depends on a zone's contents
surviving the players leaving it - write anything durable to your own tables
from a callback.

`persistent = true` in a mode's config does one reachable thing today: it keeps
an emptied world alive instead of finishing it.

## Terrain data

Terrain is separate from entities. Tile chunks are served when a player
subscribes to a zone, not through the tick and delta loop.

asobi does not define what terrain is. A provider returns the bytes of the
chunk at a `{X, Y}` coordinate; asobi caches that blob in the terrain store and
ships it to clients verbatim, base64-encoded inside a JSON `world.terrain`
frame. The payload is whatever your provider produces. A complete, runnable
provider lives in
[`examples/world-terrain`](https://github.com/widgrensit/asobi/tree/main/examples/world-terrain).

The split is: Lua selects a provider, Erlang implements one.

### Selecting a provider

Your world script names its provider from `terrain_provider`, returning the
module name and its arguments as a keyed table.

```lua
function terrain_provider(config)
    return { module = "asobi_terrain_perlin", args = { seed = 42 } }
end
```

In Erlang:

```erlang
terrain_provider(Config) ->
    {asobi_terrain_perlin, #{seed => maps:get(seed, Config, 42)}}.
```

Return `nil` (Lua) or `none` (Erlang) for a world with no terrain.

Two providers ship built in: `asobi_terrain_flat` and `asobi_terrain_perlin`.
The name is checked against an allowlist rather than resolved as an arbitrary
module, so a script cannot name `gen_server` or anything else that happens to
be loaded. A name that is not on the list logs a `terrain_provider_not_allowed`
warning and the world starts with **no terrain store at all** - clients receive
no `world.terrain` message, rather than an empty one.

To admit your own provider, extend the allowlist in `sys.config`:

```erlang
{asobi, [
    {terrain_providers, [asobi_terrain_flat, asobi_terrain_perlin, my_terrain]}
]}
```

See [Terrain provider allowlist](configuration.md#terrain-provider-allowlist),
and [Which application key](configuration.md#which-application-key) if you still
have an `{asobi_lua, [...]}` block.

A custom provider is a compiled Erlang module, so shipping one means building
your own release.

### Terrain provider behaviour (Erlang)

Implement `asobi_terrain_provider`. There is no Lua path for this, the same
split as matchmaker strategies.

```erlang
-module(my_terrain).
-behaviour(asobi_terrain_provider).
-export([init/1, load_chunk/2, generate_chunk/3]).

init(Config) ->
    {ok, Config}.

load_chunk({_X, _Y}, _State) ->
    {error, not_found}.

generate_chunk({X, Y}, Seed, State) ->
    Tiles = generate_tiles(X, Y, Seed),
    Bin = asobi_terrain:compress_chunk(asobi_terrain:encode_chunk(Tiles)),
    {ok, Bin, State}.
```

`load_chunk/2` loads from file or database; returning `{error, not_found}`
falls back to `generate_chunk/3` for procedural generation.

### Terrain encoding

`asobi_terrain` encodes tiles as compact binaries:

- Default format: 4 bytes per tile (2B tile_id, 1B flags, 1B elevation), 64x64
  tiles per chunk.
- A 64x64 chunk is 16KB raw, typically 2-4KB compressed.
- Other tile sizes and chunk dimensions via `encode_chunk/2`.

A tile is `{X, Y, TileId, Flags, Elevation}`:

```erlang
Tiles = [{0, 0, 1, 0, 10}, {3, 5, 200, 15, 255}],
Bin = asobi_terrain:encode_chunk(Tiles),
Compressed = asobi_terrain:compress_chunk(Bin).
```

### Terrain store

The terrain store is an ETS-backed cache that lazy-loads chunks from the
provider. It starts automatically when the game returns a terrain provider, and
caches each chunk after first load. It is per node, like every other cache -
see [Clustering](clustering.md#what-is-per-node).

## Zone lifecycle callbacks

A world script can react to zones loading and unloading. Both callbacks are
optional.

```lua
function on_zone_loaded(cx, cy, state)
    local zone_state = { biome = "plains" }
    return zone_state, state
end

function on_zone_unloaded(cx, cy, state)
    return state
end
```

In Erlang:

```erlang
-callback terrain_provider(Config :: map()) ->
    {Module :: module(), ProviderArgs :: map()} | none.

-callback on_zone_loaded(Coords :: {integer(), integer()}, GameState :: term()) ->
    {ok, ZoneState :: map(), GameState1 :: term()}.

-callback on_zone_unloaded(Coords :: {integer(), integer()}, GameState :: term()) ->
    {ok, GameState1 :: term()}.
```

## Configuration reference

| Key | Default | What it does |
|-----|---------|--------------|
| `grid_size` | `10` | Zones per dimension. Above 100, zones load on demand. |
| `zone_size` | `200` | World units per zone. |
| `view_radius` | `1` | Zone radius a player subscribes to. 0 means own zone only. |
| `tick_rate` | `50` | Milliseconds per world tick. |
| `max_players` | `500`, but `match_size` in a Lua script | Players per world. |
| `persistent` | `false` | Keep an emptied world alive instead of finishing it. |

## Scaling guidelines

One world lives entirely on one node, so these are per world and per node. More
nodes means more worlds, not a bigger world - see
[Clustering](clustering.md#the-scaling-unit-is-a-world-not-a-node).

A world can hold at most 10,000 active zones at once. Grids above roughly
100x100 only work because most of the map is unloaded most of the time: with
typical player clustering, expect a few hundred live zone processes. If your
players do not cluster, the ceiling is what you will hit, and the fix is a
larger `zone_size`.

The bottleneck at that scale is serialisation and network I/O, not process
count. The BEAM is comfortable with thousands of zone processes; the tick that
encodes deltas for all of them is what runs out of time first.

## Checkpoint

1. Put a `config.lua` mapping a mode to `world.lua`, with `game_type = "world"`,
   `match_size = 1` and `grid_size = 2000`, then start your world.
2. Connect a client and move into a zone. Only a handful of zones should be
   active, not four million: active zones climb as players spread out and fall
   again as they leave, and no zone is created until somebody enters it.
3. If you named a `terrain_provider`, the subscribing client receives a
   `world.terrain` message with a non-empty base64 chunk. No `world.terrain`
   message at all, plus a `terrain_provider_not_allowed` warning in the log,
   means the name is not on the allowlist.

## Next

[Performance tuning](performance-tuning.md) - spatial queries, shared-state
broadcast, and what the zone tick costs.
