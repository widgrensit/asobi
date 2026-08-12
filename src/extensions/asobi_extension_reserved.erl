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
- **rpc** from the domains of `asobi_error:core_codes/0`, plus the Lua
  namespaces. An RPC prefix and an error domain are the same token by
  construction (`{"code": "quests.name_taken"}`), so an extension owning the
  `storage` prefix would mint codes inside core's closed code set.

  `core_codes/0` rather than `codes/0` on purpose: `codes/0` includes the codes
  the installed extensions declare, and reserving those would tell an extension
  it may not claim the namespace it just claimed.
- **http** from core's own route table, via `asobi_router:core_routes/0` -
  the core groups without the extension mounts, because this runs inside
  `asobi_extensions:resolve/0` and reading the full table there would re-enter
  the resolver before its term exists. A path core serves can never be
  re-served, or shadowed under a binding, by an extension.

Deriving from modules costs one `code:ensure_loaded/1` sweep over core's
module list. `asobi_extensions` only asks for it when at least one extension
is installed, so a node with none pays nothing.

`schema_tables/1` and `worker_queues/1` are the two derivation rules
themselves, exported over an arbitrary module list. `asobi_extensions` runs
them over an **extension's** modules to derive that extension's table and queue
claims, so core's names and an extension's names are found by the same rule
rather than by two that can disagree.
""".

-export([namespaces/0, kinds/0, schema_tables/1, worker_queues/1]).

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
        rpc => lists:usort(error_domains() ++ Lua),
        http => core_route_paths()
    }.

%% Every path core's own table serves, prefixed as it is mounted. The one
%% protocol route (`/ws`) carries no methods key and is still a path claim.
core_route_paths() ->
    lists:usort([
        <<Prefix/binary, Path/binary>>
     || #{prefix := Prefix, routes := Routes} <- asobi_router:core_routes(),
        {Path, _Handler, _Options} <- Routes
    ]).

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
