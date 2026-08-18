-module(asobi_wire).
-moduledoc """
The binary encoding of `world.tick`, for clients that negotiate it.

Same information as the JSON frame, ~5x fewer bytes and materially cheaper to
decode on the client - measured at 2.4x faster than native JSON in Godot's
GDScript and 33x faster than the pure-Lua parser Defold and LOVE ship
(ADR 0013, decision 1). The server-side saving is negligible and is not the
reason this exists; the client-side one is.

## Why a per-frame field dictionary

An entity is an open map of arbitrary game-authored values, so a fixed
`x, y, vx, vy` layout cannot encode one. The obvious alternative, a negotiated
global name table, is state both ends have to agree on and re-agree after a
reconnect.

Instead each frame carries its own dictionary: the distinct field names once,
then every record refers to them by index. Forty records all carrying
`x, y, vx, vy` pay for four names, not a hundred and sixty. The frame stays
self-describing, decoding needs nothing the frame does not contain, and a game
can add a field without either side being told.

## Layout

Every multi-byte integer and float is **little-endian**, which is worth one
sentence of explanation because it is not what a wire format usually chooses.
Godot's `PackedByteArray.decode_*` reads little-endian and has no big-endian
counterpart, so network byte order would force a hand-rolled byte loop in
interpreted GDScript - and the native calls are precisely what made the codec
2.4x faster than JSON there rather than slower. Every other target reads either
order for the same price, so the runtime with no room to spare picks.

    frame    Kind:8, ZX:32/signed, ZY:32/signed, FrameSeq:64, Kf:8, Tick:64,
             DictLen:8, Dict, RecCount:16, Records

    dict     for each name: Len:8, Name/binary          (up to 32 names)
    record   Op:8, Slot:16, Gen:8, [IdLen:8, Id/binary]?, FieldCount:8, Fields
    field    Type:3, Idx:5, Value                       (one header byte)

`Op` is 0 add, 1 update, 2 remove. The entity id is present on an **add only**,
which is where the slot binding is established (ADR 0013, decision 4); update and
remove carry the slot and generation alone.

`Gen` advances every time a slot is rebound to a different entity. On this wire it
is redundant - the stream is ordered and reliable, and `frame_seq` already bounds
the reuse hazard - and it is carried anyway because the datagram plane (ADR 0012,
decision 12) cannot manage without it and must agree with this wire about which
entity holds a slot. One byte per record buys a client the ability to run both
carriers against one slot table instead of two.

`Kind` is 1 for a frame that holds a position in the zone's sequence and 2 for
one that does not. The text wire says the same thing by omitting `frame_seq`,
which a fixed-layout binary frame cannot do, so the distinction moves into the
header. It is load-bearing: the leave-removal frame a client gets on the way out
of a zone must be applied ungated, and encoding it as sequence 0 would have every
client past its first frame discard the one message that clears the ghosts.

The field header packs type and dictionary index into one byte rather than two.
Five bits of index caps a frame at 32 distinct field names, which is far past any
entity shape seen in practice, and the alternative cost a byte per field on every
record - about 15% of a steady-state delta frame.

Ids are sent as their text form rather than 16 raw bytes. It costs 20 bytes on an
add, and it buys the client an id byte-identical to the one the JSON wire and
`session.connected` give it, so a game can compare an entity to its own player
without knowing how the wire encoded it.
""".

-export([encode/1, decode/1]).
-export([field_type_tag/1]).

-export_type([frame/0, delta/0]).

-define(OP_ADD, 0).
-define(OP_UPDATE, 1).
-define(OP_REMOVE, 2).

%% Field value types. Three bits, so eight at most; six are used and the two
%% spare are deliberate headroom - adding a type later must not need a frame
%% version bump.
-define(T_F32, 0).
-define(T_I32, 1).
-define(T_TRUE, 2).
-define(T_FALSE, 3).
-define(T_STR, 4).
-define(T_NULL, 5).

-define(MAX_DICT, 32).

-define(KIND_SEQUENCED, 1).
-define(KIND_UNGATED, 2).

-type frame() :: #{
    kind := sequenced | ungated,
    zone := {integer(), integer()},
    frame_seq := non_neg_integer(),
    kf := boolean(),
    tick := non_neg_integer(),
    records := [delta()]
}.

%% Named `delta()` and not `record()`: the latter is a built-in type name and
%% shadowing it is a compile error, the same trap as clashing with a BIF name.
-type delta() :: #{
    op := add | update | remove,
    slot := non_neg_integer(),
    gen := 0..255,
    id => binary(),
    fields => #{binary() => term()}
}.

-doc """
Encodes one `world.tick` frame.

Returns `{error, dict_too_large}` rather than truncating when a frame's distinct
field names exceed 32. Silently dropping fields would be undetectable corruption
on the client; a refused frame is a server-side error someone can see.
""".
-spec encode(frame()) -> {ok, binary()} | {error, dict_too_large}.
encode(#{
    kind := Kind, zone := {ZX, ZY}, frame_seq := Seq, kf := Kf, tick := Tick, records := Recs
}) ->
    Names = dict_names(Recs),
    case length(Names) > ?MAX_DICT of
        true ->
            {error, dict_too_large};
        false ->
            Index = name_index(Names),
            Dict = <<<<(byte_size(N)):8, N/binary>> || N <- Names>>,
            Body = <<<<(encode_record(R, Index))/binary>> || R <- Recs>>,
            {ok, <<
                (kind_byte(Kind)):8,
                ZX:32/signed-little,
                ZY:32/signed-little,
                Seq:64/little,
                (bool_byte(Kf)):8,
                Tick:64/little,
                (length(Names)):8,
                Dict/binary,
                (length(Recs)):16/little,
                Body/binary
            >>}
    end.

-doc """
Decodes a frame produced by `encode/1`.

Total: a truncated, over-long or otherwise malformed binary returns
`{error, malformed}` rather than raising. This decodes bytes that will eventually
arrive on a datagram from an unauthenticated source, so a crash here would be a
remote denial of service; a decoder that only works on its own output is not a
decoder.
""".
-spec decode(binary()) -> {ok, frame()} | {error, malformed}.
decode(Bin) ->
    try
        <<KindByte:8, ZX:32/signed-little, ZY:32/signed-little, Seq:64/little, KfByte:8,
            Tick:64/little, DictLen:8,
            Rest0/binary>> =
            Bin,
        Kind = kind_atom(KindByte),
        {Names, Rest1} = decode_dict(DictLen, Rest0, []),
        <<RecCount:16/little, Rest2/binary>> = Rest1,
        NameTuple = list_to_tuple(Names),
        {Recs, <<>>} = decode_records(RecCount, Rest2, NameTuple, []),
        {ok, #{
            kind => Kind,
            zone => {ZX, ZY},
            frame_seq => Seq,
            kf => KfByte =/= 0,
            tick => Tick,
            records => Recs
        }}
    catch
        _:_ -> {error, malformed}
    end.

-doc "The wire type tag a value encodes as, exported so tests can pin the mapping.".
-spec field_type_tag(term()) -> 0..5.
field_type_tag(V) when is_float(V) -> ?T_F32;
field_type_tag(V) when is_integer(V) -> ?T_I32;
field_type_tag(true) -> ?T_TRUE;
field_type_tag(false) -> ?T_FALSE;
field_type_tag(V) when is_binary(V) -> ?T_STR;
field_type_tag(null) -> ?T_NULL.

%% --- Internal ---

%% Distinct field names in first-appearance order, so a frame's dictionary is
%% deterministic for a given record list and the encoder is testable by equality.
-spec dict_names([delta()]) -> [binary()].
dict_names(Recs) -> dict_names(Recs, [], []).

%% Threaded explicitly rather than via lists:append/1 over a comprehension: that
%% shape erases the element type on the way through, and the dictionary index is
%% only sound if the names are known to be binaries.
-spec dict_names([delta()], [binary()], [binary()]) -> [binary()].
dict_names([], _Seen, Acc) ->
    Acc;
dict_names([R | Rest], Seen, Acc) ->
    {Seen1, Acc1} = add_names(field_keys(R), Seen, Acc),
    dict_names(Rest, Seen1, Acc1).

-spec add_names([binary()], [binary()], [binary()]) -> {[binary()], [binary()]}.
add_names([], Seen, Acc) ->
    {Seen, Acc};
add_names([K | Rest], Seen, Acc) ->
    case lists:member(K, Seen) of
        true -> add_names(Rest, Seen, Acc);
        %% Appended rather than consed-and-reversed. The dictionary is capped at
        %% 32 names, so the quadratic cost is at most a few hundred cons cells per
        %% frame, and it keeps the list in first-appearance order without a
        %% lists:reverse/1 whose eqWAlizer overlay erases the element type.
        false -> add_names(Rest, [K | Seen], Acc ++ [K])
    end.

%% Pattern-matched rather than maps:get/3 with a default: the default widens the
%% map type and the key type goes with it, so the dictionary ends up untypeable
%% for the sake of one line of brevity.
-spec field_keys(delta()) -> [binary()].
field_keys(#{fields := Fields}) -> maps:keys(Fields);
field_keys(_) -> [].

%% Name -> dictionary index. Written out rather than via lists:enumerate/2, whose
%% return type erases the element type and leaves the index map untypeable.
-spec name_index([binary()]) -> #{binary() => non_neg_integer()}.
name_index(Names) -> name_index(Names, 0, #{}).

-spec name_index([binary()], non_neg_integer(), #{binary() => non_neg_integer()}) ->
    #{binary() => non_neg_integer()}.
name_index([], _I, Acc) -> Acc;
name_index([N | Rest], I, Acc) -> name_index(Rest, I + 1, Acc#{N => I}).

encode_record(#{op := Op, slot := Slot, gen := Gen} = R, Index) ->
    Fields = maps:get(fields, R, #{}),
    FieldBin = <<
        <<(encode_field(K, V, Index))/binary>>
     || K := V <- Fields
    >>,
    IdBin =
        case Op of
            add ->
                Id = maps:get(id, R),
                <<(byte_size(Id)):8, Id/binary>>;
            _ ->
                <<>>
        end,
    <<(op_byte(Op)):8, Slot:16/little, Gen:8, IdBin/binary, (map_size(Fields)):8, FieldBin/binary>>.

encode_field(Name, Value, Index) ->
    Idx = maps:get(Name, Index),
    Tag = field_type_tag(Value),
    <<Tag:3, Idx:5, (encode_value(Tag, Value))/binary>>.

encode_value(?T_F32, V) -> <<V:32/float-little>>;
encode_value(?T_I32, V) -> <<V:32/signed-little>>;
encode_value(?T_TRUE, _) -> <<>>;
encode_value(?T_FALSE, _) -> <<>>;
encode_value(?T_STR, V) -> <<(byte_size(V)):16/little, V/binary>>;
encode_value(?T_NULL, _) -> <<>>.

decode_dict(0, Rest, Acc) ->
    {lists:reverse(Acc), Rest};
decode_dict(N, <<Len:8, Name:Len/binary, Rest/binary>>, Acc) ->
    decode_dict(N - 1, Rest, [Name | Acc]).

decode_records(0, Rest, _Names, Acc) ->
    {lists:reverse(Acc), Rest};
decode_records(N, <<OpByte:8, Slot:16/little, Gen:8, Rest0/binary>>, Names, Acc) ->
    Op = op_atom(OpByte),
    {Base, Rest1} =
        case Op of
            add ->
                <<IdLen:8, Id:IdLen/binary, R/binary>> = Rest0,
                {#{op => add, slot => Slot, gen => Gen, id => Id}, R};
            _ ->
                {#{op => Op, slot => Slot, gen => Gen}, Rest0}
        end,
    <<FieldCount:8, Rest2/binary>> = Rest1,
    {Fields, Rest3} = decode_fields(FieldCount, Rest2, Names, #{}),
    Rec =
        case map_size(Fields) of
            0 -> Base;
            _ -> Base#{fields => Fields}
        end,
    decode_records(N - 1, Rest3, Names, [Rec | Acc]).

decode_fields(0, Rest, _Names, Acc) ->
    {Acc, Rest};
decode_fields(N, <<Tag:3, Idx:5, Rest0/binary>>, Names, Acc) ->
    Name = element(Idx + 1, Names),
    {Value, Rest1} = decode_value(Tag, Rest0),
    decode_fields(N - 1, Rest1, Names, Acc#{Name => Value}).

decode_value(?T_F32, <<V:32/float-little, R/binary>>) -> {V, R};
decode_value(?T_I32, <<V:32/signed-little, R/binary>>) -> {V, R};
decode_value(?T_TRUE, R) -> {true, R};
decode_value(?T_FALSE, R) -> {false, R};
decode_value(?T_STR, <<Len:16/little, V:Len/binary, R/binary>>) -> {V, R};
decode_value(?T_NULL, R) -> {null, R}.

kind_byte(sequenced) -> ?KIND_SEQUENCED;
kind_byte(ungated) -> ?KIND_UNGATED.

kind_atom(?KIND_SEQUENCED) -> sequenced;
kind_atom(?KIND_UNGATED) -> ungated.

op_byte(add) -> ?OP_ADD;
op_byte(update) -> ?OP_UPDATE;
op_byte(remove) -> ?OP_REMOVE.

op_atom(?OP_ADD) -> add;
op_atom(?OP_UPDATE) -> update;
op_atom(?OP_REMOVE) -> remove.

bool_byte(true) -> 1;
bool_byte(false) -> 0.
