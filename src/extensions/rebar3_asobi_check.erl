-module(rebar3_asobi_check).
-moduledoc """
`rebar3 asobi check` - the primary validation gate for an extension set.

```sh
rebar3 asobi check     # 0 and a summary, or 1 and a report naming both claimants
```

Add it to a host release's `rebar.config`:

```erlang
{project_plugins, [{asobi, {git, "https://github.com/widgrensit/asobi.git", {tag, "v0.50.0"}}}]}.
```

This is the gate, not the backstop. asobi validates the same set again at
boot, but a boot-time failure is raised from inside `nova_sup:init/1` - Nova
compiles the route table before `asobi_app:start/2` runs - so it surfaces with
Nova's crash context rather than a legible asobi error. Catching it in CI is
the difference between "quests and clans both claim the Lua namespace
\"quests\"" and a `function_clause` in somebody else's supervisor.

It runs `asobi_extensions:check/0`, the same function the boot backstop runs,
so build time and boot cannot disagree about what is valid.

Core's reserved names come from the plugin's copy of asobi, which is the
version in `project_plugins`. Pin it to the same tag as the dependency.
""".

-behaviour(provider).

-export([init/1, do/1, format_error/1]).

-define(PROVIDER, check).
-define(NAMESPACE, asobi).
%% `compile`, not `app_discovery`: a manifest is a module, so it has to exist
%% as a beam before it can be called.
-define(DEPS, [{default, compile}]).

-spec init(term()) -> {ok, term()}.
init(State) ->
    Provider = providers:create([
        {name, ?PROVIDER},
        {namespace, ?NAMESPACE},
        {module, ?MODULE},
        {bare, true},
        {deps, ?DEPS},
        {example, "rebar3 asobi check"},
        {opts, []},
        {short_desc, "Validate the installed asobi extension set"},
        {desc,
            "Discovers every application exporting an <app>_extension module, reads "
            "each manifest and checks that no two extensions claim the same table, "
            "RPC prefix, Lua namespace, job queue or HTTP route, and that none "
            "claims a name asobi reserves - for routes that includes any pattern a "
            "request core's own table serves could match. Exits non-zero with both "
            "claimants named."}
    ]),
    {ok, rebar_state:add_provider(State, Provider)}.

-spec do(term()) -> {ok, term()} | {error, string()}.
do(State) ->
    ok = load_apps(rebar_state:project_apps(State) ++ rebar_state:all_deps(State)),
    case asobi_extensions:check() of
        {ok, []} ->
            rebar_api:info("asobi: no extensions installed", []),
            {ok, State};
        {ok, Extensions} ->
            report(Extensions),
            {ok, State};
        {error, Problems} ->
            [rebar_api:error("asobi: ~ts", [Line]) || Line <- asobi_extensions:describe(Problems)],
            {error, format_error(invalid_extension_set)}
    end.

-spec format_error(term()) -> string().
format_error(invalid_extension_set) ->
    "the installed extension set is not valid - see the report above; this "
    "would fail at boot from inside Nova's route compilation";
format_error(Reason) ->
    lists:flatten(io_lib:format("~p", [Reason])).

%%====================================================================
%% Internal
%%====================================================================

%% Discovery reads `application:get_key/2`, so every candidate has to be a
%% loaded application in this VM, and its modules have to be reachable for the
%% manifest to be called.
load_apps(AppInfos) ->
    _ = [load_app(AppInfo) || AppInfo <- AppInfos],
    ok.

load_app(AppInfo) ->
    _ = code:add_pathz(rebar_app_info:ebin_dir(AppInfo)),
    _ = application:load(binary_to_atom(rebar_app_info:name(AppInfo), utf8)),
    ok.

report(Extensions) ->
    rebar_api:info("asobi: ~b extension(s), in migration order", [length(Extensions)]),
    _ = [rebar_api:info("  ~ts", [Line]) || E <- Extensions, Line <- lines(E)],
    _ = [rebar_api:warn("asobi: ~ts", [unreachable(E)]) || E <- Extensions, is_unreachable(E)],
    ok.

%% The route lines are the mount preview: exactly what `asobi_router` will
%% put in the table, path by path, with the chain each one sits behind.
lines(#{routes := Routes} = Extension) ->
    [summarise(Extension) | [["  ", route_line(Route)] || Route <- Routes]].

summarise(#{
    name := Name,
    app := App,
    extension_version := Version,
    rpc := Rpc,
    lua := Lua,
    routes := Routes
}) ->
    io_lib:format(
        "~s (~s, contract v~b): ~b rpc method(s), ~b lua namespace(s), ~b route(s)",
        [Name, App, Version, map_size(Rpc), map_size(Lua), length(Routes)]
    ).

route_line(#{path := Path, method := Method, security := Security}) ->
    io_lib:format(
        "~ts ~ts (~s)",
        [string:uppercase(atom_to_binary(Method, utf8)), Path, Security]
    ).

%% Not an error: it is a legal state halfway through writing an extension.
%% But an extension with no seam at all is reachable by nobody - game logic
%% calls game.<ns>.*, clients call rpc or a declared route, operators call
%% ops actions - so saying nothing would be worse.
is_unreachable(#{rpc := Rpc, lua := Lua, ops := Ops, routes := Routes}) ->
    map_size(Rpc) =:= 0 andalso map_size(Lua) =:= 0 andalso map_size(Ops) =:= 0 andalso
        Routes =:= [].

unreachable(#{app := App}) ->
    io_lib:format(
        "~s declares none of rpc/0, lua/0, ops/0 or routes/0, so nothing can "
        "call it: game logic reaches an extension through game.<ns>.*, clients "
        "through rpc, operators through ops actions, HTTP callers through a "
        "declared route",
        [App]
    ).
