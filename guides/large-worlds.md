# Large Worlds

Scale the world server to handle massive tile-based maps with lazy zone
loading, terrain data serving, and configurable zone lifecycle management.

Everything here is game logic and config. It is written once and runs the same
whether you deploy to managed Cloud (`asobi deploy`, console.asobi.dev) or
self-host your own release of asobi + asobi_lua. The one exception - shipping a
custom terrain generator - is called out under [Terrain Data](#terrain-data).

## Lazy Zone Loading

By default, all zones in a world are spawned at startup. For large worlds
(thousands of zones), enable lazy loading so zones are created on demand when a
player enters. The config keys are globals at the top of your world script.

<!-- tabs -->
**Lua**
```lua
-- world.lua
game_type         = "world"
grid_size         = 2000
zone_size         = 64
lazy_zones        = true
zone_idle_timeout = 30000
max_active_zones  = 10000
```

**Erlang**
```erlang
Config = #{
    game_module => my_world,
    grid_size => 2000,
    zone_size => 64,
    lazy_zones => true,
    zone_idle_timeout => 30000,
    max_active_zones => 10000
}.
```
<!-- /tabs -->

With `lazy_zones` on:

- Zones are created when a player joins or moves into them.
- Interest zones (adjacent to the player) only subscribe if already loaded.
- Idle zones are snapshotted to the database and terminated after `zone_idle_timeout`.
- `max_active_zones` caps concurrent zone processes and prevents runaway memory.

`lazy_zones` auto-enables when `grid_size > 100`. For small worlds
(`grid_size <= 100`) all zones are pre-warmed at startup regardless of the
setting.

## Zone Lifecycle

Each zone follows this lifecycle:

```
[not loaded] --ensure_zone--> [active] --no subscribers--> [idle]
     ^                                                        |
     |                    idle_timeout expires                 |
     +---<---snapshot + terminate---<---reap---<--------------+
```

A zone with subscribers resets its idle timer each tick. When subscribers drop
to zero and the zone has no tickable entities, it enters BEAM hibernation to
reduce memory, then is snapshotted and reaped once `zone_idle_timeout` expires.

## Terrain Data

Terrain is separate from entities. Tile chunks are served as compressed binary
blobs when a player subscribes to a zone, not through the tick/delta loop.

Asobi does not define what terrain is. A provider returns the bytes of the chunk
at a `{X, Y}` coordinate; Asobi caches that blob in the terrain store and ships
it to clients verbatim. The payload is whatever your provider produces. A
complete, runnable provider lives in
[`examples/world-terrain`](https://github.com/widgrensit/asobi/tree/main/examples/world-terrain).

The split is: Lua selects a provider, Erlang implements one.

### Selecting a Provider

Your world script names its provider from `terrain_provider`, returning the
module name and its args as a keyed table.

<!-- tabs -->
**Lua**
```lua
-- world.lua
function terrain_provider(config)
    return { module = "asobi_terrain_perlin", args = { seed = 42 } }
end
```

**Erlang**
```erlang
terrain_provider(Config) ->
    {asobi_terrain_perlin, #{seed => maps:get(seed, Config, 42)}}.
```
<!-- /tabs -->

Return `nil` (Lua) or `none` (Erlang) for a world with no terrain.

Two providers ship built in: `asobi_terrain_flat` and `asobi_terrain_perlin`.
The name is checked against an allowlist rather than resolved as an arbitrary
module, so a script cannot name `gen_server` or any other loaded module. A name
that is not on the list is rejected with `terrain_provider_not_allowed`.

**Cloud:** the two built-in providers are available with no configuration.

**Self-hosted:** extend the allowlist to admit your own provider. This is an
`asobi_lua` key, set in sys.config - see
[Terrain provider allowlist](configuration.md#terrain-provider-allowlist):

```erlang
{asobi_lua, [
    {terrain_providers, [asobi_terrain_flat, asobi_terrain_perlin, my_terrain]}
]}
```

A custom provider is a compiled Erlang module, so shipping one means running
your own release: it is a self-hosted feature. On managed Cloud, stick to the
built-ins.

### Terrain Provider Behaviour (Erlang)

Implement `asobi_terrain_provider` to supply terrain data. This is Erlang only,
the same split as matchmaker strategies.

```erlang
-module(my_terrain).
-behaviour(asobi_terrain_provider).
-export([init/1, load_chunk/2, generate_chunk/3]).

init(Config) ->
    {ok, Config}.

load_chunk({X, Y}, State) ->
    {error, not_found}.

generate_chunk({X, Y}, Seed, State) ->
    Tiles = generate_tiles(X, Y, Seed),
    Bin = asobi_terrain:compress_chunk(asobi_terrain:encode_chunk(Tiles)),
    {ok, Bin, State}.
```

`load_chunk/2` loads from file or database; returning `{error, not_found}` falls
back to `generate_chunk/3` for procedural generation.

When a player subscribes to a zone, they receive a `world.terrain` message with
the compressed chunk data (base64-encoded in JSON).

### Terrain Encoding

`asobi_terrain` encodes tiles as compact binaries:

- Default format: 4 bytes per tile (2B tile_id, 1B flags, 1B elevation).
- 64x64 chunk = 16KB raw, typically 2-4KB compressed.
- Custom formats via the `format` parameter.

```erlang
Tiles = [{0, 0, 1, 0, 10}, {3, 5, 200, 15, 255}],
Bin = asobi_terrain:encode_chunk(Tiles),
Compressed = asobi_terrain:compress_chunk(Bin).
```

### Terrain Store

The terrain store is an ETS-backed cache that lazy-loads chunks from the
provider. It starts automatically when the game returns a terrain provider.
Chunks are cached after first load.

## Zone Lifecycle Callbacks

A world script can react to zones loading and unloading. Both callbacks are
optional.

<!-- tabs -->
**Lua**
```lua
-- world.lua
function on_zone_loaded(cx, cy, state)
    local zone_state = { biome = "plains" }
    return zone_state, state
end

function on_zone_unloaded(cx, cy, state)
    return state
end
```

**Erlang**
```erlang
-callback terrain_provider(Config :: map()) ->
    {Module :: module(), ProviderArgs :: map()} | none.

-callback on_zone_loaded(Coords :: {integer(), integer()}, GameState :: term()) ->
    {ok, ZoneState :: map(), GameState1 :: term()}.

-callback on_zone_unloaded(Coords :: {integer(), integer()}, GameState :: term()) ->
    {ok, GameState1 :: term()}.
```
<!-- /tabs -->

## Configuration Reference

| Key | Default | Description |
|-----|---------|-------------|
| `grid_size` | `10` | Zones per dimension |
| `zone_size` | `200` | World units per zone |
| `lazy_zones` | `grid_size > 100` | Enable on-demand zone loading |
| `zone_idle_timeout` | `30000` | Milliseconds before idle zones are reaped |
| `max_active_zones` | `10000` | Maximum concurrent zone processes |

## Scaling Guidelines

Asobi is single-node by design. These figures are per node.

| Map Size | Zones | Recommended Config |
|----------|-------|--------------------|
| Small (1K x 1K) | 100 | Default (eager loading) |
| Medium (10K x 10K) | 10,000 | `lazy_zones = true` |
| Large (128K x 128K) | 4,000,000 | Lazy + terrain provider + tuned idle timeout |

For large worlds, expect 200-500 concurrent zone processes per node with typical
player clustering. The BEAM handles this efficiently; the bottleneck is
serialisation and network I/O, not process count.

## Checkpoint

1. Set `game_type = "world"`, `grid_size = 2000` and `lazy_zones = true` in
   `world.lua`, then start your world (Cloud: `asobi deploy`; self-hosted: your
   release).
2. Connect a client and move into a zone. On the server, confirm only a handful
   of zones are active, not four million:

   ```
   Active zones climb as players spread out, and idle zones vanish after
   zone_idle_timeout - not all grid_size^2 zones at once.
   ```
3. If you named a `terrain_provider`, the subscribing client receives a
   `world.terrain` message with a non-empty base64 chunk. An empty chunk or a
   `terrain_provider_not_allowed` log means the name is not on the allowlist.

## Next

[Performance Tuning](performance-tuning.md) - spatial-grid indexing, adaptive
tick rates, and shared-state broadcast for busy zones.
