-module(asobi_ops_features).
-moduledoc """
The installed feature set, as the ops read plane reports it.

There is no extension registry yet, so everything here comes from core and
`extensions/0` is empty. Core and an extension are reported in the same shape
- `#{name, version, capabilities}` - so a registry can fill `extensions/0`
later without the endpoint, its envelope, or its consumers changing.

Capabilities report what is *configured*, not what is compiled in: a console
needs to know whether Steam auth will work on this deployment, and "the module
exists" does not answer that. Each entry is a name and a boolean only - never
the configured value, which is usually a secret.
""".

-export([features/0, extensions/0, capabilities/0]).

-spec features() -> map().
features() ->
    #{
        data => #{
            core => #{
                name => ~"asobi",
                version => version(),
                capabilities => capabilities()
            },
            extensions => extensions()
        }
    }.

-doc """
Installed extensions, in the same shape as the `core` entry.

Always `[]` today. When an extension registry lands this reads from it and
nothing above this function changes.
""".
-spec extensions() -> [map()].
extensions() -> [].

-doc "Core capabilities, sorted by name so the response is stable.".
-spec capabilities() -> [#{name := binary(), enabled := boolean()}].
capabilities() ->
    [
        #{name => Name, enabled => Enabled}
     || {Name, Enabled} <- lists:sort([
            {~"clustering", configured(cluster)},
            {~"guest_auth", configured(guest_auth)},
            {~"iap_apple", configured(apple_bundle_id)},
            {~"iap_google", configured(google_package_name)},
            {~"lua", module_available(asobi_lua_match)},
            {~"matches", any_mode(fun is_match_mode/1)},
            {~"oidc", configured_collection(oidc_providers)},
            {~"steam", configured(steam_api_key)},
            {~"worlds", any_mode(fun is_world_mode/1)}
        ])
    ].

-spec version() -> binary().
version() ->
    case application:get_key(asobi, vsn) of
        {ok, Vsn} when is_list(Vsn) -> list_to_binary(Vsn);
        _ -> ~"unknown"
    end.

-spec configured(atom()) -> boolean().
configured(Key) ->
    case application:get_env(asobi, Key) of
        {ok, undefined} -> false;
        {ok, ~""} -> false;
        {ok, _} -> true;
        undefined -> false
    end.

-spec configured_collection(atom()) -> boolean().
configured_collection(Key) ->
    case application:get_env(asobi, Key) of
        {ok, Map} when is_map(Map) -> map_size(Map) > 0;
        {ok, List} when is_list(List) -> List =/= [];
        _ -> false
    end.

-spec module_available(module()) -> boolean().
module_available(Module) ->
    code:which(Module) =/= non_existing.

-spec any_mode(fun((term()) -> boolean())) -> boolean().
any_mode(Pred) ->
    case application:get_env(asobi, game_modes) of
        {ok, Modes} when is_map(Modes) -> lists:any(Pred, maps:values(Modes));
        _ -> false
    end.

-spec is_world_mode(term()) -> boolean().
is_world_mode(#{type := world}) -> true;
is_world_mode(_) -> false.

-spec is_match_mode(term()) -> boolean().
is_match_mode(Config) -> not is_world_mode(Config).
