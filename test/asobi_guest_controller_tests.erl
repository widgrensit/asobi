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
