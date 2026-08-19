-module(asobi_dgram).
-moduledoc """
The datagram-plane codec (ADR 0012, superseded and re-accepted by ADR 0013).

Pure: no processes, no sockets, no stored keys. Every hostile byte the gateway
will ever see is parsed here, so this module is where the parse guard and the MAC
check live and it is unit-testable without a network.

## What travels here, and what never does

Down, `pose`: absolute per-record transform state, self-contained per record and
harmless to lose because the next one supersedes it. Up, `input`: the frozen
`world.input` payload bytes on a different carrier. Six control frames either
way. **Nothing with authority** - auth, inventory, economy, chat, match results
and every frame in the JSON corpus stay on the TLS WebSocket, and `world.tick`
above all, which is an op-delta against a baseline that advances on send and so
corrupts permanently under loss.

## The ordering is the guarantee

`peek/1` is pure arithmetic over the first bytes and costs nothing. `verify/2` is
the only expensive step and is reachable only by a datagram that already passed
the guard, fitted the global budget, carried a live `conn_id` and fitted that
connection's own budget (ADR 0012, decision 9). Calling `verify/2` on unfiltered
input throws that ordering away.

## Layout

    prefix(16)  Magic:8=0xA5, Version:8, Opcode:8, Flags:8,
                ConnId:32, PathTag:64
    uplink      prefix, CSeq:64, <body>, Mac:16
    downlink    prefix, <body>                      (no MAC - see below)

    pose body   Tick:32, BSeq:32, ZoneX:16/signed, ZoneY:16/signed,
                FieldMask:8, Count:8, Epoch:16, Records
    record      Slot:16, Gen:8, RMask:8, [Value:16/signed]*

`PathTag` MUST be zero on every uplink. `Flags` is entirely reserved and MUST be
zero; a set bit is a drop, which is what keeps a future flag from being silently
ignored by an old gateway.

Every multi-byte value is **little-endian**, which departs from ADR 0012's
`uint32be` prose and does so deliberately. The same six SDK decoders read this and
the WebSocket binary wire, that wire is little-endian because Godot's byte readers
have no big-endian counterpart, and one carrier in each byte order is a trap
nobody would thank us for. Recorded as an amendment rather than a silent fix.

## `conn_id` is the identity; the observed address is a return-path handle

`conn_id` is cleartext at bytes 4-7 of every datagram and is the sole demux key.
It is **not a secret**: it is visible to any on-path observer and will end up in
logs and metric labels. Uplink routing never consults the observed source address,
because any NAT, proxy or load balancer may rewrite it and a kernel-assigned
mapping is expirable and reusable.

## The downlink carries no MAC and no encryption

Stated plainly because it is a real reduction: *the datagram plane provides
off-path forgery resistance and no confidentiality or on-path integrity.* A
shared-key MAC would not be a control at all, since every subscriber holds the key
and could forge to every other; a per-client-key MAC measured at +46% CPU per
subscriber and destroys the shareable wire bytes, which is the one reversal of
ADR 0001 this design refuses. An attacker needs `conn_id` AND `path_tag` AND
delivery to the victim's current handle, and with all three can make one client's
*render* wrong for at most one pose interval.
""".

-export([peek/1, verify/2, mac/2]).
-export([decode_uplink/1, encode_uplink/3]).
-export([decode_downlink/1, encode_downlink/1]).
-export([prefix/1, pack_pose/6]).
-export([max_datagram/0, min_hello/0]).

-export_type([prefix/0, uplink/0, downlink/0, pose_record/0, opcode/0]).

-define(MAGIC, 16#A5).
-define(VERSION, 1).

%% Control frames, then the two payload frames. ADR 0012, decision 1.
-define(OP_HELLO, 1).
-define(OP_HELLO_OK, 2).
-define(OP_HELLO_CONFIRM, 3).
-define(OP_BYE, 4).
-define(OP_PING, 5).
-define(OP_PONG, 6).
-define(OP_POSE, 7).
-define(OP_INPUT, 8).

-define(PREFIX_BYTES, 16).
-define(MAC_BYTES, 16).
-define(CSEQ_BYTES, 8).

%% Provisional until an operator measures a real path MTU, per ADR 0012's own
%% consequences. Nothing may infer it at build time.
-define(MAX_DATAGRAM, 1100).

%% `hello` is padded by the client so that no reply can exceed its request
%% (ADR 0012, decision 10). The gateway drops a short one BEFORE any MAC work,
%% which is the point: the padding is an anti-amplification control, not framing.
-define(MIN_HELLO, 64).

-define(POSE_HEADER_BYTES, 16).
-define(RECORD_HEADER_BYTES, 4).

-type opcode() ::
    hello | hello_ok | hello_confirm | bye | ping | pong | pose | input.

-type prefix() :: #{
    opcode := opcode(),
    conn_id := non_neg_integer(),
    path_tag := non_neg_integer()
}.

-type uplink() :: #{
    opcode := opcode(),
    conn_id := non_neg_integer(),
    cseq := non_neg_integer(),
    body := binary()
}.

-type pose_record() :: #{
    slot := 0..65535,
    gen := 0..255,
    rmask := 0..255,
    values := [integer()]
}.

-type downlink() :: #{
    opcode := opcode(),
    conn_id := non_neg_integer(),
    path_tag := non_neg_integer(),
    body := binary()
}.

-doc "The 1100-byte datagram budget. There is no fragmentation on this plane.".
-spec max_datagram() -> pos_integer().
max_datagram() -> ?MAX_DATAGRAM.

-doc "The length a `hello` must reach before the gateway will do MAC work on it.".
-spec min_hello() -> pos_integer().
min_hello() -> ?MIN_HELLO.

-doc """
The parse guard, and nothing else.

Magic, version, a known opcode, all-zero reserved flags, and the minimum length
for the opcode. Pure arithmetic over a fixed prefix, so it is safe to run on
every datagram that arrives including a flood, and it is the only thing that runs
before the volumetric limiter.

Deliberately does NOT verify the MAC or consult any table: that ordering is the
whole defence (ADR 0012, decision 9).
""".
-spec peek(binary()) -> {ok, prefix()} | {error, atom()}.
peek(<<?MAGIC:8, ?VERSION:8, Op:8, Flags:8, ConnId:32/little, PathTag:64/little, _/binary>> = Bin) ->
    case Flags of
        0 ->
            case opcode(Op) of
                {ok, Opcode} ->
                    case byte_size(Bin) >= min_bytes(Opcode) of
                        true ->
                            {ok, #{opcode => Opcode, conn_id => ConnId, path_tag => PathTag}};
                        false ->
                            {error, too_short}
                    end;
                error ->
                    {error, unknown_opcode}
            end;
        _ ->
            %% A reserved bit is a drop rather than a mask-and-continue, so a
            %% flag defined later cannot be silently ignored by an old gateway.
            {error, reserved_flag_set}
    end;
peek(_) ->
    {error, malformed}.

-doc """
Verifies an uplink datagram's MAC under this connection's `KUp`.

Constant-time. The MAC covers every byte before it, so `conn_id`, `cseq`, the
opcode and the body are all authenticated - which is what stops a captured
`hello_confirm` being replayed from another handle, given `cseq` strictly
advances.
""".
-spec verify(binary(), binary()) -> ok | {error, atom()}.
verify(Bin, KUp) when byte_size(Bin) > ?MAC_BYTES ->
    Split = byte_size(Bin) - ?MAC_BYTES,
    <<Signed:Split/binary, Given:?MAC_BYTES/binary>> = Bin,
    case crypto:hash_equals(mac(Signed, KUp), Given) of
        true -> ok;
        false -> {error, bad_mac}
    end;
verify(_Bin, _KUp) ->
    {error, too_short}.

-doc "HMAC-SHA256 truncated to 128 bits, the tag every uplink datagram carries.".
-spec mac(binary(), binary()) -> binary().
mac(Signed, KUp) ->
    <<Tag:?MAC_BYTES/binary, _/binary>> = crypto:mac(hmac, sha256, KUp, Signed),
    Tag.

-doc """
Decodes a verified uplink datagram.

Call `peek/1` and `verify/2` first. This assumes both have passed and does no
authentication of its own.
""".
-spec decode_uplink(binary()) -> {ok, uplink()} | {error, atom()}.
decode_uplink(Bin) ->
    case peek(Bin) of
        {ok, #{opcode := Opcode, conn_id := ConnId, path_tag := PathTag}} ->
            case PathTag of
                0 ->
                    Len = byte_size(Bin) - ?PREFIX_BYTES - ?CSEQ_BYTES - ?MAC_BYTES,
                    case Len >= 0 of
                        true ->
                            <<_:?PREFIX_BYTES/binary, CSeq:64/little, Body:Len/binary,
                                _Mac:?MAC_BYTES/binary>> = Bin,
                            {ok, #{
                                opcode => Opcode,
                                conn_id => ConnId,
                                cseq => CSeq,
                                body => Body
                            }};
                        false ->
                            {error, too_short}
                    end;
                _ ->
                    %% The uplink has no return-path handle to carry, so a
                    %% non-zero path_tag is either a confused client or an
                    %% attempt to smuggle one. Neither is worth parsing.
                    {error, path_tag_not_zero}
            end;
        {error, _} = Err ->
            Err
    end.

-doc "Builds an uplink datagram, MAC included. Used by the SDKs and by tests.".
-spec encode_uplink(
    #{
        opcode := opcode(),
        conn_id := non_neg_integer(),
        cseq := non_neg_integer(),
        body => binary()
    },
    binary(),
    non_neg_integer()
) -> binary().
encode_uplink(#{opcode := Opcode, conn_id := ConnId, cseq := CSeq} = Frame, KUp, PadTo) ->
    %% The padding goes INSIDE the MAC's coverage, not after it. Appended after
    %% the tag it would both break verification - the last 16 bytes would be
    %% padding rather than the tag - and let an attacker strip it back down to
    %% recover the amplification ratio the padding exists to remove.
    Body = pad(maps:get(body, Frame, <<>>), PadTo - ?PREFIX_BYTES - ?CSEQ_BYTES - ?MAC_BYTES),
    Signed =
        <<?MAGIC:8, ?VERSION:8, (op_byte(Opcode)):8, 0:8, ConnId:32/little, 0:64, CSeq:64/little,
            Body/binary>>,
    <<Signed/binary, (mac(Signed, KUp))/binary>>.

-doc """
Decodes a downlink datagram.

Unauthenticated by construction - there is no MAC to check. A client's defence is
that `conn_id` and `path_tag` both have to be right and the packet has to reach
its current handle, and that a forged pose can only make its own render wrong for
one interval.
""".
-spec decode_downlink(binary()) -> {ok, downlink()} | {error, atom()}.
decode_downlink(Bin) ->
    case peek(Bin) of
        {ok, #{opcode := Opcode, conn_id := ConnId, path_tag := PathTag}} ->
            <<_:?PREFIX_BYTES/binary, Body/binary>> = Bin,
            {ok, #{opcode => Opcode, conn_id => ConnId, path_tag => PathTag, body => Body}};
        {error, _} = Err ->
            Err
    end.

-doc "Builds a downlink datagram. No MAC: see the module doc.".
-spec encode_downlink(#{
    opcode := opcode(),
    conn_id := non_neg_integer(),
    path_tag := non_neg_integer(),
    body => binary()
}) -> binary().
encode_downlink(#{opcode := Opcode, conn_id := ConnId, path_tag := PathTag} = Frame) ->
    Body = maps:get(body, Frame, <<>>),
    <<(prefix(#{opcode => Opcode, conn_id => ConnId, path_tag => PathTag}))/binary, Body/binary>>.

-doc """
The 16-byte per-subscriber prefix, alone.

Separate from the body because that is what preserves ADR 0001 through the
fan-out: the sender writes `[Prefix, SharedBody]` as a two-element iovec, so the
body is referenced once and never copied per subscriber. A function that returned
one joined binary would quietly undo the encode-once discipline.
""".
-spec prefix(#{
    opcode := opcode(), conn_id := non_neg_integer(), path_tag := non_neg_integer()
}) -> binary().
prefix(#{opcode := Opcode, conn_id := ConnId, path_tag := PathTag}) ->
    <<?MAGIC:8, ?VERSION:8, (op_byte(Opcode)):8, 0:8, ConnId:32/little, PathTag:64/little>>.

-doc """
Splits a tick's records into datagram-sized shared bodies.

There is no fragmentation on this plane (ADR 0012, decision 2): when a tick's
record set exceeds the budget it becomes several independent datagrams with the
same `tick`, consecutive `bseq` and disjoint record subsets, each individually
applicable. No reassembly buffer, no timer, no partial-frame state - and so no
memory-exhaustion surface, which is the point rather than a side effect.

Returns the bodies in order; the caller assigns them to `bseq`, `bseq + 1`, and
so on. A record too large for an empty datagram is impossible by arithmetic: the
budget is 1100 and the largest record is 20 bytes.
""".
-spec pack_pose(
    non_neg_integer(),
    non_neg_integer(),
    {integer(), integer()},
    0..255,
    0..65535,
    [pose_record()]
) -> [binary()].
pack_pose(Tick, BSeq, Zone, FieldMask, Epoch, Records) ->
    Budget = ?MAX_DATAGRAM - ?PREFIX_BYTES - ?POSE_HEADER_BYTES,
    Chunks = chunk(Records, Budget, [], 0, []),
    build_bodies(Tick, BSeq, Zone, FieldMask, Epoch, Chunks, []).

%% --- Internal ---

build_bodies(_Tick, _BSeq, _Zone, _FieldMask, _Epoch, [], Acc) ->
    lists:reverse(Acc);
build_bodies(Tick, BSeq, {ZX, ZY} = Zone, FieldMask, Epoch, [Chunk | Rest], Acc) ->
    Encoded = <<<<(encode_record(R))/binary>> || R <- Chunk>>,
    Body =
        <<Tick:32/little, BSeq:32/little, ZX:16/signed-little, ZY:16/signed-little, FieldMask:8,
            (length(Chunk)):8, Epoch:16/little, Encoded/binary>>,
    build_bodies(Tick, BSeq + 1, Zone, FieldMask, Epoch, Rest, [Body | Acc]).

%% `count` is one byte, so a datagram carries at most 255 records however much
%% room the budget leaves. Built head-first rather than accumulated and reversed:
%% lists:reverse/1's eqWAlizer overlay erases the element type.
chunk([], _Budget, [], _Used, Acc) ->
    lists:reverse(Acc);
chunk([], _Budget, Current, _Used, Acc) ->
    lists:reverse([lists:reverse(Current) | Acc]);
chunk([R | Rest], Budget, Current, Used, Acc) ->
    Size = record_bytes(R),
    case Used + Size > Budget orelse length(Current) >= 255 of
        true when Current =/= [] ->
            chunk([R | Rest], Budget, [], 0, [lists:reverse(Current) | Acc]);
        _ ->
            chunk(Rest, Budget, [R | Current], Used + Size, Acc)
    end.

record_bytes(#{rmask := RMask}) ->
    ?RECORD_HEADER_BYTES + 2 * popcount(RMask).

encode_record(#{slot := Slot, gen := Gen, rmask := RMask, values := Values}) ->
    Fields = <<<<V:16/signed-little>> || V <- Values>>,
    <<Slot:16/little, Gen:8, RMask:8, Fields/binary>>.

popcount(Byte) -> popcount(Byte, 0).

popcount(0, N) -> N;
popcount(B, N) -> popcount(B bsr 1, N + (B band 1)).

pad(Bin, PadTo) when PadTo =< 0; byte_size(Bin) >= PadTo ->
    Bin;
pad(Bin, PadTo) ->
    <<Bin/binary, 0:((PadTo - byte_size(Bin)) * 8)>>.

%% Uplinks carry a cseq and a MAC; downlinks carry neither. `hello` alone has a
%% padded floor, and it is a security control rather than framing.
min_bytes(hello) -> ?MIN_HELLO;
min_bytes(hello_confirm) -> ?PREFIX_BYTES + ?CSEQ_BYTES + 8 + ?MAC_BYTES;
min_bytes(ping) -> ?PREFIX_BYTES + ?CSEQ_BYTES + 8 + ?MAC_BYTES;
min_bytes(bye) -> ?PREFIX_BYTES + ?CSEQ_BYTES + ?MAC_BYTES;
min_bytes(input) -> ?PREFIX_BYTES + ?CSEQ_BYTES + ?MAC_BYTES;
min_bytes(hello_ok) -> ?PREFIX_BYTES + 8;
min_bytes(pong) -> ?PREFIX_BYTES + 16;
min_bytes(pose) -> ?PREFIX_BYTES + ?POSE_HEADER_BYTES.

opcode(?OP_HELLO) -> {ok, hello};
opcode(?OP_HELLO_OK) -> {ok, hello_ok};
opcode(?OP_HELLO_CONFIRM) -> {ok, hello_confirm};
opcode(?OP_BYE) -> {ok, bye};
opcode(?OP_PING) -> {ok, ping};
opcode(?OP_PONG) -> {ok, pong};
opcode(?OP_POSE) -> {ok, pose};
opcode(?OP_INPUT) -> {ok, input};
opcode(_) -> error.

op_byte(hello) -> ?OP_HELLO;
op_byte(hello_ok) -> ?OP_HELLO_OK;
op_byte(hello_confirm) -> ?OP_HELLO_CONFIRM;
op_byte(bye) -> ?OP_BYE;
op_byte(ping) -> ?OP_PING;
op_byte(pong) -> ?OP_PONG;
op_byte(pose) -> ?OP_POSE;
op_byte(input) -> ?OP_INPUT.
