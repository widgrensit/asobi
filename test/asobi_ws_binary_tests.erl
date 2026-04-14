-module(asobi_ws_binary_tests).

-include_lib("eunit/include/eunit.hrl").

%% --- Terrain Chunk ---

terrain_chunk_roundtrip_test() ->
    Coords = {10, -5},
    Data = crypto:strong_rand_bytes(256),
    Encoded = asobi_ws_binary:encode_terrain_chunk(Coords, Data),
    ?assertEqual({Coords, Data}, asobi_ws_binary:decode_terrain_chunk(Encoded)).

terrain_chunk_negative_coords_test() ->
    Coords = {-100, -200},
    Data = ~"terrain_data",
    Encoded = asobi_ws_binary:encode_terrain_chunk(Coords, Data),
    ?assertEqual({Coords, Data}, asobi_ws_binary:decode_terrain_chunk(Encoded)).

terrain_chunk_empty_data_test() ->
    Coords = {0, 0},
    Encoded = asobi_ws_binary:encode_terrain_chunk(Coords, <<>>),
    ?assertEqual({Coords, <<>>}, asobi_ws_binary:decode_terrain_chunk(Encoded)).

terrain_chunk_tlv_structure_test() ->
    Data = ~"abc",
    Encoded = asobi_ws_binary:encode_terrain_chunk({1, 2}, Data),
    <<Type:8, Len:32/big, _Payload:Len/binary>> = Encoded,
    ?assertEqual(16#01, Type),
    ?assertEqual(4 + 4 + 3, Len).

terrain_chunk_size_vs_json_test() ->
    ChunkData = crypto:strong_rand_bytes(1024),
    BinaryEncoded = asobi_ws_binary:encode_terrain_chunk({5, 10}, ChunkData),
    JsonPayload = json:encode(#{
        coords => [5, 10],
        data => base64:encode(ChunkData)
    }),
    BinarySize = byte_size(BinaryEncoded),
    JsonSize = byte_size(iolist_to_binary(JsonPayload)),
    ?assert(BinarySize < JsonSize),
    Savings = (1 - BinarySize / JsonSize) * 100,
    ct:pal(
        "Binary: ~B bytes, JSON+base64: ~B bytes, savings: ~.1f%",
        [BinarySize, JsonSize, Savings]
    ).

%% --- Entity Deltas ---

entity_deltas_roundtrip_test() ->
    Deltas = [
        #{op => add, entity_id => ~"player-1", fields => #{~"x" => 10, ~"y" => 20}},
        #{op => update, entity_id => ~"player-2", fields => #{~"hp" => 50}},
        #{op => remove, entity_id => ~"mob-99"}
    ],
    Encoded = asobi_ws_binary:encode_entity_deltas(42, Deltas),
    {TickN, Decoded} = asobi_ws_binary:decode_entity_deltas(Encoded),
    ?assertEqual(42, TickN),
    ?assertEqual(3, length(Decoded)),
    [D1, D2, D3] = Decoded,
    ?assertEqual(add, maps:get(op, D1)),
    ?assertEqual(~"player-1", maps:get(entity_id, D1)),
    ?assertEqual(10, maps:get(~"x", maps:get(fields, D1))),
    ?assertEqual(update, maps:get(op, D2)),
    ?assertEqual(remove, maps:get(op, D3)),
    ?assertEqual(false, maps:is_key(fields, D3)).

entity_deltas_empty_test() ->
    Encoded = asobi_ws_binary:encode_entity_deltas(0, []),
    ?assertEqual({0, []}, asobi_ws_binary:decode_entity_deltas(Encoded)).

entity_deltas_tlv_structure_test() ->
    Deltas = [#{op => add, entity_id => ~"e1", fields => #{~"a" => 1}}],
    Encoded = asobi_ws_binary:encode_entity_deltas(1, Deltas),
    <<Type:8, _Len:32/big, _/binary>> = Encoded,
    ?assertEqual(16#02, Type).

entity_deltas_large_tick_test() ->
    TickN = 1 bsl 48,
    Deltas = [#{op => update, entity_id => ~"e1", fields => #{~"v" => true}}],
    Encoded = asobi_ws_binary:encode_entity_deltas(TickN, Deltas),
    {DecodedTick, _} = asobi_ws_binary:decode_entity_deltas(Encoded),
    ?assertEqual(TickN, DecodedTick).

entity_deltas_unicode_id_test() ->
    Id = unicode:characters_to_binary([16#1F680, $-, $a]),
    Deltas = [#{op => add, entity_id => Id, fields => #{}}],
    Encoded = asobi_ws_binary:encode_entity_deltas(1, Deltas),
    {_, [D]} = asobi_ws_binary:decode_entity_deltas(Encoded),
    ?assertEqual(Id, maps:get(entity_id, D)).

%% --- is_binary_mode ---

is_binary_mode_true_test() ->
    ?assertEqual(true, asobi_ws_binary:is_binary_mode(#{binary_protocol => true})).

is_binary_mode_false_test() ->
    ?assertEqual(false, asobi_ws_binary:is_binary_mode(#{binary_protocol => false})).

is_binary_mode_missing_test() ->
    ?assertEqual(false, asobi_ws_binary:is_binary_mode(#{})).

is_binary_mode_non_boolean_test() ->
    ?assertEqual(false, asobi_ws_binary:is_binary_mode(#{binary_protocol => ~"yes"})).
