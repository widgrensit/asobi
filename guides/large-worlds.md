# Large Worlds

Scale the world server to handle massive tile-based maps with lazy zone
loading, terrain data serving, and configurable zone lifecycle management.

## Lazy Zone Loading

By default, all zones in a world are spawned at startup. For large worlds
(thousands of zones), enable lazy loading so zones are created on demand
when a player enters.

```erlang
Config = #{
    game_module => my_world,
    grid_size => 2000,          %% 2000x2000 zone grid
    zone_size => 64,            %% 64 tiles per zone
    lazy_zones => true,         %% auto-true when grid_size > 100
    zone_idle_timeout => 30000, %% reap idle zones after 30s
    max_active_zones => 10000   %% cap concurrent zone processes
}.
```

With `lazy_zones => true`:

- Zones are created when a player joins or moves into them
- Interest zones (adjacent to the player) only subscribe if already loaded
- Idle zones are snapshotted to the database and terminated after `zone_idle_timeout`
- The `max_active_zones` cap prevents runaway memory usage

For small worlds (`grid_size =< 100`), all zones are pre-warmed at startup
regardless of the `lazy_zones` setting.

## Zone Lifecycle

Each zone follows this lifecycle:

```
[not loaded] --ensure_zone--> [active] --no subscribers--> [idle]
     ^                                                        |
     |                    idle_timeout expires                 |
     +---<---snapshot + terminate---<---reap---<--------------+
```

Active zones call `touch_zone` each tick when they have subscribers,
resetting the idle timer. When subscribers drop to zero and the zone has
no tickable entities, it enters Erlang hibernation to reduce memory.

## Terrain Data

Terrain is separate from entities. Tile chunks are served as compressed
binary blobs when a player subscribes to a zone -- not through the
tick/delta loop.

### Terrain Provider Behaviour

Implement `asobi_terrain_provider` to supply terrain data:

```erlang
-module(my_terrain).
-behaviour(asobi_terrain_provider).
-export([init/1, load_chunk/2, generate_chunk/3]).

init(Config) ->
    {ok, Config}.

load_chunk({X, Y}, State) ->
    %% Load from file, database, etc.
    {error, not_found}.  %% Falls back to generate_chunk/3

generate_chunk({X, Y}, Seed, State) ->
    %% Procedural generation
    Tiles = generate_tiles(X, Y, Seed),
    Bin = asobi_terrain:compress_chunk(
        asobi_terrain:encode_chunk(Tiles)
    ),
    {ok, Bin, State}.
```

### Connecting to the World

Add `terrain_provider/1` to your world game module:

```erlang
-module(my_world).
-behaviour(asobi_world).

terrain_provider(Config) ->
    {my_terrain, #{seed => maps:get(seed, Config, 42)}}.
```

When a player subscribes to a zone, they receive a `world.terrain` message
with the compressed chunk data (base64-encoded in JSON).

### Terrain Encoding

`asobi_terrain` encodes tiles as compact binaries:

- Default format: 4 bytes per tile (2B tile_id, 1B flags, 1B elevation)
- 64x64 chunk = 16KB raw, typically 2-4KB compressed
- Custom formats via the `format` parameter

```erlang
Tiles = [{0, 0, 1, 0, 10}, {3, 5, 200, 15, 255}],
Bin = asobi_terrain:encode_chunk(Tiles),
Compressed = asobi_terrain:compress_chunk(Bin),
%% Compressed is typically 75-85% smaller
```

### Terrain Store

The terrain store is an ETS-backed cache that lazy-loads chunks from the
provider. It is started automatically when the game module returns a
terrain provider. Chunks are cached after first load.

## Configuration Reference

| Key | Default | Description |
|-----|---------|-------------|
| `lazy_zones` | `grid_size > 100` | Enable on-demand zone loading |
| `zone_idle_timeout` | `30000` | Milliseconds before idle zones are reaped |
| `max_active_zones` | `10000` | Maximum concurrent zone processes |
| `grid_size` | `10` | Zones per dimension |
| `zone_size` | `200` | World units per zone |

## New Behaviour Callbacks

These optional callbacks are available on `asobi_world`:

```erlang
-callback terrain_provider(Config :: map()) ->
    {Module :: module(), ProviderArgs :: map()} | none.

-callback on_zone_loaded(Coords :: {integer(), integer()}, GameState :: term()) ->
    {ok, ZoneState :: map(), GameState1 :: term()}.

-callback on_zone_unloaded(Coords :: {integer(), integer()}, GameState :: term()) ->
    {ok, GameState1 :: term()}.
```

## Scaling Guidelines

| Map Size | Zones | Recommended Config |
|----------|-------|--------------------|
| Small (1K x 1K) | 100 | Default (eager loading) |
| Medium (10K x 10K) | 10,000 | `lazy_zones => true` |
| Large (128K x 128K) | 4,000,000 | Lazy + terrain provider + tuned idle timeout |

For large worlds, expect 200-500 concurrent zone processes per node with
typical player clustering. The BEAM handles this efficiently -- the
bottleneck is serialisation and network I/O, not process count.
