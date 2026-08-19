-module(asobi_dgram_tests).
-include_lib("eunit/include/eunit.hrl").

%% The datagram-plane codec (ADR 0012 as re-accepted by ADR 0013).

-define(KUP, <<"0123456789abcdef0123456789abcdef">>).
-define(CONN, 16#DEADBEEF).

%% --- The parse guard ---

%% Every rejection here happens before a single byte of MAC work, which is the
%% ordering the whole defence rests on (ADR 0012, decision 9). A guard that
%% accepted any of these would hand an unauthenticated flood a crypto budget.
parse_guard_rejects_before_any_mac_work_test() ->
    Good = uplink(ping, 1, <<0:64>>),
    Cases = [
        {"empty", <<>>},
        {"one byte", <<16#A5>>},
        {"wrong magic", flip(Good, 0, 16#FF)},
        {"wrong version", flip(Good, 1, 9)},
        {"unknown opcode", flip(Good, 2, 99)},
        {"a reserved flag bit", flip(Good, 3, 1)},
        {"prefix only", binary:part(Good, 0, 16)}
    ],
    [?assertMatch({error, _}, asobi_dgram:peek(B), Label) || {Label, B} <- Cases],
    ?assertMatch({ok, #{opcode := ping}}, asobi_dgram:peek(Good)).

%% A reserved bit is a DROP, not a mask-and-continue. Masking would let a flag
%% defined later be silently ignored by an old gateway, which is how a protocol
%% ends up with two incompatible readings of the same byte.
reserved_flags_are_a_drop_not_a_mask_test() ->
    Good = uplink(ping, 1, <<0:64>>),
    [
        ?assertEqual({error, reserved_flag_set}, asobi_dgram:peek(flip(Good, 3, 1 bsl Bit)))
     || Bit <- lists:seq(0, 7)
    ].

%% Random noise must never parse, and must never raise: this runs on every packet
%% that reaches the port, from anyone.
peek_is_total_test() ->
    [
        ?assertMatch({error, _}, asobi_dgram:peek(crypto:strong_rand_bytes(N)))
     || N <- lists:seq(0, 80)
    ].

%% `hello` is padded by the client so no reply can exceed its request. The gateway
%% drops a short one BEFORE MAC work, so the padding is an anti-amplification
%% control rather than framing, and the guard is where it has to be enforced.
short_hello_is_refused_by_the_guard_test() ->
    Unpadded = asobi_dgram:encode_uplink(
        #{opcode => hello, conn_id => ?CONN, cseq => 1}, ?KUP, 0
    ),
    ?assert(byte_size(Unpadded) < asobi_dgram:min_hello()),
    ?assertEqual({error, too_short}, asobi_dgram:peek(Unpadded)),
    Padded = uplink(hello, 1, <<>>),
    ?assertMatch({ok, #{opcode := hello}}, asobi_dgram:peek(Padded)).

%% --- Authentication ---

mac_round_trips_and_rejects_every_tampered_byte_test() ->
    Bin = uplink(input, 7, <<"move">>),
    ?assertEqual(ok, asobi_dgram:verify(Bin, ?KUP)),
    ?assertEqual({error, bad_mac}, asobi_dgram:verify(Bin, <<"a-different-key-................">>)),
    %% Every byte is covered, including conn_id, cseq and the opcode - which is
    %% what stops a captured frame being replayed under another identity.
    [
        ?assertEqual(
            {error, bad_mac},
            asobi_dgram:verify(flip(Bin, I, (binary:at(Bin, I) + 1) rem 256), ?KUP),
            I
        )
     || I <- lists:seq(0, byte_size(Bin) - 1)
    ].

uplink_round_trips_test() ->
    Bin = uplink(input, 4711, <<"payload bytes">>),
    ?assertEqual(ok, asobi_dgram:verify(Bin, ?KUP)),
    ?assertEqual(
        {ok, #{opcode => input, conn_id => ?CONN, cseq => 4711, body => <<"payload bytes">>}},
        asobi_dgram:decode_uplink(Bin)
    ).

%% The uplink has no return-path handle to carry, so a non-zero path_tag is either
%% a confused client or an attempt to smuggle one. Neither is worth parsing.
uplink_with_a_path_tag_is_refused_test() ->
    Bin = uplink(ping, 1, <<0:64>>),
    Tagged = binary:part(Bin, 0, 8),
    Rest = binary:part(Bin, 16, byte_size(Bin) - 16),
    ?assertEqual(
        {error, path_tag_not_zero},
        asobi_dgram:decode_uplink(<<Tagged/binary, 1:64/little, Rest/binary>>)
    ).

%% --- The amplification invariant ---

%% ADR 0012, decision 10, as an assertion over the frame table rather than as
%% prose: every server reply is no larger than the request that caused it, and no
%% unauthenticated or malformed datagram receives any reply at all.
%%
%% This is the property that stops the port being a reflector. It is asserted here
%% because prose does not fail a build.
every_reply_is_no_larger_than_its_request_test() ->
    [
        case Reply of
            none ->
                ok;
            _ ->
                Request = smallest_request(Op),
                Answer = smallest_reply(Reply),
                ?assert(
                    byte_size(Answer) =< byte_size(Request),
                    {Op, byte_size(Request), Reply, byte_size(Answer)}
                )
        end
     || {Op, Reply} <- reply_table()
    ].

%% Every uplink opcode must appear in the table above, so adding one forces an
%% explicit decision about what it answers rather than defaulting to silence and
%% being discovered later by an amplification report.
the_reply_table_covers_every_uplink_opcode_test() ->
    ?assertEqual(
        lists:sort([hello, hello_confirm, bye, ping, input]),
        lists:sort([Op || {Op, _} <- reply_table()])
    ).

%% --- pose ---

pose_round_trips_through_the_two_element_iovec_test() ->
    Records = [
        #{slot => 1, gen => 0, rmask => 2#0011, values => [100, -200]},
        #{slot => 65535, gen => 255, rmask => 2#1111, values => [1, 2, 3, 4]}
    ],
    [Body] = asobi_dgram:pack_pose(42, 7, {3, -2}, 2#1111, 9, Records),
    Prefix = asobi_dgram:prefix(#{opcode => pose, conn_id => ?CONN, path_tag => 16#0102030405060708}),
    {ok, Decoded} = asobi_dgram:decode_downlink(iolist_to_binary([Prefix, Body])),
    ?assertMatch(#{opcode := pose, conn_id := ?CONN, path_tag := 16#0102030405060708}, Decoded),
    <<Tick:32/little, BSeq:32/little, ZX:16/signed-little, ZY:16/signed-little, FieldMask:8,
        Count:8, Epoch:16/little, Rest/binary>> = maps:get(body, Decoded),
    ?assertEqual({42, 7, 3, -2, 2#1111, 2, 9}, {Tick, BSeq, ZX, ZY, FieldMask, Count, Epoch}),
    <<1:16/little, 0:8, 2#0011:8, 100:16/signed-little, -200:16/signed-little, 65535:16/little,
        255:8, 2#1111:8, 1:16/signed-little, 2:16/signed-little, 3:16/signed-little,
        4:16/signed-little>> = Rest.

%% There is no fragmentation on this plane. A tick too big for one datagram
%% becomes SEVERAL independent ones - same tick, consecutive bseq, disjoint
%% records, each applicable on its own - so there is no reassembly buffer and
%% therefore no memory-exhaustion surface.
an_oversized_tick_splits_into_independent_datagrams_test() ->
    Records = [
        #{slot => I, gen => 0, rmask => 2#1111, values => [I, I, 0, 0]}
     || I <- lists:seq(1, 400)
    ],
    Bodies = asobi_dgram:pack_pose(1, 0, {0, 0}, 2#1111, 0, Records),
    ?assert(length(Bodies) > 1),

    %% Every datagram fits the budget, prefix included.
    [
        ?assert(16 + byte_size(B) =< asobi_dgram:max_datagram())
     || B <- Bodies
    ],

    %% bseq advances by exactly one per datagram, because a client uses it as the
    %% per-zone loss metric and a gap in it must mean loss rather than packing.
    ?assertEqual(
        lists:seq(0, length(Bodies) - 1),
        [
            begin
                <<_:32/little, S:32/little, _/binary>> = B,
                S
            end
         || B <- Bodies
        ]
    ),

    %% And the records are disjoint and complete: nothing dropped, nothing sent
    %% twice, which is what "each individually applicable" has to mean.
    Counts = [
        begin
            <<_:104, C:8, _/binary>> = B,
            C
        end
     || B <- Bodies
    ],
    ?assertEqual(400, lists:sum(Counts)).

%% A record carries only the fields its rmask names, in canonical bit order, so a
%% zone sending x,y costs half what one sending x,y,vx,vy costs. That ratio is
%% what the whole 1100-byte budget was sized against.
record_size_follows_the_field_mask_test() ->
    Two = [#{slot => I, gen => 0, rmask => 2#0011, values => [0, 0]} || I <- lists:seq(1, 200)],
    Four = [
        #{slot => I, gen => 0, rmask => 2#1111, values => [0, 0, 0, 0]}
     || I <- lists:seq(1, 200)
    ],
    ?assertEqual(2, length(asobi_dgram:pack_pose(1, 0, {0, 0}, 2#0011, 0, Two))),
    ?assertEqual(3, length(asobi_dgram:pack_pose(1, 0, {0, 0}, 2#1111, 0, Four))).

%% `count` is one byte, so a datagram carries at most 255 records however much
%% room the budget leaves. A packer that ignored that would write a count that
%% wrapped and hand every client a truncated frame it could not detect.
count_is_capped_at_a_byte_test() ->
    Records = [#{slot => I, gen => 0, rmask => 0, values => []} || I <- lists:seq(1, 300)],
    Bodies = asobi_dgram:pack_pose(1, 0, {0, 0}, 0, 0, Records),
    Counts = [
        begin
            <<_:104, C:8, _/binary>> = B,
            C
        end
     || B <- Bodies
    ],
    ?assert(lists:all(fun(C) -> C =< 255 end, Counts)),
    ?assertEqual(300, lists:sum(Counts)).

%% --- Helpers ---

%% The protocol's reply table, as data rather than as prose. `none` means the
%% gateway answers nothing at all, which is the other half of the invariant: no
%% unauthenticated or malformed datagram receives any reply, and every rejection
%% is a silent drop plus a counter.
reply_table() ->
    [
        {hello, hello_ok},
        {hello_confirm, none},
        {ping, pong},
        {bye, none},
        {input, none}
    ].

%% The smallest datagram a client could legitimately send for this opcode. The
%% invariant has to hold against the SMALLEST request, not a typical one.
smallest_request(hello) -> uplink(hello, 1, <<>>);
smallest_request(hello_confirm) -> uplink(hello_confirm, 1, <<0:64>>);
smallest_request(ping) -> uplink(ping, 1, <<0:64>>);
smallest_request(bye) -> uplink(bye, 1, <<>>);
smallest_request(input) -> uplink(input, 1, <<>>).

%% ...and the LARGEST reply the gateway could send back, for the same reason.
smallest_reply(hello_ok) -> downlink(hello_ok, <<0:64>>);
smallest_reply(pong) -> downlink(pong, <<0:64, 0:64>>).

uplink(Opcode, CSeq, Body) ->
    Pad =
        case Opcode of
            hello -> asobi_dgram:min_hello();
            _ -> 0
        end,
    asobi_dgram:encode_uplink(
        #{opcode => Opcode, conn_id => ?CONN, cseq => CSeq, body => Body}, ?KUP, Pad
    ).

downlink(Opcode, Body) ->
    asobi_dgram:encode_downlink(#{
        opcode => Opcode, conn_id => ?CONN, path_tag => 16#AABBCCDD, body => Body
    }).

flip(Bin, Index, Byte) ->
    <<Head:Index/binary, _:8, Tail/binary>> = Bin,
    <<Head/binary, Byte:8, Tail/binary>>.
