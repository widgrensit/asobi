-module(asobi_oidc_config_tests).
-include_lib("eunit/include/eunit.hrl").

%% asobi#220: provider_configuration_opts pins the discovery/JWKS fetch to
%% explicit TLS options (asobi_tls_client, the same helper #171 uses for
%% Steam/IAP) instead of httpc's implicit default. This is a trust anchor
%% (see nova_auth_oidc's moduledoc), so it must always be built from the
%% same static helper - never from oidc_providers or any other
%% operator/env-supplied config. It's only present when at least one
%% provider is actually configured (asobi_tls_client:ssl_options/0 can
%% raise on an image with no CA trust store, and calling it unconditionally
%% would mean a deployment that doesn't use OIDC pays that boot-time risk
%% too - see asobi_sup_oidc_tests for the boot-gate side of this).

config_includes_provider_configuration_opts_when_a_provider_is_configured_test() ->
    application:set_env(asobi, oidc_providers, #{
        authentik => #{issuer => ~"https://auth.example.com"}
    }),
    try
        Cfg = asobi_oidc_config:config(),
        ?assert(maps:is_key(provider_configuration_opts, Cfg)),
        #{request_opts := #{ssl := SslOpts}} = maps:get(provider_configuration_opts, Cfg),
        ?assertEqual(asobi_tls_client:ssl_options(), SslOpts)
    after
        application:unset_env(asobi, oidc_providers)
    end.

config_omits_provider_configuration_opts_when_no_provider_is_configured_test() ->
    application:unset_env(asobi, oidc_providers),
    Cfg = asobi_oidc_config:config(),
    ?assertNot(maps:is_key(provider_configuration_opts, Cfg)).

config_provider_configuration_opts_only_carries_request_opts_test() ->
    %% nova_auth_oidc validates this map's keys against
    %% [fallback_expiry, request_opts, quirks] and errors on anything else -
    %% pin the shape here too so a future edit can't silently add a key
    %% ensure_providers/1 would then reject at boot.
    application:set_env(asobi, oidc_providers, #{
        authentik => #{issuer => ~"https://auth.example.com"}
    }),
    try
        Cfg = asobi_oidc_config:config(),
        Pco = maps:get(provider_configuration_opts, Cfg),
        ?assertEqual([request_opts], maps:keys(Pco))
    after
        application:unset_env(asobi, oidc_providers)
    end.

config_narrows_providers_to_atom_keyed_maps_test() ->
    application:set_env(asobi, oidc_providers, #{
        authentik => #{issuer => ~"https://auth.example.com"},
        ~"not_an_atom_key" => #{issuer => ~"https://evil.example.com"},
        bad_entry => not_a_map
    }),
    try
        Cfg = asobi_oidc_config:config(),
        ?assertEqual([authentik], maps:keys(maps:get(providers, Cfg)))
    after
        application:unset_env(asobi, oidc_providers)
    end.

config_defaults_providers_to_empty_map_test() ->
    application:unset_env(asobi, oidc_providers),
    Cfg = asobi_oidc_config:config(),
    ?assertEqual(#{}, maps:get(providers, Cfg)).

config_preserves_full_provider_map_for_valid_entry_test() ->
    %% A provider that passes validation must come through with every
    %% field intact (client_id/client_secret/scopes/...), not just issuer.
    application:set_env(asobi, oidc_providers, #{
        authentik => #{
            issuer => ~"https://auth.example.com",
            client_id => ~"cid",
            client_secret => ~"secret",
            scopes => [~"openid", ~"email"]
        }
    }),
    try
        Cfg = asobi_oidc_config:config(),
        ?assertEqual(
            #{
                issuer => ~"https://auth.example.com",
                client_id => ~"cid",
                client_secret => ~"secret",
                scopes => [~"openid", ~"email"]
            },
            maps:get(authentik, maps:get(providers, Cfg))
        )
    after
        application:unset_env(asobi, oidc_providers)
    end.

%% asobi#220 (post security review): nova_auth_oidc:ensure_providers/1
%% pattern-matches #{issuer := Issuer} per provider - a present-but-missing
%% issuer would otherwise crash with a bare function_clause deep inside a
%% dependency during asobi_sup's boot, taking the whole game backend down
%% over what is an optional feature. Disable just that one provider
%% instead - it's dropped from the returned providers map, not raised.
config_drops_provider_missing_issuer_test() ->
    application:set_env(asobi, oidc_providers, #{
        authentik => #{client_id => ~"cid", client_secret => ~"secret"},
        google => #{issuer => ~"https://accounts.google.com"}
    }),
    try
        Cfg = asobi_oidc_config:config(),
        ?assertEqual([google], maps:keys(maps:get(providers, Cfg)))
    after
        application:unset_env(asobi, oidc_providers)
    end.

%% The TLS pin in provider_configuration_opts only protects a connection
%% that is already HTTPS - a non-https issuer bypasses it entirely, so
%% this provider is dropped rather than silently fetching discovery and
%% the JWKS in plaintext.
config_drops_provider_with_insecure_issuer_test() ->
    application:set_env(asobi, oidc_providers, #{
        authentik => #{issuer => ~"http://auth.example.com"},
        google => #{issuer => ~"https://accounts.google.com"}
    }),
    try
        Cfg = asobi_oidc_config:config(),
        ?assertEqual([google], maps:keys(maps:get(providers, Cfg)))
    after
        application:unset_env(asobi, oidc_providers)
    end.
