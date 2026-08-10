-module(rebar3_asobi_console).
-moduledoc """
`rebar3 asobi console` - compose an operator console out of core's screens and
every installed extension's.

```sh
rebar3 asobi console          # build the composed bundle
rebar3 asobi console --dev    # Vite dev server, proxied at a running node
```

An extension owns its operator UI the way it owns its migrations and its RPC
handlers: as source in its own application, under `priv/console`, with
`index.jsx` as the entry. Nothing is registered and nothing is declared -
discovery is the file being there, the same way migrations and schemas are
discovered rather than declared.

## Why this is a build step and not a runtime load

The console's CSP is `script-src 'nonce-<per-response>'` with no host source
(`m:asobi_console_csp`). A nonce does not propagate to a module's static
imports, so a second chunk fetched at runtime is refused by the browser -
which is why `console/vite.config.js` pins a single chunk in the first place.
Every runtime plugin mechanism there is (dynamic `import()`, module
federation, an import map) needs either `'strict-dynamic'` or a host source in
`script-src`, and the console's strongest property is that even an injected
`<script src>` pointing at its own origin is refused.

So the composition happens where it costs nothing: at build time, producing
one chunk exactly as before, just a larger one. The policy is not touched.

## What it does

1. Runs `asobi_extensions:check/0` - the same validation `rebar3 asobi check`
   runs - so a broken extension set fails here rather than after an npm
   install.
2. Copies asobi's `console/` into `_build/asobi_console`, which is where
   everything generated lives. Neither the asobi dependency nor, when asobi is
   the project itself, its source tree is written to.
3. Symlinks each extension's `priv/console` under `extensions/<name>`, and
   generates `src/registry.generated.js` importing each one.
4. `npm ci` from asobi's own committed lockfile. Extensions have no
   `package.json`, no `node_modules` and no React of their own: they ship JSX
   source, so the whole composed bundle resolves one copy of everything.
5. `vite build` into the `console_bundle_app`'s `priv/console`.

Symlinks rather than absolute paths in the generated imports, with
`resolve.preserveSymlinks` on: it keeps every source file under Vite's root,
which is what makes the dev server able to serve and hot-reload an extension's
JSX. Without `preserveSymlinks` Vite resolves through to the real path, the
file is outside the root again, and the dev server refuses it.

## What the host has to set

In `rebar.config`, the application the built bundle is written into:

```erlang
{asobi, [{console_bundle_app, game_console}]}.
```

and the same name in `sys.config`, which is what makes the node serve it:

```erlang
{asobi, [{console, true}, {console_bundle_app, game_console}]}.
```

Two places because they answer two questions - where the build writes, and
what the node reads - and a release can be built on one machine and configured
on another. `m:asobi_console` refuses a `console_bundle_app` that is not in
the release rather than falling back to asobi's own bundle, so the two
disagreeing is loud.

See `guides/console-extensions.md`.
""".

-behaviour(provider).

-export([init/1, do/1, format_error/1]).

-define(PROVIDER, console).
-define(NAMESPACE, asobi).
%% A manifest is a module, so it has to exist as a beam before `info/0` can be
%% called for the name an extension's screens are keyed by.
-define(DEPS, [{default, compile}]).

-define(WORKSPACE, "asobi_console").
-define(DEFAULT_TARGET, "http://localhost:8082").
-define(DEFAULT_PORT, 5173).

%% Copied into the workspace on every run. `node_modules` is deliberately not
%% in the list: it is expensive, it is not source, and it survives between runs.
-define(SOURCES, ["package.json", "package-lock.json", "vite.config.js", "src"]).

-spec init(term()) -> {ok, term()}.
init(State) ->
    Provider = providers:create([
        {name, ?PROVIDER},
        {namespace, ?NAMESPACE},
        {module, ?MODULE},
        {bare, true},
        {deps, ?DEPS},
        {example, "rebar3 asobi console"},
        {opts, [
            {dev, $d, "dev", boolean,
                "Run the Vite dev server with hot reload instead of building, proxied at a running node"},
            {target, $t, "target", string, "Node the dev server proxies the ops API at (default " ?DEFAULT_TARGET ")"},
            {port, $p, "port", integer, "Port the dev server listens on (default 5173)"},
            {out, $o, "out", string, "Write the bundle here instead of the console_bundle_app's priv/console"},
            {reinstall, undefined, "reinstall", boolean, "Re-run npm ci even when node_modules is present"}
        ]},
        {short_desc, "Build an operator console including every extension's screens"},
        {desc,
            "Composes asobi's own console with the priv/console source of every installed "
            "extension into one bundle, and writes it into the application named by "
            "{asobi, [{console_bundle_app, App}]} in rebar.config. With --dev, runs the Vite "
            "dev server against a live node instead."}
    ]),
    {ok, rebar_state:add_provider(State, Provider)}.

-spec do(term()) -> {ok, term()} | {error, string()}.
do(State) ->
    {Args, _} = rebar_state:command_parsed_args(State),
    Apps = rebar_state:project_apps(State) ++ rebar_state:all_deps(State),
    ok = load_apps(Apps),
    Dirs = app_dirs(Apps),
    maybe
        {ok, Source} ?= console_source(Dirs),
        {ok, Extensions} ?= extensions(Dirs),
        {ok, Out} ?= output(State, Args, Dirs),
        Workspace = workspace(State),
        ok ?= prepare(Source, Workspace),
        ok ?= link_extensions(Workspace, Extensions),
        ok ?= generate(Workspace, Extensions, Out, Args),
        report(Extensions),
        ok ?= install(Workspace, Args),
        ok ?= run(Workspace, Out, Args),
        {ok, State}
    else
        {error, Reason} -> {error, format_error(Reason)}
    end.

-spec format_error(term()) -> string().
format_error({no_console_source, Dir}) ->
    lists:flatten(
        io_lib:format(
            "asobi's console source is not at ~ts. A Hex release older than the one that "
            "added \"console\" to {hex, [{include_files, ...}]} does not ship it; upgrade "
            "asobi, or depend on it from git.",
            [Dir]
        )
    );
format_error(no_asobi) ->
    "asobi is not among this project's applications or dependencies";
format_error(no_output) ->
    "nowhere to write the bundle. Add {asobi, [{console_bundle_app, your_app}]} to rebar.config, "
    "where your_app is an application in this release whose priv/console the node will serve, "
    "or pass --out DIR";
format_error({unknown_output_app, App}) ->
    lists:flatten(
        io_lib:format(
            "console_bundle_app names ~ts, which is not an application in this project. It has "
            "to be one this release builds, because the bundle is written into its priv.",
            [App]
        )
    );
format_error(invalid_extension_set) ->
    "the installed extension set is not valid - see the report above. `rebar3 asobi check` "
    "reports the same thing and is the gate for it";
format_error({symlink_failed, Name, Reason}) ->
    lists:flatten(
        io_lib:format(
            "could not link extension ~ts into the build workspace (~p). The build needs "
            "symlinks; on a filesystem or platform without them, build in a container.",
            [Name, Reason]
        )
    );
format_error({write_failed, Path, Reason}) ->
    lists:flatten(io_lib:format("could not write ~ts (~p)", [Path, Reason]));
format_error({command_failed, Command, Code}) ->
    lists:flatten(io_lib:format("`~ts` exited ~b - its output is above", [Command, Code]));
format_error(Reason) ->
    lists:flatten(io_lib:format("~p", [Reason])).

%%====================================================================
%% Discovery
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

app_dirs(AppInfos) ->
    maps:from_list([
        {binary_to_atom(rebar_app_info:name(AppInfo), utf8), rebar_app_info:dir(AppInfo)}
     || AppInfo <- AppInfos
    ]).

console_source(Dirs) ->
    case maps:find(asobi, Dirs) of
        {ok, Dir} ->
            Source = filename:join(Dir, "console"),
            case filelib:is_regular(filename:join(Source, "package.json")) of
                true -> {ok, Source};
                false -> {error, {no_console_source, Source}}
            end;
        error ->
            {error, no_asobi}
    end.

%% The extension set is validated before anything is copied or installed: a
%% duplicate Lua namespace is cheaper to hear about now than after npm.
extensions(Dirs) ->
    case asobi_extensions:check() of
        {ok, Resolved} ->
            {ok, [Found || Extension <- Resolved, {ok, Found} <- [with_console(Extension, Dirs)]]};
        {error, Problems} ->
            _ = [rebar_api:error("asobi: ~ts", [Line]) || Line <- asobi_extensions:describe(Problems)],
            {error, invalid_extension_set}
    end.

%% Keyed by `info().name`, not by the application name: `/ext/<name>` and the
%% manifest's own `name` field are both the extension's name, and an
%% application called `asobi_quests` serves an extension called `quests`.
with_console(#{app := App, name := Name}, Dirs) ->
    case maps:find(App, Dirs) of
        {ok, Dir} ->
            Console = filename:join([Dir, "priv", "console"]),
            case filelib:is_regular(filename:join(Console, "index.jsx")) of
                true -> {ok, #{app => App, name => atom_to_list(Name), dir => Console}};
                false -> none
            end;
        error ->
            none
    end.

output(State, Args, Dirs) ->
    case proplists:get_value(out, Args) of
        undefined -> configured_output(State, Dirs);
        Path -> {ok, filename:absname(Path)}
    end.

configured_output(State, Dirs) ->
    case proplists:get_value(console_bundle_app, rebar_state:get(State, asobi, [])) of
        undefined ->
            {error, no_output};
        App ->
            case maps:find(App, Dirs) of
                {ok, Dir} -> {ok, filename:join([Dir, "priv", "console"])};
                error -> {error, {unknown_output_app, App}}
            end
    end.

%%====================================================================
%% Workspace
%%====================================================================

workspace(State) ->
    filename:join(rebar_dir:base_dir(State), ?WORKSPACE).

%% Source is copied rather than built in place. Building in the asobi
%% dependency's own directory would put generated files in a tree rebar3 is
%% free to refetch, and when asobi is the project itself it would write into
%% the repository. `node_modules` is left alone, so a rebuild is a copy and a
%% Vite run.
prepare(Source, Workspace) ->
    ok = filelib:ensure_path(Workspace),
    _ = rebar_file_utils:rm_rf(filename:join(Workspace, "src")),
    Copied = [filename:join(Source, Name) || Name <- ?SOURCES],
    rebar_file_utils:cp_r(Copied, Workspace),
    ok.

link_extensions(Workspace, Extensions) ->
    Root = filename:join(Workspace, "extensions"),
    %% Rebuilt from nothing each run, so an extension dropped from the release
    %% cannot linger as a stale link and end up in the bundle.
    _ = rebar_file_utils:rm_rf(Root),
    ok = filelib:ensure_path(Root),
    link_each(Root, Extensions).

link_each(_Root, []) ->
    ok;
link_each(Root, [#{name := Name, dir := Dir} | Rest]) ->
    case file:make_symlink(Dir, filename:join(Root, Name)) of
        ok -> link_each(Root, Rest);
        {error, Reason} -> {error, {symlink_failed, Name, Reason}}
    end.

%%====================================================================
%% Generated files
%%====================================================================

generate(Workspace, Extensions, Out, Args) ->
    maybe
        ok ?= write(filename:join([Workspace, "src", "registry.generated.js"]), registry(Extensions)),
        ok ?= write(filename:join(Workspace, "vite.host.config.js"), host_config(Out, Args)),
        ok ?= write(filename:join(Workspace, "index.html"), dev_document()),
        ok
    end.

write(Path, Contents) ->
    case file:write_file(Path, unicode:characters_to_binary(Contents)) of
        ok -> ok;
        {error, Reason} -> {error, {write_failed, Path, Reason}}
    end.

registry(Extensions) ->
    [
        "// Generated by `rebar3 asobi console`. Do not edit and do not commit.\n",
        "//\n",
        "// One static import per installed extension that ships priv/console. Static\n",
        "// because the console is one chunk: the CSP's nonce does not reach a\n",
        "// dynamically imported module, so a lazily loaded screen would be refused by\n",
        "// the browser rather than merely arriving late.\n",
        [io_lib:format("import ~ts from '../extensions/~ts/index.jsx';\n", [alias(Name), Name]) ||
            #{name := Name} <- Extensions],
        "\nexport const extensions = [",
        lists:join(", ", [alias(Name) || #{name := Name} <- Extensions]),
        "];\n"
    ].

%% `info().name` is already a lowercase atom that is a legal identifier - the
%% extension registry refuses anything else - so the import binding is the name
%% with one prefix to keep it away from anything this module might add later.
alias(Name) ->
    "ext_" ++ Name.

host_config(Out, Args) ->
    [
        "// Generated by `rebar3 asobi console`. Do not edit and do not commit.\n",
        "import base from './vite.config.js';\n\n",
        "export default {\n",
        "  ...base,\n",
        "  // Extensions are symlinked under extensions/. Resolving through the link\n",
        "  // would put their source outside Vite's root, and the dev server refuses to\n",
        "  // serve what is outside its root.\n",
        "  resolve: { ...base.resolve, preserveSymlinks: true },\n",
        "  build: { ...base.build, outDir: ", quote(Out), " },\n",
        "  server: {\n",
        "    port: ", integer_to_list(proplists:get_value(port, Args, ?DEFAULT_PORT)), ",\n",
        "    strictPort: true,\n",
        "    // Same-origin through the proxy, so config.js reads no api base and takes\n",
        "    // the same path a self-hosted node takes. cookieDomainRewrite is what lets\n",
        "    // the node's HttpOnly session cookie survive the hop to localhost.\n",
        "    proxy: {\n",
        "      '/api/v1/ops': ", proxy(Args), ",\n",
        "      '/console/session': ", proxy(Args), ",\n",
        "    },\n",
        "  },\n",
        "};\n"
    ].

proxy(Args) ->
    Target = proplists:get_value(target, Args, ?DEFAULT_TARGET),
    ["{ target: ", quote(Target), ", changeOrigin: true, cookieDomainRewrite: 'localhost' }"].

%% The build emits no document - `asobi_console_shell` renders it, because the
%% nonce and the api base are only knowable per response. The dev server has
%% neither, and needs a document, so it gets this one. It is never built and
%% never served by a node.
dev_document() ->
    [
        "<!doctype html>\n<html lang=\"en\">\n<head>\n",
        "<meta charset=\"utf-8\">\n",
        "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n",
        "<title>asobi ops (dev)</title>\n",
        "</head>\n<body>\n<div id=\"root\"></div>\n",
        "<script type=\"module\" src=\"/src/main.jsx\"></script>\n",
        "</body>\n</html>\n"
    ].

quote(Value) ->
    ["'", string:replace(Value, "'", "\\'", all), "'"].

%%====================================================================
%% npm and Vite
%%====================================================================

%% `npm ci` removes node_modules and reinstalls from the lockfile every time it
%% runs, so it is run once and then only when asked for. The lockfile is
%% asobi's own, which is what makes the composed bundle as reproducible as the
%% one this repository commits.
install(Workspace, Args) ->
    Present = filelib:is_dir(filename:join(Workspace, "node_modules")),
    case Present andalso proplists:get_value(reinstall, Args, false) =/= true of
        true -> ok;
        false -> sh("npm ci", Workspace)
    end.

run(Workspace, Out, Args) ->
    case proplists:get_value(dev, Args, false) of
        true ->
            Port = integer_to_list(proplists:get_value(port, Args, ?DEFAULT_PORT)),
            Target = proplists:get_value(target, Args, ?DEFAULT_TARGET),
            rebar_api:info("asobi: dev server on http://localhost:~ts, ops API proxied at ~ts", [Port, Target]),
            sh("npx vite --config vite.host.config.js", Workspace);
        false ->
            case sh("npx vite build --config vite.host.config.js", Workspace) of
                ok ->
                    rebar_api:info("asobi: console written to ~ts", [Out]),
                    ok;
                Error ->
                    Error
            end
    end.

sh(Command, Dir) ->
    case rebar_utils:sh(Command, [{cd, Dir}, {use_stdout, true}, return_on_error]) of
        {ok, _Output} -> ok;
        {error, {Code, _Output}} -> {error, {command_failed, Command, Code}}
    end.

%%====================================================================
%% Reporting
%%====================================================================

report([]) ->
    rebar_api:warn(
        "asobi: no installed extension ships priv/console, so this bundle is core's screens "
        "only - which is what the committed one in asobi's own priv already is",
        []
    );
report(Extensions) ->
    rebar_api:info("asobi: composing the console with ~b extension(s)", [length(Extensions)]),
    _ = [rebar_api:info("  ~ts (~ts)", [Name, App]) || #{name := Name, app := App} <- Extensions],
    ok.
