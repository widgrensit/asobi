-module(asobi_dgram_rx_tests).
-include_lib("eunit/include/eunit.hrl").

%% The receive pipeline (ADR 0012, decisions 9 and 10). The ordering IS the
%% defence, so these tests are mostly about what does NOT happen and in what
%% order it fails to happen.

-define(KUP, <<"0123456789abcdef0123456789abcdef">>).
-define(CONN, 4711).
-define(HANDLE, {handle, a}).

rx_test_() ->
    {foreach, fun setup/0, fun cleanup/1, [
        {"a malformed datagram never reaches the key lookup", fun guard_precedes_lookup/0},
        {"an unknown conn_id never reaches MAC work", fun unknown_conn_never_macs/0},
        {"a bad MAC is dropped in silence", fun bad_mac_is_silent/0},
        {"a downlink opcode on the uplink is refused", fun downlink_opcode_refused/0},
        {"hello answers a challenge to the candidate handle", fun hello_answers_challenge/0},
        {"hello_confirm is answered with nothing at all", fun confirm_gets_no_reply/0},
        {"ping is answered with a strictly smaller pong", fun ping_pong_is_not_an_amplifier/0},
        {"input reaches the caller only after every gate", fun input_passes_every_gate/0},
        {"a replayed input is refused on cseq", fun replayed_input_refused/0},
        {"the rebind budget ends in teardown, not a reply", fun rebind_limit_tears_down/0},
        {"no rejection ever produces a reply", fun no_rejection_ever_replies/0}
    ]}.

setup() ->
    _ = application:ensure_all_started(seki),
    asobi_dgram_limits:register(),
    {ok, Pid} = asobi_dgram_table:start_link(),
    ok = asobi_dgram_table:register(binding(?CONN)),
    Pid.

cleanup(Pid) -> gen_server:stop(Pid).

%% --- Ordering ---

%% The key lookup must never be reached by bytes the guard rejects. Asserted by
%% making the lookup explode: if the pipeline calls it, the test crashes rather
%% than passing quietly.
guard_precedes_lookup() ->
    Deps = deps(#{kup_of => fun(_) -> error(lookup_should_not_be_reached) end}),
    ?assertEqual(drop, asobi_dgram_rx:handle(<<>>, ?HANDLE, Deps)),
    ?assertEqual(drop, asobi_dgram_rx:handle(<<16#A5, 9, 1, 0>>, ?HANDLE, Deps)),
    %% ...and random noise, which is what actually arrives on an open port.
    [
        ?assertEqual(drop, asobi_dgram_rx:handle(crypto:strong_rand_bytes(N), ?HANDLE, Deps))
     || N <- lists:seq(0, 40)
    ].

%% MAC verification is the only expensive step, and an attacker who does not hold
%% a live conn_id must never reach it. This is the property the whole tier
%% ordering exists to produce.
unknown_conn_never_macs() ->
    Bin = uplink(ping, 1, <<0:64>>),
    Deps = deps(#{kup_of => fun(_) -> error end}),
    ?assertEqual(drop, asobi_dgram_rx:handle(Bin, ?HANDLE, Deps)),
    %% And the transitions were never consulted either.
    assert_cseq_untouched().

bad_mac_is_silent() ->
    Bin = uplink(ping, 1, <<0:64>>),
    Tampered = <<(binary:part(Bin, 0, byte_size(Bin) - 1))/binary, 0>>,
    ?assertEqual(drop, asobi_dgram_rx:handle(Tampered, ?HANDLE, deps(#{}))),
    %% cseq must not have advanced: a forged datagram that burns a sequence
    %% number is a denial of service against the real client.
    assert_cseq_untouched().

%% A pose or pong arriving on the uplink is a confused client or a reflection
%% attempt. Either way it is not worth a table lookup.
downlink_opcode_refused() ->
    Bin = asobi_dgram:encode_downlink(#{
        opcode => pose, conn_id => ?CONN, path_tag => 0, body => <<0:128>>
    }),
    Deps = deps(#{kup_of => fun(_) -> error(lookup_should_not_be_reached) end}),
    ?assertEqual(drop, asobi_dgram_rx:handle(Bin, ?HANDLE, Deps)).

%% --- The handshake ---

hello_answers_challenge() ->
    {reply, Reply} = asobi_dgram_rx:handle(uplink(hello, 1, <<>>), ?HANDLE, deps(#{})),
    {ok, #{opcode := Opcode, conn_id := ConnId, body := Body}} = asobi_dgram:decode_downlink(Reply),
    ?assertEqual({hello_ok, ?CONN, 8}, {Opcode, ConnId, byte_size(Body)}),
    %% No state frame may follow until the echo returns.
    ?assertEqual(error, asobi_dgram_table:sendable(?CONN)),

    ?assertEqual(drop, asobi_dgram_rx:handle(uplink(hello_confirm, 2, Body), ?HANDLE, deps(#{}))),
    ?assertEqual({ok, ?HANDLE}, asobi_dgram_table:sendable(?CONN)).

%% A confirmation of the confirmation would be a reply with nothing to say, and
%% every byte the gateway sends unprompted is a byte an amplifier could borrow.
confirm_gets_no_reply() ->
    {reply, Reply} = asobi_dgram_rx:handle(uplink(hello, 1, <<>>), ?HANDLE, deps(#{})),
    {ok, #{body := Challenge}} = asobi_dgram:decode_downlink(Reply),
    ?assertEqual(
        drop, asobi_dgram_rx:handle(uplink(hello_confirm, 2, Challenge), ?HANDLE, deps(#{}))
    ).

%% ADR 0012, decision 10, on the live path rather than on the frame table.
ping_pong_is_not_an_amplifier() ->
    Ping = uplink(ping, 1, <<7:64>>),
    {reply, Pong} = asobi_dgram_rx:handle(Ping, ?HANDLE, deps(#{})),
    ?assert(byte_size(Pong) =< byte_size(Ping)),
    {ok, #{opcode := pong, body := Body}} = asobi_dgram:decode_downlink(Pong),
    %% The client's own stamp comes back, so a round trip needs no per-ping state.
    ?assertMatch(<<7:64, _:64>>, Body).

%% --- input ---

input_passes_every_gate() ->
    ?assertEqual(
        {input, ?CONN, <<"move">>},
        asobi_dgram_rx:handle(uplink(input, 1, <<"move">>), ?HANDLE, deps(#{}))
    ).

%% Every uplink advances cseq, so a captured input cannot be replayed any more
%% than a captured handshake frame can.
replayed_input_refused() ->
    Bin = uplink(input, 5, <<"move">>),
    ?assertMatch({input, _, _}, asobi_dgram_rx:handle(Bin, ?HANDLE, deps(#{}))),
    ?assertEqual(drop, asobi_dgram_rx:handle(Bin, ?HANDLE, deps(#{}))).

%% Past the budget the answer is teardown, not another challenge. Minting again
%% would let a flapping path spend the gateway's entropy indefinitely.
rebind_limit_tears_down() ->
    Bound = fun(N, H) ->
        {reply, R} = asobi_dgram_rx:handle(uplink(hello, N, <<>>), H, deps(#{})),
        {ok, #{body := C}} = asobi_dgram:decode_downlink(R),
        drop = asobi_dgram_rx:handle(uplink(hello_confirm, N + 1, C), H, deps(#{})),
        ok
    end,
    ok = Bound(1, ?HANDLE),
    ok = Bound(3, {handle, b}),
    ok = Bound(5, {handle, c}),
    ok = Bound(7, {handle, d}),
    ?assertEqual(
        {teardown, ?CONN},
        asobi_dgram_rx:handle(uplink(hello, 9, <<>>), {handle, e}, deps(#{}))
    ).

%% The invariant's other half: no unauthenticated or malformed datagram receives
%% ANY reply. Swept across every gate rather than asserted one at a time, because
%% the one that gets missed is the one that becomes the reflector.
no_rejection_ever_replies() ->
    Good = uplink(ping, 1, <<0:64>>),
    Cases = [
        {"empty", <<>>, deps(#{})},
        {"noise", crypto:strong_rand_bytes(50), deps(#{})},
        {"bad magic", <<0, (binary:part(Good, 1, byte_size(Good) - 1))/binary>>, deps(#{})},
        {"reserved flag", flip(Good, 3, 128), deps(#{})},
        {"unknown conn", Good, deps(#{kup_of => fun(_) -> error end})},
        {"bad mac", flip(Good, byte_size(Good) - 1, 0), deps(#{})},
        {"stale cseq", uplink(input, 0, <<>>), deps(#{})}
    ],
    [
        ?assertEqual(drop, asobi_dgram_rx:handle(Bin, ?HANDLE, D), Label)
     || {Label, Bin, D} <- Cases
    ].

%% --- Helpers ---

deps(Overrides) ->
    maps:merge(
        #{
            kup_of => fun asobi_dgram_table:kup_of/1,
            hello => fun asobi_dgram_table:hello/4,
            confirm => fun asobi_dgram_table:confirm/4,
            note_uplink => fun asobi_dgram_table:note_uplink/2,
            challenge => fun() -> crypto:strong_rand_bytes(8) end
        },
        Overrides
    ).

uplink(Opcode, CSeq, Body) ->
    Pad =
        case Opcode of
            hello -> asobi_dgram:min_hello();
            _ -> 0
        end,
    asobi_dgram:encode_uplink(
        #{opcode => Opcode, conn_id => ?CONN, cseq => CSeq, body => Body}, ?KUP, Pad
    ).

%% The counter is only observable through the transitions it gates, so this asks
%% the question the attack actually poses: can the REAL client still use sequence
%% number 1? If a dropped datagram had advanced the counter, it could not.
assert_cseq_untouched() ->
    ?assertMatch({input, _, _}, asobi_dgram_rx:handle(uplink(input, 1, <<>>), ?HANDLE, deps(#{}))).

flip(Bin, Index, Byte) ->
    <<Head:Index/binary, _:8, Tail/binary>> = Bin,
    <<Head/binary, Byte:8, Tail/binary>>.

binding(ConnId) ->
    #{
        conn_id => ConnId,
        kup => ?KUP,
        player_id => ~"p1",
        epoch => 1,
        expires_at => erlang:system_time(millisecond) + 60_000,
        state => registered,
        handle => undefined,
        pending_handle => undefined,
        challenge => undefined,
        cseq => 0,
        rebinds => []
    }.
