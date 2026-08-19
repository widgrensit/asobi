-module(asobi_extension_reserved).
-moduledoc """
The names core keeps for itself.

`asobi_extensions:validate/1` refuses an `owns/0` claim on anything in here,
so an extension cannot shadow a core table, a core Lua namespace, a core error
domain or a core job queue.

Every list is derived from the live core source rather than restated, so it
cannot drift:

- **lua** from `asobi_lua_surface:reserved_namespaces/0`, the one place the
  `game.*` vocabulary is written down.
- **tables** from every core `kura_schema` module's `table/0`, found the same
  way asobi finds an extension's schemas.
- **queues** from every core `shigoto_worker` module's `queue/0`.
- **rpc** from the domains of `asobi_error:core_codes/0`, the Lua namespaces,
  and `core_wire_prefixes/0`. An RPC prefix and an error domain are the same
  token by construction (`{"code": "quests.name_taken"}`), so an extension
  owning the `storage` prefix would mint codes inside core's closed code set.
  `core_wire_prefixes/0` adds the wire frame families a code domain and a Lua
  namespace between them miss - `session`, `presence` and `module` - so an
  extension can neither mint a `session.*` code nor emit a `session.connected`
  event under `asobi_extensions:emit/4`.

  `core_codes/0` rather than `codes/0` on purpose: `codes/0` includes the codes
  the installed extensions declare, and reserving those would tell an extension
  it may not claim the namespace it just claimed.
- **http** from the route tables of every co-mounted application - the same
  list Nova compiles, `[nova, asobi | nova_apps]` - so `/health`, `/ready`
  and `/live` (served by `nova_resilience` in both shipped configs) are as
  unclaimable as core's own paths. asobi's table comes from
  `asobi_router:core_routes/0`, the groups without the extension mounts,
  because this runs inside `asobi_extensions:resolve/0` and reading the full
  table there would re-enter the resolver before its term exists; every
  other app's comes from its `<app>_router:routes/1`. A path any co-mounted
  app serves can never be re-served, or shadowed under a binding, by an
  extension.

On top of the derived set, `route_prefixes/0` names the privileged plane
roots (`/api/v1/ops`, `/api/v1/auth`, `/api/v1/iap`, `/api/v1/rpc`, `/console`,
`/ws`): no extension route may sit anywhere under them, whatever it would
resolve to. This is a policy list, not a derivation - which sub-paths of a
plane are sensitive is a judgment the route table cannot express.

`core_capabilities/0` answers the mirror-image question `owns/0` does not:
not "what may an extension never claim" but "what may an extension depend on".
A subsystem name here can be named in `requires/0` yet never in `owns/0` - you
may call into `economy`, never claim its namespace - so the two roles sit in
one module because both are the authority on core's own subsystem names.

Deriving from modules costs one `code:ensure_loaded/1` sweep over core's
module list. `asobi_extensions` only asks for it when at least one extension
is installed, so a node with none pays nothing.

`schema_tables/1` and `worker_queues/1` are the two derivation rules
themselves, exported over an arbitrary module list. `asobi_extensions` runs
them over an **extension's** modules to derive that extension's table and queue
claims, so core's names and an extension's names are found by the same rule
rather than by two that can disagree.
""".

-export([
    namespaces/0,
    kinds/0,
    route_prefixes/0,
    core_capabilities/0,
    core_wire_prefixes/0,
    schema_tables/1,
    worker_queues/1
]).

-type kind() :: tables | rpc | lua | queues | http.
-export_type([kind/0]).

-doc "The namespace kinds an extension may claim in `owns/0`.".
-spec kinds() -> [kind(), ...].
kinds() ->
    [tables, rpc, lua, queues, http].

-doc "Core's reserved token set, per namespace kind.".
-spec namespaces() -> #{kind() := [asobi_extension:token()]}.
namespaces() ->
    Modules = core_modules(),
    Lua = lua(),
    #{
        tables => schema_tables(Modules),
        queues => worker_queues(Modules),
        lua => Lua,
        rpc => lists:usort(error_domains() ++ Lua ++ core_wire_prefixes()),
        http => core_route_paths()
    }.

-doc """
The privileged plane roots. No extension route may sit anywhere under one -
mounting an open webhook handler inside the operator, auth, purchase,
extension-rpc, console or socket plane is refused whatever the path would
resolve to. `/api/v1/rpc` is the core rpc dispatcher's own HTTP route
(`m:asobi_rpc_controller`), reserved so an extension cannot shadow the frozen
`POST /api/v1/rpc/<method>` surface through its `routes/0`.
""".
-spec route_prefixes() -> [asobi_extension:token(), ...].
route_prefixes() ->
    [~"/api/v1/ops", ~"/api/v1/auth", ~"/api/v1/iap", ~"/api/v1/rpc", ~"/console", ~"/ws"].

-doc """
The core subsystem names an extension may name in `requires/0`.

A documented constant, not a derivation, and deliberately so. The names an
extension depends on are the extraction-unit names - the one each subsystem
carries out of core as its own package, so `asobi_leaderboards`'s
`info().name` is `leaderboards` - and no single core artefact spells that set:
the `game.*` Lua namespaces are singular and partial (`leaderboard`, no
`world` or `tournaments` at all) and the error-code domains mix machinery in.
So the set is written here, one atom per subsystem, tied to its `src/`
directory and its extraction wave. It has two groups: the extraction-unit
names, each of which becomes an extension of exactly that name; and the
kernel-permanent runtime subsystems an extension may call into but that never
leave core (`matches`, `world`, `votes`, `presence`, `timers`). Only the first
group moves.

The resolution set `asobi_extensions` validates a `requires/0` against is the
union of this set and the installed extensions' own names, and that union is
why the set stays correct across an extraction: when a subsystem leaves core
its atom is deleted here and reappears as the extracted package's
`info().name`, so a `requires` on it moves from the core side of the union to
the extension side with the same answer - satisfied, because the bundle
installs the package. Sub-parts are named by the unit that extracts, never
separately: use `economy` for inventory, `chat` for dm, `matches` for the
matchmaker or match-scoped zones, `world` for world zones and terrain.
""".
-spec core_capabilities() -> [asobi_extension:name(), ...].
core_capabilities() ->
    [
        %% Extraction targets - each becomes an extension named exactly this.
        storage,
        iap,
        notifications,
        leaderboards,
        economy,
        tournaments,
        social,
        chat,
        %% Kernel-permanent subsystems - callable, never extracted.
        matches,
        world,
        votes,
        presence,
        timers
    ].

-doc """
The core wire frame-family prefixes with no error domain and no Lua namespace.

`error_domains/0` and `lua/0` between them cover most core wire frame families -
`match.*`, `world.*`, `chat.*`, `matchmaker.*` and the rest all have an error
code or a `game.*` namespace under the same prefix. Three do not:

- `session` (`session.connected`, `session.heartbeat`),
- `presence` (`presence.updated`),
- `module` (`module.message`, `module.error`, `module.event`, the frames an
  extension pushes - the last through `asobi_extensions:emit/4`).

An RPC prefix, an error-code domain and an event domain are one token by
construction, so without reserving these an extension could own `session` in
`owns/0` and mint a `session.*` code or emit a `session.connected` event,
colliding with a core frame family. This constant is a documented list rather
than a derivation precisely because no core artefact names these prefixes -
they exist only as wire type literals in `m:asobi_ws_handler`. Folded into the
reserved `rpc` union, so the gap closes for error codes and the `module.event`
event seam alike.
""".
-spec core_wire_prefixes() -> [asobi_extension:token(), ...].
core_wire_prefixes() ->
    [~"session", ~"presence", ~"module"].

%% Every path any co-mounted application serves, prefixed as it is mounted.
%% The compiled dispatch is `[nova, BootstrapApp | nova_apps]` (nova_sup),
%% and in routing_tree the FIRST insert of a path wins, so an extension claim
%% on a later app's path (nova_resilience's /health) would silently hijack
%% it. `nova:get_env/2` reads the bootstrap application's env, which is
%% exactly where nova_sup reads `nova_apps` from.
core_route_paths() ->
    lists:usort([
        Path
     || App <- co_mounted_apps(),
        Group <- app_route_groups(App),
        Path <- group_paths(Group)
    ]).

co_mounted_apps() ->
    NovaApps =
        case nova:get_env(nova_apps, []) of
            Apps when is_list(Apps) -> [App || App <- Apps, is_atom(App)];
            _ -> []
        end,
    [nova, asobi | NovaApps].

%% asobi through `core_routes/0` - its full `routes/1` resolves extensions,
%% and this runs inside the resolver. Everything else through its Nova router
%% module, found by name in the app's own module list (the manifest-module
%% rule, so no atom is ever created from config data) and called exactly as
%% `nova_router:compile/3` calls it.
app_route_groups(asobi) ->
    asobi_router:core_routes();
app_route_groups(App) ->
    _ = application:load(App),
    Name = atom_to_list(App) ++ "_router",
    lists:append([
        Module:routes(nova:get_environment())
     || Module <- app_modules(App),
        atom_to_list(Module) =:= Name,
        code:ensure_loaded(Module) =:= {module, Module},
        erlang:function_exported(Module, routes, 1)
    ]).

app_modules(App) ->
    case application:get_key(App, modules) of
        {ok, Modules} -> Modules;
        undefined -> []
    end.

%% Total over every route shape Nova compiles: a path entry is a claim, a
%% status-code entry claims nothing, and anything else - a static-file
%% 2-tuple, a non-binary prefix - raises rather than silently reserving
%% nothing. A hole here is a hijackable path, so unrecognised means loud.
group_paths(#{routes := Routes} = Group) ->
    case maps:get(prefix, Group, ~"") of
        Prefix when is_binary(Prefix) ->
            lists:append([entry_paths(Prefix, Entry) || Entry <- Routes]);
        _ ->
            error({asobi_unrecognised_core_route_group, Group})
    end;
group_paths(Group) ->
    error({asobi_unrecognised_core_route_group, Group}).

entry_paths(Prefix, {Path, _Handler, _Options}) when is_binary(Path) ->
    [<<Prefix/binary, Path/binary>>];
entry_paths(_Prefix, {Status, _Handler, _Options}) when is_integer(Status) ->
    [];
entry_paths(Prefix, Entry) ->
    error({asobi_unrecognised_core_route, Prefix, Entry}).

-doc "Every table declared by a `kura_schema` module in this list.".
-spec schema_tables([module()]) -> [asobi_extension:token()].
schema_tables(Modules) ->
    exported_values(Modules, table, {fields, 0}).

-doc "Every queue declared by a `shigoto_worker` module in this list.".
-spec worker_queues([module()]) -> [asobi_extension:token()].
worker_queues(Modules) ->
    exported_values(Modules, queue, {perform, 1}).

lua() ->
    lists:usort([
        Namespace
     || Path <- asobi_lua_surface:reserved_namespaces(),
        Namespace <- lua_namespace(Path)
    ]).

%% `game` itself is reserved: an extension owning it would claim the root
%% table every other namespace hangs off.
lua_namespace([~"game"]) -> [~"game"];
lua_namespace([~"game", Namespace]) -> [Namespace];
lua_namespace(_) -> [].

error_domains() ->
    lists:usort([Domain || Code <- asobi_error:core_codes(), Domain <- domain(Code)]).

domain(Code) ->
    case binary:split(Code, ~".") of
        [Domain, _] -> [Domain];
        _ -> []
    end.

%% An empty module list would silently reserve nothing, which is worse than a
%% crash: an extension could then claim `players` and the check would pass.
core_modules() ->
    _ = application:load(asobi),
    case application:get_key(asobi, modules) of
        {ok, [_ | _] = Modules} -> Modules;
        Other -> error({asobi_core_modules_unavailable, Other})
    end.

%% Every core module exporting Fun/0 alongside its companion - the pair that
%% identifies a kura schema (`table/0` + `fields/0`) or a shigoto worker
%% (`queue/0` + `perform/1`) - contributes Fun().
exported_values(Modules, Fun, {Companion, Arity}) ->
    lists:usort([
        Module:Fun()
     || Module <- Modules,
        code:ensure_loaded(Module) =:= {module, Module},
        erlang:function_exported(Module, Fun, 0),
        erlang:function_exported(Module, Companion, Arity)
    ]).
