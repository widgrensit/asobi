-module(asobi_oidc_config_tests).
-include_lib("eunit/include/eunit.hrl").

%% asobi#220: provider_configuration_opts pins the discovery/JWKS fetch to
%% explicit TLS options (asobi_tls_client, the same helper #171 uses for
%% Steam/IAP) instead of httpc's implicit default. This is a trust anchor
%% (see nova_auth_oidc's moduledoc), so it must always be present and built
%% from the same static helper - never from oidc_providers or any other
%% operator/env-supplied config.

config_includes_provider_configuration_opts_test() ->
    Cfg = asobi_oidc_config:config(),
    ?assert(maps:is_key(provider_configuration_opts, Cfg)),
    #{request_opts := #{ssl := SslOpts}} = maps:get(provider_configuration_opts, Cfg),
    ?assertEqual(asobi_tls_client:ssl_options(), SslOpts).

config_provider_configuration_opts_only_carries_request_opts_test() ->
    %% nova_auth_oidc validates this map's keys against
    %% [fallback_expiry, request_opts, quirks] and errors on anything else -
    %% pin the shape here too so a future edit can't silently add a key
    %% ensure_providers/1 would then reject at boot.
    Cfg = asobi_oidc_config:config(),
    Pco = maps:get(provider_configuration_opts, Cfg),
    ?assertEqual([request_opts], maps:keys(Pco)).

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
