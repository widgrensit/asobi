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
- **rpc** from the domains of `asobi_error:codes/0`, plus the Lua namespaces.
  An RPC prefix and an error domain are the same token by construction
  (`{"code": "quests.name_taken"}`), so an extension owning the `storage`
  prefix would mint codes inside core's closed code set.

Deriving from modules costs one `code:ensure_loaded/1` sweep over core's
module list. `asobi_extensions` only asks for it when at least one extension
is installed, so a node with none pays nothing.
""".

-export([namespaces/0, kinds/0]).

-type kind() :: tables | rpc | lua | queues.
-export_type([kind/0]).

-doc "The namespace kinds an extension may claim in `owns/0`.".
-spec kinds() -> [kind(), ...].
kinds() ->
    [tables, rpc, lua, queues].

-doc "Core's reserved token set, per namespace kind.".
-spec namespaces() -> #{kind() := [asobi_extension:token()]}.
namespaces() ->
    Modules = core_modules(),
    Lua = lua(),
    #{
        tables => exported_values(Modules, table, {fields, 0}),
        queues => exported_values(Modules, queue, {perform, 1}),
        lua => Lua,
        rpc => lists:usort(error_domains() ++ Lua)
    }.

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
    lists:usort([Domain || Code <- asobi_error:codes(), Domain <- domain(Code)]).

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
