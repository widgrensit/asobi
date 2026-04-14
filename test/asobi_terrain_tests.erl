-module(asobi_terrain_tests).
-include_lib("eunit/include/eunit.hrl").

default_format_test() ->
    Fmt = asobi_terrain:default_format(),
    ?assertEqual(64, maps:get(chunk_width, Fmt)),
    ?assertEqual(64, maps:get(chunk_height, Fmt)),
    ?assertEqual(4, maps:get(tile_size, Fmt)).

chunk_byte_size_test() ->
    ?assertEqual(16384, asobi_terrain:chunk_byte_size(asobi_terrain:default_format())).

encode_decode_roundtrip_test() ->
    Tiles = [{0, 0, 1, 0, 10}, {3, 5, 200, 15, 255}, {63, 63, 65535, 255, 128}],
    Bin = asobi_terrain:encode_chunk(Tiles),
    Decoded = asobi_terrain:decode_chunk(Bin),
    lists:foreach(
        fun(Tile) ->
            ?assert(lists:member(Tile, Decoded))
        end,
        Tiles
    ).

encode_size_test() ->
    Bin = asobi_terrain:encode_chunk([]),
    ?assertEqual(16384, byte_size(Bin)).

encode_map_input_test() ->
    TileMap = #{{0, 0} => {1, 0, 10}, {1, 0} => {2, 3, 50}},
    Bin = asobi_terrain:encode_chunk(TileMap, asobi_terrain:default_format()),
    ?assertEqual(16384, byte_size(Bin)),
    Decoded = asobi_terrain:decode_chunk(Bin),
    ?assert(lists:member({0, 0, 1, 0, 10}, Decoded)),
    ?assert(lists:member({1, 0, 2, 3, 50}, Decoded)).

decode_skips_zero_tiles_test() ->
    Decoded = asobi_terrain:decode_chunk(asobi_terrain:encode_chunk([])),
    ?assertEqual([], Decoded).

compress_decompress_roundtrip_test() ->
    Tiles = [{X, Y, X + Y + 1, 0, 0} || X <- lists:seq(0, 63), Y <- lists:seq(0, 63)],
    Bin = asobi_terrain:encode_chunk(Tiles),
    Compressed = asobi_terrain:compress_chunk(Bin),
    ?assert(byte_size(Compressed) < byte_size(Bin)),
    Decompressed = asobi_terrain:decompress_chunk(Compressed),
    ?assertEqual(Bin, Decompressed).

compression_ratio_test() ->
    Bin = asobi_terrain:encode_chunk([{0, 0, 1, 0, 0}]),
    Compressed = asobi_terrain:compress_chunk(Bin),
    ?assert(byte_size(Compressed) < byte_size(Bin) div 2).

custom_format_test() ->
    Fmt = #{tile_size => 4, chunk_width => 4, chunk_height => 4},
    ?assertEqual(64, asobi_terrain:chunk_byte_size(Fmt)),
    Tiles = [{0, 0, 1, 0, 0}, {3, 3, 2, 0, 0}],
    Bin = asobi_terrain:encode_chunk(Tiles, Fmt),
    ?assertEqual(64, byte_size(Bin)),
    Decoded = asobi_terrain:decode_chunk(Bin, Fmt),
    ?assert(lists:member({0, 0, 1, 0, 0}, Decoded)),
    ?assert(lists:member({3, 3, 2, 0, 0}, Decoded)).

max_tile_values_test() ->
    Tiles = [{0, 0, 65535, 255, 255}],
    Bin = asobi_terrain:encode_chunk(Tiles),
    Decoded = asobi_terrain:decode_chunk(Bin),
    ?assert(lists:member({0, 0, 65535, 255, 255}, Decoded)).
