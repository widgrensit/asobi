-module(asobi_ws_binary).

-export([
    encode_terrain_chunk/2,
    decode_terrain_chunk/1,
    encode_entity_deltas/2,
    decode_entity_deltas/1,
    is_binary_mode/1
]).

-define(TYPE_TERRAIN_CHUNK, 16#01).
-define(TYPE_ENTITY_DELTA, 16#02).
-define(TYPE_MATCH_STATE, 16#03).

-define(OP_ADD, 0).
-define(OP_UPDATE, 1).
-define(OP_REMOVE, 2).

-spec encode_terrain_chunk({integer(), integer()}, binary()) -> binary().
encode_terrain_chunk({CX, CY}, CompressedData) ->
    Payload = <<CX:32/signed-big, CY:32/signed-big, CompressedData/binary>>,
    Len = byte_size(Payload),
    <<?TYPE_TERRAIN_CHUNK:8, Len:32/big, Payload/binary>>.

-spec decode_terrain_chunk(binary()) -> {{integer(), integer()}, binary()}.
decode_terrain_chunk(<<?TYPE_TERRAIN_CHUNK:8, Len:32/big, Payload:Len/binary>>) ->
    <<CX:32/signed-big, CY:32/signed-big, CompressedData/binary>> = Payload,
    {{CX, CY}, CompressedData}.

-spec encode_entity_deltas(non_neg_integer(), [map()]) -> binary().
encode_entity_deltas(TickN, Deltas) ->
    EncodedDeltas = [encode_delta(D) || D <- Deltas],
    Count = length(Deltas),
    DeltaBin = iolist_to_binary(EncodedDeltas),
    Payload = <<TickN:64/big, Count:32/big, DeltaBin/binary>>,
    Len = byte_size(Payload),
    <<?TYPE_ENTITY_DELTA:8, Len:32/big, Payload/binary>>.

-spec decode_entity_deltas(binary()) -> {non_neg_integer(), [map()]}.
decode_entity_deltas(<<?TYPE_ENTITY_DELTA:8, Len:32/big, Payload:Len/binary>>) ->
    <<TickN:64/big, Count:32/big, Rest/binary>> = Payload,
    {Deltas, <<>>} = decode_deltas(Rest, Count, []),
    {TickN, Deltas}.

-spec is_binary_mode(map()) -> boolean().
is_binary_mode(State) when is_map(State) ->
    maps:get(binary_protocol, State, false) =:= true.

%% --- Internal ---

encode_delta(#{op := Op, entity_id := EntityId, fields := Fields}) ->
    OpByte = op_to_byte(Op),
    IdBin = unicode:characters_to_binary(EntityId),
    IdLen = byte_size(IdBin),
    FieldsBin = iolist_to_binary(json:encode(Fields)),
    FieldsLen = byte_size(FieldsBin),
    <<OpByte:8, IdLen:16/big, IdBin/binary, FieldsLen:32/big, FieldsBin/binary>>;
encode_delta(#{op := Op, entity_id := EntityId}) ->
    OpByte = op_to_byte(Op),
    IdBin = unicode:characters_to_binary(EntityId),
    IdLen = byte_size(IdBin),
    <<OpByte:8, IdLen:16/big, IdBin/binary, 0:32/big>>.

decode_deltas(Rest, 0, Acc) ->
    {lists:reverse(Acc), Rest};
decode_deltas(
    <<OpByte:8, IdLen:16/big, IdBin:IdLen/binary, FieldsLen:32/big, FieldsBin:FieldsLen/binary,
        Rest/binary>>,
    Count,
    Acc
) ->
    Op = byte_to_op(OpByte),
    Delta0 = #{op => Op, entity_id => IdBin},
    Delta =
        case FieldsLen of
            0 -> Delta0;
            _ -> Delta0#{fields => json:decode(FieldsBin)}
        end,
    decode_deltas(Rest, Count - 1, [Delta | Acc]).

op_to_byte(add) -> ?OP_ADD;
op_to_byte(update) -> ?OP_UPDATE;
op_to_byte(remove) -> ?OP_REMOVE.

byte_to_op(?OP_ADD) -> add;
byte_to_op(?OP_UPDATE) -> update;
byte_to_op(?OP_REMOVE) -> remove.
