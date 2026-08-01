-module(asobi_oauth_controller_tests).
-include_lib("eunit/include/eunit.hrl").

%% asobi#220 security review (H-1): /api/v1/auth/oauth is unauthenticated
%% (security => false). Before this, a dependency crash inside
%% nova_auth_oidc_jwt:validate_token/3 (e.g. the function_clause bug
%% fixed in novaframework/nova_auth_oidc#10) would propagate straight to
%% cowboy uncaught - on an unauthenticated route, an unbounded 500/log
%% amplifier with no rate limit. validate_oidc_token/2 must always
%% return a normal {error, _} tuple instead, no matter what the
%% dependency does.

setup() ->
    meck:new(nova_auth_oidc_jwt, [passthrough, non_strict]),
    ok.

cleanup(_) ->
    meck:unload(nova_auth_oidc_jwt).

validate_oidc_token_test_() ->
    {foreach, fun setup/0, fun cleanup/1, [
        {"a successful validation passes the actor map through",
            fun successful_validation_passes_through/0},
        {"an {error, _} from the dependency passes through unchanged",
            fun dependency_error_passes_through/0},
        {"a dependency crash (function_clause) is caught, not propagated",
            fun dependency_crash_is_caught/0},
        {"a dependency crash (badarg) is caught, not propagated",
            fun dependency_badarg_is_caught/0},
        {"a well-typed but unmatched return value is caught too, not just exceptions",
            fun dependency_unmatched_return_is_caught/0}
    ]}.

successful_validation_passes_through() ->
    meck:expect(nova_auth_oidc_jwt, validate_token, fun(_, _, _) ->
        {ok, #{id => ~"user-1"}}
    end),
    ?assertEqual(
        {ok, #{id => ~"user-1"}},
        asobi_oauth_controller:validate_oidc_token(google, ~"sometoken")
    ).

dependency_error_passes_through() ->
    meck:expect(nova_auth_oidc_jwt, validate_token, fun(_, _, _) ->
        {error, invalid_signature}
    end),
    ?assertEqual(
        {error, invalid_signature},
        asobi_oauth_controller:validate_oidc_token(google, ~"sometoken")
    ).

dependency_crash_is_caught() ->
    meck:expect(nova_auth_oidc_jwt, validate_token, fun(_, _, _) ->
        error(function_clause)
    end),
    ?assertEqual(
        {error, validation_failed},
        asobi_oauth_controller:validate_oidc_token(google, ~"sometoken")
    ).

dependency_badarg_is_caught() ->
    meck:expect(nova_auth_oidc_jwt, validate_token, fun(_, _, _) ->
        erlang:error(badarg)
    end),
    ?assertEqual(
        {error, validation_failed},
        asobi_oauth_controller:validate_oidc_token(google, ~"sometoken")
    ).

%% validate_oidc_token/2 deliberately has no explicit catch-all case
%% clause for this (dialyzer proves the dependency's current, declared
%% contract never produces one) - this proves the case being INSIDE the
%% try body, not a `try ... of` clause, is what makes an unmatched value
%% safe: it raises case_clause, which the same catch handles, rather
%% than propagating as an uncaught try_clause exception.
dependency_unmatched_return_is_caught() ->
    meck:expect(nova_auth_oidc_jwt, validate_token, fun(_, _, _) ->
        something_unexpected
    end),
    ?assertEqual(
        {error, validation_failed},
        asobi_oauth_controller:validate_oidc_token(google, ~"sometoken")
    ).

%% ---- real end-to-end integration (asobi#220) ----
%%
%% Everything above mocks nova_auth_oidc_jwt itself, which is correct for
%% pinning validate_oidc_token/2's own crash-safety contract - but it
%% can't prove OIDC login actually WORKS, only that this module survives
%% the dependency misbehaving. This group drives the REAL
%% nova_auth_oidc_jwt:validate_token/3 -> oidcc_jwt_util:verify_signature/3
%% chain with a genuinely-signed token, mocking only the one real network
%% boundary (the discovery worker's get_jwks/1) - proving the full chain
%% asobi_oauth_controller -> nova_auth_oidc_jwt -> oidcc_jwt_util that
%% was broken end to end before novaframework/nova_auth_oidc#9/#10 now
%% actually validates a real token.

real_validation_setup() ->
    %% nova_auth_oidc:config/1 caches asobi_oidc_config:config/0's result in
    %% persistent_term on first call - invalidate before setting env so this
    %% group's oidc_providers value is guaranteed to be the one actually
    %% read, regardless of what ran (and cached) before it.
    nova_auth_oidc:invalidate_cache(asobi_oidc_config),
    application:set_env(asobi, oidc_providers, #{
        google => #{
            issuer => ~"https://accounts.google.com",
            client_id => ~"test-client-id",
            client_secret => ~"test-client-secret"
        }
    }),
    meck:new(oidcc_provider_configuration_worker, [passthrough]),
    ok.

real_validation_cleanup(_) ->
    meck:unload(oidcc_provider_configuration_worker),
    application:unset_env(asobi, oidc_providers),
    nova_auth_oidc:invalidate_cache(asobi_oidc_config).

real_validation_test_() ->
    {foreach, fun real_validation_setup/0, fun real_validation_cleanup/1, [
        {"a genuinely RS256-signed, correctly-claimed token validates end to end",
            fun genuine_token_validates/0},
        {"a genuinely signed but expired token is rejected by real claims validation",
            fun genuine_expired_token_rejected/0}
    ]}.

genuine_token_validates() ->
    Priv = jose_jwk:generate_key({rsa, 2048}),
    mock_jwks(Priv),
    Token = sign_id_token(Priv, id_token_claims()),
    %% asobi_oidc_config's claims_mapping maps ~"sub" -> provider_uid (not
    %% id), merged onto build_actor/3's #{provider => Provider} base -
    %% this is the exact shape nova_auth_claims:map/3 produces, verified
    %% by reading it rather than guessed.
    ?assertEqual(
        {ok, #{provider => google, provider_uid => ~"user-42"}},
        asobi_oauth_controller:validate_oidc_token(google, Token)
    ).

genuine_expired_token_rejected() ->
    Priv = jose_jwk:generate_key({rsa, 2048}),
    mock_jwks(Priv),
    Past = erlang:system_time(second) - 3600,
    Token = sign_id_token(Priv, (id_token_claims())#{~"exp" => Past}),
    ?assertEqual(
        {error, token_expired},
        asobi_oauth_controller:validate_oidc_token(google, Token)
    ).

mock_jwks(PrivKey) ->
    PubMap = element(2, jose_jwk:to_map(jose_jwk:to_public(PrivKey))),
    Jwks = jose_jwk:from_map(#{~"keys" => [PubMap]}),
    meck:expect(oidcc_provider_configuration_worker, get_jwks, fun(_) -> Jwks end).

sign_id_token(PrivKey, Claims) ->
    Jwt = jose_jwt:from(Claims),
    {_, Signed} = jose_jwt:sign(PrivKey, #{~"alg" => ~"RS256"}, Jwt),
    {_, Compact} = jose_jws:compact(Signed),
    Compact.

id_token_claims() ->
    #{
        ~"iss" => ~"https://accounts.google.com",
        ~"aud" => ~"test-client-id",
        ~"sub" => ~"user-42",
        ~"exp" => erlang:system_time(second) + 3600
    }.
