-module(asobi_guest_controller_tests).

-include_lib("eunit/include/eunit.hrl").

setup() ->
    application:set_env(asobi, guest_verifier_pepper, crypto:strong_rand_bytes(32)),
    ok.

cleanup(_) ->
    application:unset_env(asobi, guest_verifier_pepper).

verifier_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        {"correct secret verifies", fun correct_secret_verifies/0},
        {"wrong secret is rejected", fun wrong_secret_rejected/0},
        {"tampered verifier is rejected", fun tampered_verifier_rejected/0},
        {"verify fails closed without a pepper", fun no_pepper_fails_closed/0}
    ]}.

correct_secret_verifies() ->
    Secret = crypto:strong_rand_bytes(32),
    Meta = asobi_guest_controller:make_verifier(Secret),
    ?assert(asobi_guest_controller:verify(Secret, Meta)).

wrong_secret_rejected() ->
    Meta = asobi_guest_controller:make_verifier(crypto:strong_rand_bytes(32)),
    ?assertNot(asobi_guest_controller:verify(crypto:strong_rand_bytes(32), Meta)).

tampered_verifier_rejected() ->
    Secret = crypto:strong_rand_bytes(32),
    Meta = asobi_guest_controller:make_verifier(Secret),
    Tampered = Meta#{~"verifier" => base64:encode(crypto:strong_rand_bytes(32))},
    ?assertNot(asobi_guest_controller:verify(Secret, Tampered)).

no_pepper_fails_closed() ->
    Secret = crypto:strong_rand_bytes(32),
    Meta = asobi_guest_controller:make_verifier(Secret),
    application:unset_env(asobi, guest_verifier_pepper),
    ?assertNot(asobi_guest_controller:verify(Secret, Meta)),
    application:set_env(asobi, guest_verifier_pepper, crypto:strong_rand_bytes(32)).

decode_secret_test() ->
    ?assertMatch(
        {ok, _}, asobi_guest_controller:decode_secret(base64:encode(crypto:strong_rand_bytes(32)))
    ),
    ?assertEqual(
        error, asobi_guest_controller:decode_secret(base64:encode(crypto:strong_rand_bytes(16)))
    ),
    ?assertEqual(error, asobi_guest_controller:decode_secret(~"not valid base64 !!!")).

decode_secret_upper_bound_test() ->
    %% A secret over the byte cap is rejected (would otherwise be HMAC'd per
    %% request on an unauthenticated endpoint).
    ?assertEqual(
        error, asobi_guest_controller:decode_secret(base64:encode(crypto:strong_rand_bytes(129)))
    ),
    %% Oversized base64 input is rejected before it is even decoded.
    ?assertEqual(
        error, asobi_guest_controller:decode_secret(binary:copy(~"A", 4096))
    ).

authenticate_disabled_returns_403_test() ->
    application:unset_env(asobi, guest_auth),
    Req = #{
        json => #{
            ~"device_id" => ~"dev-abc",
            ~"device_secret" => base64:encode(crypto:strong_rand_bytes(32))
        }
    },
    ?assertMatch(
        {json, 403, _, #{error := ~"guest_auth_disabled", message := _}},
        asobi_guest_controller:authenticate(Req)
    ).

valid_device_id_test() ->
    ?assert(asobi_guest_controller:valid_device_id(base64:encode(crypto:strong_rand_bytes(16)))),
    ?assertNot(asobi_guest_controller:valid_device_id(~"")),
    ?assertNot(asobi_guest_controller:valid_device_id(binary:copy(~"a", 256))).
