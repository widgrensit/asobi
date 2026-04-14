-module(asobi_terrain_test_provider).
-behaviour(asobi_terrain_provider).

-export([init/1, load_chunk/2, generate_chunk/3]).

init(Config) -> {ok, Config}.

load_chunk(_Coords, State) -> {error, not_found, State}.

generate_chunk({X, Y}, Seed, State) ->
    Tiles = [{0, 0, X + Y + Seed + 1, 0, 0}],
    Bin = asobi_terrain:compress_chunk(asobi_terrain:encode_chunk(Tiles)),
    {ok, Bin, State}.
