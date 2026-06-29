# world-terrain

A terrain provider for the asobi world server: how you tell Asobi what data
it is chunking.

## The mental model

Asobi does not define what terrain is. It asks a provider you write for the
bytes of the chunk at a `{X, Y}` coordinate, caches that blob in
`asobi_terrain_store`, and ships it to clients on zone entry. The payload is
whatever your provider returns. Asobi never looks inside it; the client
decodes it.

So "the data Asobi is chunking" is the data your provider hands back. You
choose the format. This example uses the built-in tile format, but a binary
your client understands works just as well.

```
client enters zone (X,Y)
        |
        v
asobi_terrain_store:get_chunk(Store, {X,Y})
        |  cache miss
        v
provider:load_chunk({X,Y}, S)   --> {error, not_found}
        |  fall back
        v
provider:generate_chunk({X,Y}, Seed, S) --> {ok, <<compressed tiles>>, S}
        |  cache + ship verbatim
        v
client decompresses + decodes the bytes
```

## The provider behaviour

Implement `asobi_terrain_provider` (see `src/heightmap_terrain_provider.erl`):

- `init(Args)` once at startup; returns the state threaded through later calls.
- `load_chunk({X,Y}, State)` returns a stored chunk, or `{error, not_found}`
  to fall back to `generate_chunk/3`.
- `generate_chunk({X,Y}, Seed, State)` (optional) builds a chunk procedurally.

The `asobi_terrain` helpers build the built-in payload: a chunk is a grid of
`{TileId, Flags, Elevation}` tiles, `encode_chunk/1` packs it (4 bytes/tile,
64x64 by default), `compress_chunk/1` zlib-compresses it. The client mirrors
`decompress_chunk/1` then `decode_chunk/1`.

## Wiring it to a world

Export `terrain_provider/1` from your `asobi_world` game module
(`src/world_terrain_game.erl`):

```erlang
terrain_provider(_Config) ->
    {heightmap_terrain_provider, #{}}.
```

That is the whole handshake. Asobi starts a terrain store with the module and
args you return.

### From Lua

A Lua game can return a provider too, but only an **allowlisted** Erlang
module (terrain logic cannot be written in Lua):

```lua
function terrain_provider(config)
    return { module = "heightmap_terrain_provider", args = {} }
end
```

The module must be listed in `asobi_lua`'s `terrain_providers` env, or it is
rejected with `terrain_provider_not_allowed`.

## Run it

The terrain flow is verified by a test that drives a real `asobi_terrain_store`
through the provider and decodes the result:

```
rebar3 eunit
```

To run the full world server, start Postgres and a shell:

```
docker compose up -d
rebar3 shell
```

The `overworld` mode in `config/sys.config` is served by
`world_terrain_game`, which supplies the heightmap provider.
