-module(asobi_oidc_config).
-behaviour(nova_auth_oidc).

-export([config/0]).

-spec config() -> nova_auth_oidc:oidc_config().
config() ->
    Providers = narrow_providers(application:get_env(asobi, oidc_providers, #{})),
    BaseUrl =
        case application:get_env(asobi, base_url, ~"http://localhost:8082") of
            V when is_binary(V) -> V;
            _ -> ~"http://localhost:8082"
        end,
    #{
        providers => Providers,
        base_url => BaseUrl,
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

-spec narrow_providers(term()) -> #{atom() => map()}.
narrow_providers(M) when is_map(M) ->
    maps:fold(
        fun
            (K, V, Acc) when is_atom(K), is_map(V) -> Acc#{K => V};
            (_, _, Acc) -> Acc
        end,
        #{},
        M
    );
narrow_providers(_) ->
    #{}.
