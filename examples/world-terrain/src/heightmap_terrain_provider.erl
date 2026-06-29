-module(heightmap_terrain_provider).

-moduledoc """
Example `m:asobi_terrain_provider`: a procedural heightmap.

Every chunk is generated from its world coordinates and the world seed, so
there is no stored data: `load_chunk/2` always misses and the world server
falls back to `generate_chunk/3`. A real provider would serve stored chunks
from disk or a database in `load_chunk/2` and keep `generate_chunk/3` for
never-visited coordinates.

The point this example makes: the chunk payload is *your* bytes. Here each
tile is `{TileId, Flags, Elevation}` and we use the `m:asobi_terrain`
helpers to pack and zlib-compress the grid. Asobi caches and ships that
blob verbatim; the client decodes it with the matching format.
""".

-behaviour(asobi_terrain_provider).

-export([init/1, load_chunk/2, generate_chunk/3]).

-define(TILE_WATER, 1).
-define(TILE_GRASS, 2).
-define(SEA_LEVEL, 96).

init(Config) ->
    {ok, Config}.

load_chunk(_Coords, _State) ->
    {error, not_found}.

generate_chunk({ChunkX, ChunkY}, Seed, State) ->
    #{chunk_width := Width, chunk_height := Height} = asobi_terrain:default_format(),
    Tiles = maps:from_list([
        tile_at(ChunkX * Width + X, ChunkY * Height + Y, X, Y, Seed)
     || X <- lists:seq(0, Width - 1), Y <- lists:seq(0, Height - 1)
    ]),
    Payload = asobi_terrain:compress_chunk(asobi_terrain:encode_chunk(Tiles)),
    {ok, Payload, State}.

tile_at(WorldX, WorldY, X, Y, Seed) ->
    Elevation = erlang:phash2({WorldX div 8, WorldY div 8, Seed}, 256),
    TileId =
        case Elevation < ?SEA_LEVEL of
            true -> ?TILE_WATER;
            false -> ?TILE_GRASS
        end,
    {{X, Y}, {TileId, 0, Elevation}}.
