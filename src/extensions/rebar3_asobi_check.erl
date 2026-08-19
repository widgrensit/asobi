-module(rebar3_asobi_check).
-moduledoc """
`rebar3 asobi check` - the primary validation gate for an extension set.

```sh
rebar3 asobi check     # 0 and a summary, or 1 and a report naming both claimants
```

Add it to a host release's `rebar.config`:

```erlang
{project_plugins, [{asobi, {git, "https://github.com/widgrensit/asobi.git", {tag, "v0.83.5"}}}]}.
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
-ifdef(TEST).
-export([co_mounted_from_config/1]).
-endif.

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
    ok = reserve_co_mounted_apps(State),
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

%% The boot path reserves every co-mounted application's routes - nova plus
%% the bootstrap app's `nova_apps` - so `/health` and its siblings cannot be
%% claimed. This VM never loads sys.config, so without this the gate would
%% see no `nova_apps`, pass a `/health` claim the node refuses at boot, and
%% make `check/0`'s "build gate and boot backstop can never disagree" a lie.
%% Read the same two keys the boot path reads out of the release sys_config
%% and set them for the check. Defensive by design: an unreadable or
%% templated (`.src`) config falls back to reserving nothing extra - which is
%% also the correct answer for a project that declares no `nova_apps` - and
%% never crashes the build.
reserve_co_mounted_apps(State) ->
    try
        case sys_config(State) of
            {ok, Config} ->
                apply_co_mounted(co_mounted_from_config(Config));
            none ->
                ok
        end
    catch
        Class:Reason ->
            rebar_api:debug("asobi: could not read nova_apps from config (~p:~p)", [Class, Reason]),
            ok
    end.

apply_co_mounted({ok, Bootstrap, NovaApps}) ->
    %% Set nova's env last so `application:load(nova)` cannot reset it from
    %% the .app, and set it at all because `nova:get_env/2` - the boot path's
    %% own read - keys `nova_apps` off nova's `bootstrap_application`.
    _ = application:load(nova),
    ok = application:set_env(Bootstrap, nova_apps, NovaApps),
    ok = application:set_env(nova, bootstrap_application, Bootstrap);
apply_co_mounted(none) ->
    ok.

%% The release sys_config, from relx config in the host's rebar.config. A
%% plain `.config` consults; a `.src` with templating does not, and falls
%% through to the next candidate or to `none`.
sys_config(State) ->
    Relx = rebar_state:get(State, relx, []),
    Paths = [P || {sys_config, P} <- Relx] ++ [P || {sys_config_src, P} <- Relx],
    first_consultable(Paths).

first_consultable([]) ->
    none;
first_consultable([Path | Rest]) ->
    case filelib:is_regular(Path) andalso file:consult(Path) of
        {ok, [Config]} when is_list(Config) -> {ok, Config};
        _ -> first_consultable(Rest)
    end.

-doc """
`nova`'s `bootstrap_application` and that app's `nova_apps`, the two keys
`nova_sup` uses to build the compiled dispatch, or `none` when the config
names no bootstrap app or an empty `nova_apps`. Pure, so the parse is tested
without a rebar state.
""".
-spec co_mounted_from_config([{atom(), [{atom(), term()}]}]) ->
    {ok, atom(), [atom()]} | none.
co_mounted_from_config(Config) ->
    case proplists:get_value(bootstrap_application, env(nova, Config)) of
        Bootstrap when is_atom(Bootstrap), Bootstrap =/= undefined ->
            case proplists:get_value(nova_apps, env(Bootstrap, Config)) of
                [_ | _] = NovaApps -> {ok, Bootstrap, [App || App <- NovaApps, is_atom(App)]};
                _ -> none
            end;
        _ ->
            none
    end.

%% One app's env from a sys_config, or `[]` - narrowed to a list so the
%% proplist reads above stay well-typed against an untyped config term.
env(App, Config) ->
    case proplists:get_value(App, Config, []) of
        KVs when is_list(KVs) -> KVs;
        _ -> []
    end.

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
    requires := Requires,
    rpc := Rpc,
    lua := Lua,
    routes := Routes
}) ->
    io_lib:format(
        "~s (~s, contract v~b): ~b rpc method(s), ~b lua namespace(s), ~b route(s)~ts",
        [Name, App, Version, map_size(Rpc), map_size(Lua), length(Routes), requires_note(Requires)]
    ).

%% The migration order the report already prints is the boot order a
%% requirement rides, so naming what each extension needs makes an out-of-order
%% or missing dependency legible against the list right above it.
requires_note([]) ->
    ~"";
requires_note(Requires) ->
    io_lib:format(", requires ~ts", [lists:join(~", ", [atom_to_binary(R, utf8) || R <- Requires])]).

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
