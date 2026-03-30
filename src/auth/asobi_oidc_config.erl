-module(asobi_oidc_config).
-behaviour(nova_auth_oidc).

-export([config/0]).

-spec config() -> map().
config() ->
    Providers = application:get_env(asobi, oidc_providers, #{}),
    #{
        providers => Providers,
        base_url => application:get_env(asobi, base_url, ~"http://localhost:8082"),
        auth_path_prefix => ~"/api/v1/auth/oidc",
        scopes => [~"openid", ~"profile", ~"email"],
        on_success => {redirect, ~"/"},
        on_failure => {status, 401},
        claims_mapping => #{
            ~"sub" => provider_uid,
            ~"email" => provider_email,
            ~"name" => provider_display_name
        }
    }.
