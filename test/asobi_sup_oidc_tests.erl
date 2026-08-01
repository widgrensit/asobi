-module(asobi_sup_oidc_tests).
-include_lib("eunit/include/eunit.hrl").

%% asobi#220: nova_auth_oidc_sup never starts any provider workers on its
%% own - ensure_providers/1 is what does that, and nothing called it
%% before this fix (OIDC social login never actually worked). Pin the
%% boot-time gating: only attempt it when a provider is actually
%% configured, so a deployment that doesn't use OIDC never attempts
%% discovery-fetch network I/O at boot.

setup() ->
    meck:new(nova_auth_oidc, [passthrough, non_strict]),
    meck:expect(nova_auth_oidc, ensure_providers, fun(_Mod) -> ok end),
    ok.

cleanup(_) ->
    meck:unload(nova_auth_oidc),
    application:unset_env(asobi, oidc_providers).

ensure_oidc_providers_test_() ->
    {foreach, fun setup/0, fun cleanup/1, [
        {"no oidc_providers configured: does not call ensure_providers",
            fun no_providers_skips_ensure/0},
        {"empty oidc_providers map: does not call ensure_providers",
            fun empty_providers_skips_ensure/0},
        {"a configured provider: calls ensure_providers with asobi_oidc_config",
            fun configured_provider_calls_ensure/0},
        {"always returns ignore (supervisor child-spec contract)", fun always_returns_ignore/0}
    ]}.

no_providers_skips_ensure() ->
    application:unset_env(asobi, oidc_providers),
    asobi_sup:ensure_oidc_providers(),
    ?assertEqual(0, meck:num_calls(nova_auth_oidc, ensure_providers, '_')).

empty_providers_skips_ensure() ->
    application:set_env(asobi, oidc_providers, #{}),
    asobi_sup:ensure_oidc_providers(),
    ?assertEqual(0, meck:num_calls(nova_auth_oidc, ensure_providers, '_')).

configured_provider_calls_ensure() ->
    application:set_env(asobi, oidc_providers, #{
        authentik => #{issuer => ~"https://auth.example.com"}
    }),
    asobi_sup:ensure_oidc_providers(),
    ?assertEqual(1, meck:num_calls(nova_auth_oidc, ensure_providers, [asobi_oidc_config])).

always_returns_ignore() ->
    application:unset_env(asobi, oidc_providers),
    ?assertEqual(ignore, asobi_sup:ensure_oidc_providers()),
    application:set_env(asobi, oidc_providers, #{
        authentik => #{issuer => ~"https://auth.example.com"}
    }),
    ?assertEqual(ignore, asobi_sup:ensure_oidc_providers()).
