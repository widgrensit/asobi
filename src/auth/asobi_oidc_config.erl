-module(asobi_oidc_config).
-behaviour(nova_auth_oidc).

-include_lib("kernel/include/logger.hrl").

-export([config/0]).

-spec config() -> map().
config() ->
    Providers = narrow_providers(application:get_env(asobi, oidc_providers, #{})),
    BaseUrl =
        case application:get_env(asobi, base_url, ~"http://localhost:8082") of
            V when is_binary(V) -> V;
            _ -> ~"http://localhost:8082"
        end,
    Base = #{
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
    },
    case map_size(Providers) of
        0 ->
            Base;
        _ ->
            %% asobi#220: pins the discovery/JWKS fetch to the same
            %% explicit, version-independent TLS verification already
            %% used for Steam/IAP (asobi_tls_client, #171). A trust
            %% anchor, not just a TLS option - see nova_auth_oidc's
            %% moduledoc - so this MUST stay a static call, never built
            %% from oidc_providers or any other operator/env config.
            %%
            %% asobi_tls_client:ssl_options/0 raises if the image has no
            %% CA trust store - only call it when there's an actual
            %% provider to configure, so a deployment that doesn't use
            %% OIDC never pays that boot-time risk (this function is
            %% called at every boot, by asobi_sup's provider-startup
            %% gate, whether or not OIDC ends up being used).
            Base#{
                provider_configuration_opts => #{
                    request_opts => #{ssl => asobi_tls_client:ssl_options()}
                }
            }
    end.

-spec narrow_providers(term()) -> #{atom() => map()}.
narrow_providers(M) when is_map(M) ->
    maps:fold(
        fun
            (K, V, Acc) when is_atom(K), is_map(V) ->
                case validate_provider(K, V) of
                    {ok, Provider} -> Acc#{K => Provider};
                    drop -> Acc
                end;
            (K, _V, Acc) ->
                ?LOG_ERROR(#{
                    msg =>
                        ~"oidc_providers entry key must be an atom and value a map; provider disabled",
                    key => K
                }),
                Acc
        end,
        #{},
        M
    );
narrow_providers(_Other) ->
    ?LOG_ERROR(#{msg => ~"oidc_providers is not a map; all OIDC providers disabled"}),
    #{}.

%% asobi#220: nova_auth_oidc:ensure_providers/1 pattern-matches
%% #{issuer := Issuer} per provider - a provider entry present in config
%% but missing issuer would otherwise crash with a bare function_clause
%% deep inside a dependency during asobi_sup's boot, taking the whole
%% game backend down over what is an optional feature (social login).
%% Disable just that one provider instead: log loudly - key NAMES only,
%% never the provider map itself, which holds client_secret - and drop
%% it, so a config typo degrades one login option, not the whole node.
%%
%% Rejecting a non-https issuer is not optional either: the TLS pin this
%% module supplies via provider_configuration_opts only protects a
%% connection that is already HTTPS - an operator-typo'd (or malicious,
%% if this config is ever built from anything less trusted than static
%% code) http:// issuer bypasses it entirely, fetching discovery and the
%% JWKS in plaintext.
-spec validate_provider(atom(), map()) -> {ok, map()} | drop.
validate_provider(_Name, #{issuer := <<"https://", _/binary>>} = Provider) ->
    {ok, Provider};
validate_provider(Name, #{issuer := Issuer}) when is_binary(Issuer) ->
    ?LOG_ERROR(#{
        msg => ~"oidc provider has a non-https issuer; provider disabled",
        provider => Name
    }),
    drop;
validate_provider(Name, Provider) ->
    ?LOG_ERROR(#{
        msg => ~"oidc provider is missing issuer; provider disabled",
        provider => Name,
        present_keys => maps:keys(Provider)
    }),
    drop.
