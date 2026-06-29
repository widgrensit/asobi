-module(heightmap_terrain_provider_tests).
-include_lib("eunit/include/eunit.hrl").

%% The runnable proof of the terrain flow: start a terrain store with the
%% example provider, fetch a chunk through it, then decompress and decode the
%% payload back to tiles - exactly what a client does.

chunk_round_trips_through_the_store_test() ->
    Store = start_store(42),
    {ok, Payload} = asobi_terrain_store:get_chunk(Store, {0, 0}),
    ?assert(is_binary(Payload)),
    Tiles = asobi_terrain:decode_chunk(asobi_terrain:decompress_chunk(Payload)),
    #{chunk_width := Width, chunk_height := Height} = asobi_terrain:default_format(),
    %% The provider fills every tile with a non-zero id, so the whole grid
    %% survives the decode (zero-id tiles are dropped as empty).
    ?assertEqual(Width * Height, length(Tiles)),
    gen_server:stop(Store).

same_seed_and_coords_are_deterministic_test() ->
    A = start_store(7),
    B = start_store(7),
    {ok, ChunkA} = asobi_terrain_store:get_chunk(A, {3, 5}),
    {ok, ChunkB} = asobi_terrain_store:get_chunk(B, {3, 5}),
    ?assertEqual(ChunkA, ChunkB),
    gen_server:stop(A),
    gen_server:stop(B).

different_seeds_diverge_test() ->
    A = start_store(1),
    B = start_store(2),
    {ok, ChunkA} = asobi_terrain_store:get_chunk(A, {3, 5}),
    {ok, ChunkB} = asobi_terrain_store:get_chunk(B, {3, 5}),
    ?assertNotEqual(ChunkA, ChunkB),
    gen_server:stop(A),
    gen_server:stop(B).

start_store(Seed) ->
    {ok, Store} = asobi_terrain_store:start_link(#{
        provider => {heightmap_terrain_provider, #{}},
        seed => Seed
    }),
    Store.
