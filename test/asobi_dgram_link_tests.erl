-module(asobi_dgram_link_tests).
-include_lib("eunit/include/eunit.hrl").

%% The engine-to-gateway link's framing and auth. The gateway is the untrusted end
%% of this link, so the engine's decoder is a trust boundary even though both ends
%% are ours - which is what most of these tests are about.

-define(SECRET, <<"a-shared-secret-from-the-config">>).

%% --- Framing ---

register_round_trips_test() ->
    Msg =
        {register, #{
            conn_id => 16#DEADBEEF,
            kup => crypto:strong_rand_bytes(32),
            player_id => ~"01a0115f-547e-714f-829f-408c855ab77b",
            epoch => 7,
            expires_at => 1_785_312_000_000
        }},
    ?assertEqual({ok, Msg}, roundtrip(Msg)).

unregister_round_trips_test() ->
    ?assertEqual({ok, {unregister, 42}}, roundtrip({unregister, 42})).

input_round_trips_test() ->
    ?assertEqual({ok, {input, 1, <<"move payload">>}}, roundtrip({input, 1, <<"move payload">>})).

%% An input body is a game's own move payload and may legitimately be empty, so
%% the decoder must not treat "no bytes left" as a truncated frame.
an_empty_input_body_is_legitimate_test() ->
    ?assertEqual({ok, {input, 1, <<>>}}, roundtrip({input, 1, <<>>})).

%% The length prefix is what lets a reader know when it has a whole frame. A
%% decoder that guessed from content would desynchronise permanently on the first
%% input body that happened to look like a header.
every_frame_declares_its_own_length_test() ->
    Encoded = asobi_dgram_link:encode({unregister, 42}),
    <<Len:32/little, Payload/binary>> = Encoded,
    ?assertEqual(Len, byte_size(Payload)).

%% --- Hostile input ---

%% Total, and never term_to_binary. A decoder calling binary_to_term/1 on socket
%% bytes is the single most exploitable thing an Erlang program can do, and it
%% would be exploitable from the gateway inward exactly when the gateway is the
%% process most likely to be compromised.
decode_is_total_test() ->
    Cases = [
        {"empty", <<>>},
        {"unknown tag", <<99, 0, 0, 0, 0>>},
        {"truncated register", <<1, 0, 0, 0>>},
        {"register with a lying key length", <<1, 0:32, 200, 0, 0>>},
        {"truncated unregister", <<2, 0, 0>>},
        {"trailing junk on unregister", <<2, 0:32, 0, 0>>}
    ],
    [?assertEqual({error, malformed}, asobi_dgram_link:decode(B), Label) || {Label, B} <- Cases],
    [
        ?assertMatch({error, malformed}, asobi_dgram_link:decode(crypto:strong_rand_bytes(N)))
     || N <- lists:seq(0, 3)
    ].

%% An external term would decode to an atom or a fun. Assert the shape the
%% decoder accepts is the shape the encoder produces and nothing wider.
an_erlang_term_is_not_a_frame_test() ->
    ?assertEqual({error, malformed}, asobi_dgram_link:decode(term_to_binary({register, #{}}))).

%% --- Auth ---

%% A bare secret comparison would be replayable by anyone who watched one
%% connect. Signing a nonce the gateway chose is not.
the_tag_is_bound_to_the_nonce_test() ->
    A = crypto:strong_rand_bytes(16),
    B = crypto:strong_rand_bytes(16),
    ?assertEqual(asobi_dgram_link:auth_tag(A, ?SECRET), asobi_dgram_link:auth_tag(A, ?SECRET)),
    ?assertNotEqual(asobi_dgram_link:auth_tag(A, ?SECRET), asobi_dgram_link:auth_tag(B, ?SECRET)),
    ?assertNotEqual(
        asobi_dgram_link:auth_tag(A, ?SECRET), asobi_dgram_link:auth_tag(A, <<"another secret">>)
    ).

%% --- Helpers ---

roundtrip(Msg) ->
    <<Len:32/little, Payload/binary>> = asobi_dgram_link:encode(Msg),
    ?assertEqual(Len, byte_size(Payload)),
    asobi_dgram_link:decode(Payload).
