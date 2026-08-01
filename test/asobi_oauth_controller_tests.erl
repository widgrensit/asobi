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
