-module(asobi_ops_features).
-moduledoc """
The installed feature set, as the ops read plane reports it.

Core and every installed extension are reported in the same shape -
`#{name, version, capabilities}` - so a console reads one row type and does
not branch on which half of the deployment a feature came from.

This is the endpoint the console uses to decide which of its screens to
render. A composed console bundle carries the screens of every extension it
was built with, and renders each one only when this endpoint says that
extension is installed - so one bundle serves a staging node and a production
node whose extension sets differ. That is the whole mechanism, and it is why
the endpoint reports the extension's *version* as well as its name: a console
rendering against a schema that has moved should be able to say so rather
than fail oddly.

Capabilities report what is *configured*, not what is compiled in: a console
needs to know whether Steam auth will work on this deployment, and "the module
exists" does not answer that. Each entry is a name and a boolean only - never
the configured value, which is usually a secret.

`lua` is the exception and is a module check, because since the runtime merged
into asobi there is nothing to configure: it is present in every stock release.
It stays in the list so a console rendering against a stripped custom release
still gets an answer rather than an absent key.
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
Installed extensions, in dependency order, in the same shape as `core`.

Read from `asobi_extensions:resolve/0`'s memoised result, so this costs a
`persistent_term` read and can never disagree with the set the node actually
booted with.

An extension's capabilities are the seams it declares something under -
`rpc`, `ops`, `lua`, `tables`, plus `console` for one that ships operator
screens - reported as the same `#{name, enabled}` pair core uses. They say
what the extension contributes, never what it contains: no method name, no
action name, no table name, nothing an operator has not already been told by
installing it.
""".
-spec extensions() -> [map()].
extensions() ->
    [describe(Extension) || Extension <- asobi_extensions:resolve()].

-spec describe(asobi_extensions:extension()) -> map().
describe(#{app := App, name := Name, rpc := Rpc, ops := Ops, lua := Lua, owns := Owns}) ->
    #{
        name => Name,
        version => app_version(App),
        capabilities => [
            #{name => ~"console", enabled => ships_console(App)},
            #{name => ~"lua", enabled => map_size(Lua) > 0},
            #{name => ~"ops", enabled => map_size(Ops) > 0},
            #{name => ~"rpc", enabled => map_size(Rpc) > 0},
            #{name => ~"tables", enabled => maps:get(tables, Owns, []) =/= []}
        ]
    }.

-doc """
Whether this extension ships console source, as a file check on its `priv`.

The console does not need this to decide what to render - it knows what was
compiled into it. It is reported for the case that produces a confusing
console rather than a broken one: an extension that ships screens, installed
on a node whose bundle was never recomposed, shows `console` here and no
screens in the nav. That difference is the whole diagnosis, and without this
capability an operator has nothing to read it from.
""".
-spec ships_console(atom()) -> boolean().
ships_console(App) ->
    case code:priv_dir(App) of
        {error, _Reason} -> false;
        Priv -> filelib:is_regular(filename:join([Priv, "console", "index.jsx"]))
    end.

-spec app_version(atom()) -> binary().
app_version(App) ->
    case application:get_key(App, vsn) of
        {ok, Vsn} when is_list(Vsn) -> list_to_binary(Vsn);
        _ -> ~"unknown"
    end.

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
