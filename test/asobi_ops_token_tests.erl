-module(asobi_ops_token_tests).

-include_lib("eunit/include/eunit.hrl").

-define(ENV, ~"019f7646-9ddb-77ee-82f5-b5e7f3b9ee9d").
-define(ENGINE_KEY, ~"engine-api-key-not-a-real-one").

%% The cloud credential. A valid MAC is necessary and not sufficient, and most
%% of what is asserted here is the "not sufficient" half: a signature the
%% holder cannot forge still buys nothing if the token is for another
%% environment, has expired, was minted with an unbounded lifetime, or names a
%% capability class this plane does not have.

token_test_() ->
    {foreach, fun setup/0, fun cleanup/1, [
        fun a_minted_token_verifies/0,
        fun the_claims_survive_the_round_trip/0,
        fun a_token_for_another_environment_is_refused/0,
        fun a_token_signed_with_another_key_is_refused/0,
        fun a_tampered_payload_is_refused/0,
        fun an_expired_token_is_refused/0,
        fun a_long_lived_token_is_refused_even_when_signed/0,
        fun a_future_token_is_refused/0,
        fun an_unknown_capability_class_is_refused/0,
        fun a_malformed_token_is_refused/0,
        fun a_version_that_is_not_ours_is_refused/0,
        fun nothing_verifies_without_both_halves_of_the_config/0,
        fun the_key_is_derived_not_the_credential/0
    ]}.

setup() ->
    application:set_env(asobi, ops_token_secret, ?ENGINE_KEY),
    application:set_env(asobi, env_id, ?ENV),
    ok.

cleanup(_) ->
    application:unset_env(asobi, ops_token_secret),
    application:unset_env(asobi, env_id),
    ok.

a_minted_token_verifies() ->
    ?assertMatch({ok, #{sub := ~"user-1"}}, asobi_ops_token:verify(mint())).

the_claims_survive_the_round_trip() ->
    {ok, Claims} = asobi_ops_token:verify(mint(#{caps => [read, player_data]})),
    ?assertEqual(?ENV, maps:get(env, Claims)),
    ?assertEqual(~"user-1", maps:get(sub, Claims)),
    ?assertEqual([read, player_data], maps:get(caps, Claims)).

%% The key is per environment, so this is already refused by the signature -
%% the `env` check is the second lock on the same door, and it is the one that
%% still holds if a key is ever shared.
a_token_for_another_environment_is_refused() ->
    Token = asobi_ops_token:sign(key(), claims(#{env => ~"some-other-env"})),
    ?assertEqual({error, wrong_environment}, asobi_ops_token:verify(Token)).

a_token_signed_with_another_key_is_refused() ->
    Token = asobi_ops_token:sign(asobi_ops_token:key(~"a-different-engine-key"), claims(#{})),
    ?assertEqual({error, bad_signature}, asobi_ops_token:verify(Token)).

a_tampered_payload_is_refused() ->
    [Version, Payload, Mac] = binary:split(mint(), ~".", [global]),
    Decoded = base64:decode(Payload, #{mode => urlsafe, padding => false}),
    Swapped = binary:replace(Decoded, ~"\"read\"", ~"\"config\""),
    Reencoded = base64:encode(Swapped, #{mode => urlsafe, padding => false}),
    Tampered = <<Version/binary, ".", Reencoded/binary, ".", Mac/binary>>,
    ?assertEqual({error, bad_signature}, asobi_ops_token:verify(Tampered)).

an_expired_token_is_refused() ->
    Now = erlang:system_time(second),
    Token = asobi_ops_token:sign(key(), claims(#{iat => Now - 600, exp => Now - 1})),
    ?assertEqual({error, expired}, asobi_ops_token:verify(Token)).

%% The one that matters most: this side of the wire does not trust the other
%% side to have picked a sane TTL, so a mint bug cannot issue a token this
%% node will honour for a year. There is no revocation list to fall back on.
a_long_lived_token_is_refused_even_when_signed() ->
    Now = erlang:system_time(second),
    Token = asobi_ops_token:sign(key(), claims(#{iat => Now, exp => Now + 31_536_000})),
    ?assertEqual({error, lifetime_too_long}, asobi_ops_token:verify(Token)),
    AtTheLimit = asobi_ops_token:sign(
        key(), claims(#{iat => Now, exp => Now + asobi_ops_token:max_ttl()})
    ),
    ?assertMatch({ok, _}, asobi_ops_token:verify(AtTheLimit)).

a_future_token_is_refused() ->
    Now = erlang:system_time(second),
    Token = asobi_ops_token:sign(key(), claims(#{iat => Now + 3600, exp => Now + 3900})),
    ?assertEqual({error, not_yet_valid}, asobi_ops_token:verify(Token)).

an_unknown_capability_class_is_refused() ->
    Now = erlang:system_time(second),
    Json = #{
        ~"env" => ?ENV,
        ~"sub" => ~"user-1",
        ~"caps" => [~"read", ~"superuser"],
        ~"iat" => Now,
        ~"exp" => Now + 300
    },
    ?assertEqual({error, bad_caps}, asobi_ops_token:verify(hand_sign(Json))).

a_malformed_token_is_refused() ->
    [
        ?assertEqual({error, malformed}, asobi_ops_token:verify(T))
     || T <- [~"", ~"nonsense", ~"v1.only-two", ~"v1.a.b.c"]
    ],
    ?assertEqual({error, malformed}, asobi_ops_token:verify(not_a_binary)).

a_version_that_is_not_ours_is_refused() ->
    [_Version, Payload, Mac] = binary:split(mint(), ~".", [global]),
    ?assertEqual(
        {error, malformed},
        asobi_ops_token:verify(<<"v2.", Payload/binary, ".", Mac/binary>>)
    ).

%% A node that knows its key but not which environment it is cannot check
%% `env`, so it refuses rather than accepting a token minted for somebody
%% else's environment.
nothing_verifies_without_both_halves_of_the_config() ->
    Token = mint(),
    application:unset_env(asobi, env_id),
    ?assertEqual({error, not_configured}, asobi_ops_token:verify(Token)),
    application:set_env(asobi, env_id, ?ENV),
    application:unset_env(asobi, ops_token_secret),
    ?assertEqual({error, not_configured}, asobi_ops_token:verify(Token)).

%% A credential used to authenticate must not double as a signing key.
the_key_is_derived_not_the_credential() ->
    ?assertNotEqual(?ENGINE_KEY, asobi_ops_token:key(?ENGINE_KEY)),
    ?assertEqual(32, byte_size(asobi_ops_token:key(?ENGINE_KEY))),
    ?assertNotEqual(
        asobi_ops_token:key(?ENGINE_KEY),
        asobi_ops_token:key(<<?ENGINE_KEY/binary, "x">>)
    ).

%%--------------------------------------------------------------------

key() -> asobi_ops_token:key(?ENGINE_KEY).

mint() -> mint(#{}).

mint(Overrides) -> asobi_ops_token:sign(key(), claims(Overrides)).

claims(Overrides) ->
    Now = erlang:system_time(second),
    maps:merge(
        #{env => ?ENV, sub => ~"user-1", caps => [read], iat => Now, exp => Now + 300},
        Overrides
    ).

%% Sign a claims object this module's own `sign/2` would refuse to build, so
%% the verifier is tested against a shape only a broken minter would produce.
hand_sign(Json) ->
    Payload = base64:encode(iolist_to_binary(json:encode(Json)), #{
        mode => urlsafe, padding => false
    }),
    Signed = <<"v1.", Payload/binary>>,
    Mac = base64:encode(crypto:mac(hmac, sha256, key(), Signed), #{
        mode => urlsafe, padding => false
    }),
    <<Signed/binary, ".", Mac/binary>>.
