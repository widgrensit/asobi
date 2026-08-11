-module(asobi_extensions).
-moduledoc """
The extension registry: a pure memoised function, not a process.

`resolve/0` loads the host's application closure, discovers every application
exporting an `<app>_extension` module, reads its manifest, validates the set
and writes the result to `persistent_term`. Whoever calls first pays for it;
everybody after reads a term.

It cannot be a process, and this is the constraint that decides the shape.
`nova` is in asobi's `applications` list, so OTP starts Nova first, and
`nova_sup:init/1` calls `setup_cowboy/1` -> `nova_router:compile/1` ->
`asobi_router:routes/1` **before `asobi_app:start/2` ever runs**. The router
is therefore the first caller, and at that moment no asobi process exists.
A registry gen_server, a supervised child or a step in an asobi boot sequence
would all be populated after the route table was already compiled.

Its callers, in boot order:

1. `asobi_router:routes/1`, inside Nova's boot.
2. `asobi_app:start/2`, before migrations.
3. `asobi_repo:migration_apps/0`, when kura discovers migrations.

Discovery walks the **OTP application graph**, not Nova's `nova_apps`.
`nova_apps` only sees Nova apps, so a Lua-only or jobs-only extension would be
invisible, and Nova's own `resolve_nova_apps` reverses its accumulator at
every nesting level so its output is neither depth-first nor declaration
order. `application:get_key(App, applications)` is the authoritative start
order, and the closure walk emits each application after everything it
depends on, so the discovered list is already topologically ordered with ties
in the host's declaration order. Nothing sorts it afterwards.

Core loads the closure before discovering. In a release every application is
loaded by the boot script before any start; under `rebar3 shell` and CT they
load lazily, and without the sweep the discovered set would differ between
dev and prod with no error.

`rebar3 asobi check` is the primary gate and runs `check/0`, the same
function, without memoising. Boot validation is a backstop, and it is a
backstop specifically because a failure raised from inside `nova_sup:init/1`
surfaces with Nova's crash context rather than a legible asobi error.
""".

-include_lib("kernel/include/logger.hrl").

-export([resolve/0, check/0, validate/1, describe/1, sup_specs/1, error_codes/0]).
-export([rpc_methods/0, lua_bindings/0, ops_action/2]).
-ifdef(TEST).
-export([reset/0]).
-endif.

-define(KEY, {?MODULE, resolved}).
-define(CODES_KEY, {?MODULE, error_codes}).
-define(RPC_KEY, {?MODULE, rpc_methods}).
-define(LUA_KEY, {?MODULE, lua_bindings}).
-define(OPS_KEY, {?MODULE, ops_actions}).

-doc "One resolved extension. `sup/0` is deliberately absent; see `sup_specs/1`.".
-type extension() :: #{
    app := atom(),
    module := module(),
    name := asobi_extension:name(),
    extension_version := pos_integer(),
    rpc := asobi_extension:rpc(),
    ops := asobi_extension:ops(),
    lua := asobi_extension:lua(),
    owns := asobi_extension:owns(),
    codes := asobi_extension:codes()
}.

-type problem() ::
    {bad_manifest, atom(), module(), term()}
    | {duplicate_name, asobi_extension:name(), atom(), atom()}
    | {namespace_conflict, asobi_extension_reserved:kind(), asobi_extension:token(), atom(), atom()}
    | {reserved_namespace, asobi_extension_reserved:kind(), asobi_extension:token(), atom()}
    | {undeclared_claim, asobi_extension_reserved:kind(), asobi_extension:token(), atom()}.

-doc "One `lua/0` binding with the namespace and function name it was declared under.".
-type binding() :: #{
    namespace := asobi_extension:lua_namespace(),
    function := binary(),
    mfa := mfa(),
    args := [asobi_extension:lua_arg()],
    effects := asobi_lua_surface:effect(),
    vms := [asobi_lua_surface:vm_kind()]
}.

-export_type([extension/0, problem/0, binding/0]).

-doc """
The installed extensions, in dependency order. Memoised.

Raises `{asobi_extensions, Problems}` on an invalid set, after logging the
same problems in prose. A node that cannot say which extension owns a
namespace must not serve traffic under either.
""".
-spec resolve() -> [extension()].
resolve() ->
    case persistent_term:get(?KEY, undefined) of
        undefined ->
            Extensions = resolve_now(),
            persistent_term:put(?CODES_KEY, error_code_table(Extensions)),
            persistent_term:put(?RPC_KEY, rpc_table(Extensions)),
            persistent_term:put(?LUA_KEY, lua_table(Extensions)),
            persistent_term:put(?OPS_KEY, ops_table(Extensions)),
            persistent_term:put(?KEY, Extensions),
            Extensions;
        Extensions ->
            Extensions
    end.

-doc """
Every error code the installed extensions mint, as `Code => {Status, Message}`.

`asobi_error` reads this rather than resolving, so building an error object
never triggers discovery and never raises: before `resolve/0` has run there
are no extension codes, and `resolve/0` runs inside Nova's boot, long before
any request can fail.
""".
-spec error_codes() -> #{asobi_error:code() => {pos_integer(), binary()}}.
error_codes() ->
    persistent_term:get(?CODES_KEY, #{}).

-doc """
Every RPC method the installed extensions declare, as `Method => {M, F, A}`.

`m:asobi_rpc` reads this rather than resolving, for the same reason
`error_codes/0` exists: dispatch is on a request path and must never trigger
discovery. Before `resolve/0` has run the table is empty, and `resolve/0` runs
inside Nova's boot, long before a socket exists.

Methods cannot collide across extensions. A method's prefix is a derived `rpc`
claim, and `validate/1` refuses two extensions claiming one prefix, so
flattening the declared maps together cannot lose an entry.
""".
-spec rpc_methods() -> #{asobi_extension:method() => mfa()}.
rpc_methods() ->
    persistent_term:get(?RPC_KEY, #{}).

-doc """
Every `game.<ns>.<fn>` binding the installed extensions declare, flattened.

`m:asobi_lua_api` filters this by the VM kind it is installing into and
installs what remains. Flat rather than nested because every consumer wants
one pass over bindings, not a walk over namespaces.
""".
-spec lua_bindings() -> [binding()].
lua_bindings() ->
    persistent_term:get(?LUA_KEY, []).

-doc """
The operator action `Extension` declares as `Action`, or `undefined`.

Read on two request paths - the capability check in `m:asobi_ops_caps` and the
dispatch in `m:asobi_ops_extension` - so like `rpc_methods/0` it reads the
memoised table and never triggers discovery. `undefined` for an extension that
is not installed and for an action it does not declare, which is one answer
because they are one outcome: nothing to route to, and nothing to authorise.
""".
-spec ops_action(binary(), binary()) -> asobi_extension:ops_entry() | undefined.
ops_action(Extension, Action) ->
    maps:get({Extension, Action}, persistent_term:get(?OPS_KEY, #{}), undefined).

%% The codes term is written before the resolved term, so a concurrent second
%% caller that sees ?KEY populated also sees the codes it implies.
error_code_table(Extensions) ->
    maps:from_list([
        {Code, {Status, Message}}
     || #{codes := Codes} <- Extensions,
        Code := #{status := Status, message := Message} <- Codes
    ]).

rpc_table(Extensions) ->
    maps:from_list([{Method, Target} || #{rpc := Rpc} <- Extensions, Method := Target <- Rpc]).

ops_table(Extensions) ->
    maps:from_list([
        {{atom_to_binary(Name, utf8), Action}, Entry}
     || #{name := Name, ops := Ops} <- Extensions, Action := Entry <- Ops
    ]).

lua_table(Extensions) ->
    [
        Binding#{namespace => Namespace, function => Function}
     || #{lua := Lua} <- Extensions,
        Namespace := Functions <- Lua,
        Function := Binding <- Functions
    ].

%% Two concurrent first callers both compute and both write. The computation
%% is a pure function of the loaded application set, so they write the same
%% term and the race has no observable effect.
resolve_now() ->
    case check() of
        {ok, Extensions} ->
            Extensions;
        {error, Problems} ->
            ?LOG_ERROR(#{
                msg => ~"extension_validation_failed",
                problems => describe(Problems)
            }),
            error({asobi_extensions, Problems})
    end.

-doc """
Discover, read and validate without memoising.

The build-time gate (`rebar3 asobi check`) and the boot backstop run exactly
this, so the two can never disagree.
""".
-spec check() -> {ok, [extension()]} | {error, [problem(), ...]}.
check() ->
    case read(discover()) of
        {ok, []} ->
            {ok, []};
        {ok, Extensions} ->
            case validate(Extensions) of
                ok -> {ok, Extensions};
                {error, _} = Error -> Error
            end;
        {error, _} = Error ->
            Error
    end.

-doc """
The child specs an extension wants asobi to supervise.

Called from `asobi_extension_child_sup:init/1` rather than cached, so the
running code always decides.
""".
-spec sup_specs(module()) -> [supervisor:child_spec()].
sup_specs(Module) ->
    case erlang:function_exported(Module, sup, 0) of
        true -> Module:sup();
        false -> []
    end.

-ifdef(TEST).
-spec reset() -> ok.
reset() ->
    _ = persistent_term:erase(?KEY),
    _ = persistent_term:erase(?OPS_KEY),
    _ = persistent_term:erase(?CODES_KEY),
    _ = persistent_term:erase(?RPC_KEY),
    _ = persistent_term:erase(?LUA_KEY),
    ok.
-endif.

%%====================================================================
%% Discovery
%%====================================================================

discover() ->
    [
        {App, Module}
     || App <- closure(),
        App =/= asobi,
        {true, Module} <- [manifest_module(App)]
    ].

%% The dependency-closure test is an optimisation only: asobi_lua, asobi_engine
%% and asobi_admin all have asobi in their closure and none is an extension.
%% Exporting `<app>_extension` is the filter.
manifest_module(App) ->
    Name = atom_to_list(App) ++ "_extension",
    case [M || M <- modules(App), atom_to_list(M) =:= Name] of
        [Module] -> {true, Module};
        _ -> false
    end.

modules(App) ->
    case application:get_key(App, modules) of
        {ok, Modules} -> Modules;
        undefined -> []
    end.

deps(App) ->
    case application:get_key(App, applications) of
        {ok, Applications} when is_list(Applications) -> Applications;
        _ -> []
    end.

%% Post-order over the application graph: an application is emitted after
%% everything it depends on, which is OTP's own start order. Loading happens
%% in the same walk because an application's `applications` key is unreadable
%% until it is loaded.
closure() ->
    {_Seen, Reversed} = walk(roots(), sets:new(), []),
    lists:reverse(Reversed).

walk([], Seen, Acc) ->
    {Seen, Acc};
walk([App | Rest], Seen, Acc) ->
    case sets:is_element(App, Seen) of
        true ->
            walk(Rest, Seen, Acc);
        false ->
            _ = application:load(App),
            {Seen1, Acc1} = walk(deps(App), sets:add_element(App, Seen), Acc),
            walk(Rest, Seen1, [App | Acc1])
    end.

%% The bootstrap application leads, because it is the host - the only thing
%% that depends on both asobi and its extensions - and its `applications` list
%% is the host's declaration order.
roots() ->
    bootstrap() ++ lists:sort([App || {App, _Desc, _Vsn} <- application:loaded_applications()]).

bootstrap() ->
    case application:get_env(nova, bootstrap_application) of
        {ok, App} when is_atom(App) -> [App];
        _ -> []
    end.

%%====================================================================
%% Reading manifests
%%====================================================================

read(Pairs) ->
    Results = [read_one(App, Module) || {App, Module} <- Pairs],
    case lists:append([Problems || {error, Problems} <- Results]) of
        [] -> {ok, [Extension || {ok, Extension} <- Results]};
        Problems -> {error, Problems}
    end.

read_one(App, Module) ->
    case code:ensure_loaded(Module) of
        {module, Module} -> read_manifest(App, Module);
        {error, What} -> {error, [{bad_manifest, App, Module, {unloadable, What}}]}
    end.

read_manifest(App, Module) ->
    Reads = [
        {info, call(Module, info, undefined)},
        {rpc, call(Module, rpc, #{})},
        {lua, call(Module, lua, #{})},
        {owns, call(Module, owns, #{})},
        {codes, call(Module, codes, #{})},
        {ops, call(Module, ops, #{})},
        {sup, call(Module, sup, [])}
    ],
    case [{Key, Detail} || {Key, {error, Detail}} <- Reads] of
        [] ->
            Values = maps:from_list([{Key, Value} || {Key, {ok, Value}} <- Reads]),
            build(App, Module, Values);
        Failed ->
            {error, [{bad_manifest, App, Module, {Key, Detail}} || {Key, Detail} <- Failed]}
    end.

call(Module, Function, Default) ->
    case erlang:function_exported(Module, Function, 0) of
        false ->
            {ok, Default};
        true ->
            try
                {ok, Module:Function()}
            catch
                Class:Reason -> {error, {raised, Class, Reason}}
            end
    end.

build(App, Module, Values) ->
    #{
        info := Info,
        rpc := Rpc,
        lua := Lua,
        owns := Owns,
        codes := Codes,
        ops := Ops,
        sup := Sup
    } = Values,
    case shape_problems(Info, Rpc, Lua, Owns, Codes, Ops, Sup) of
        [] ->
            #{name := Name, extension_version := Version} = Info,
            {ok, #{
                app => App,
                module => Module,
                name => Name,
                extension_version => Version,
                rpc => Rpc,
                lua => Lua,
                owns => Owns,
                codes => Codes,
                ops => Ops
            }};
        Details ->
            {error, [{bad_manifest, App, Module, Detail} || Detail <- Details]}
    end.

shape_problems(Info, Rpc, Lua, Owns, Codes, Ops, Sup) ->
    info_problems(Info) ++
        rpc_problems(Rpc) ++
        lua_problems(Lua) ++
        owns_problems(Owns) ++
        codes_problems(Codes) ++
        ops_problems(Ops) ++
        sup_problems(Sup).

info_problems(#{name := Name, extension_version := Version}) when
    is_atom(Name), Name =/= undefined, is_integer(Version), Version > 0
->
    name_problems(Name);
info_problems(Info) ->
    [{info, ~"must be #{name := atom(), extension_version := pos_integer()}", Info}].

%% The name is a path segment in `/ext/<name>`, a symlink under the console
%% build workspace, and a JavaScript import binding in the generated registry.
%% Holding it to an identifier here is what lets each of those interpolate it
%% without escaping, and it is the same shape the console's own registry
%% applies to a manifest before it renders one.
name_problems(Name) ->
    case re:run(atom_to_binary(Name, utf8), ~"^[a-z][a-z0-9_]*$", [{capture, none}]) of
        match -> [];
        nomatch -> [{info, ~"name must match ^[a-z][a-z0-9_]*$", Name}]
    end.

rpc_problems(Rpc) when is_map(Rpc) ->
    [
        {rpc, ~"method must be <prefix>.<method> mapped to {Module, Function, 2}", Method}
     || Method := Target <- Rpc, not is_rpc_entry(Method, Target)
    ];
rpc_problems(Rpc) ->
    [{rpc, ~"must be a map", Rpc}].

%% Arity 2 and nothing else: `m:asobi_rpc` applies every target as
%% `Module:Function(Params, Ctx)`, so a handler declared at any other arity
%% cannot be called at all. Refusing it here makes that a build failure rather
%% than a 500 the first time a client tries the method.
is_rpc_entry(Method, {M, F, 2}) when is_atom(M), is_atom(F) ->
    is_dotted(Method);
is_rpc_entry(_Method, _Target) ->
    false.

ops_problems(Ops) when is_map(Ops) ->
    [
        {ops, ~"action must map to #{method, mfa => {Module, Function, 2}, class}", Action}
     || Action := Entry <- Ops, not is_ops_entry(Action, Entry)
    ];
ops_problems(Ops) ->
    [{ops, ~"must be a map", Ops}].

%% The action is one path segment, so it may not carry a slash or a dot: the
%% router splits on the first and the console builds links from the second.
%% Arity 2 for the same reason `rpc/0` insists on it - core applies every
%% target as `Module:Function(Params, Ctx)`.
is_ops_entry(Action, #{method := Method, mfa := {M, F, 2}, class := Class}) when
    is_atom(M), is_atom(F)
->
    is_segment(Action) andalso
        lists:member(Method, [get, post, put, delete]) andalso
        lists:member(Class, asobi_ops_caps:class_names());
is_ops_entry(_Action, _Entry) ->
    false.

is_segment(Action) when is_binary(Action), Action =/= ~"" ->
    binary:match(Action, [~"/", ~".", ~"?", ~"#", ~"%"]) =:= nomatch;
is_segment(_Action) ->
    false.

is_dotted(Method) when is_binary(Method) ->
    case binary:split(Method, ~".") of
        [Prefix, Rest] -> Prefix =/= ~"" andalso Rest =/= ~"" andalso not has_dot(Rest);
        _ -> false
    end;
is_dotted(_) ->
    false.

has_dot(Binary) ->
    binary:match(Binary, ~".") =/= nomatch.

lua_problems(Lua) when is_map(Lua) ->
    lists:append([
        lua_namespace_problems(Namespace, Functions)
     || Namespace := Functions <- Lua
    ]);
lua_problems(Lua) ->
    [{lua, ~"must be a map of namespace => functions", Lua}].

lua_namespace_problems(Namespace, Functions) when is_binary(Namespace), is_map(Functions) ->
    [
        {lua, binding_problem(Binding), {Namespace, Name}}
     || Name := Binding <- Functions, not is_lua_binding(Name, Binding)
    ];
lua_namespace_problems(Namespace, _Functions) ->
    [{lua, ~"namespace must be a binary mapped to a map of functions", Namespace}].

%% `args` is what the injector decodes off the Lua stack and `mfa` is what it
%% then applies, so a binding whose lengths disagree cannot be called at all.
is_lua_binding(Name, #{mfa := {M, F, A}, args := Args, effects := Effects, vms := Vms}) when
    is_binary(Name), is_atom(M), is_atom(F), is_integer(A), A >= 0, is_list(Args), is_list(Vms)
->
    length(Args) =:= A andalso
        lists:member(Effects, asobi_lua_surface:effects()) andalso
        Vms =/= [] andalso
        lists:all(fun(Vm) -> lists:member(Vm, asobi_lua_surface:extension_vm_kinds()) end, Vms);
is_lua_binding(_Name, _Binding) ->
    false.

binding_problem(#{mfa := {_, _, A}, args := Args}) when
    is_integer(A), is_list(Args), length(Args) =/= A
->
    ~"args must declare one type per mfa argument";
%% `bot` is a VM kind core has and not one an extension may bind into: a bot
%% script is loaded with no `game` table at all, so the binding would install
%% nothing. See `asobi_lua_surface:extension_vm_kinds/0`.
binding_problem(#{vms := Vms}) when is_list(Vms) ->
    case lists:member(bot, Vms) of
        true -> ~"vms cannot include bot: a bot VM has no game.* table to install into";
        false -> ~"binding must be #{mfa, args, effects, vms}"
    end;
binding_problem(_Binding) ->
    ~"binding must be #{mfa, args, effects, vms}".

owns_problems(Owns) when is_map(Owns) ->
    Kinds = asobi_extension_reserved:kinds(),
    [
        {owns, ~"unknown namespace kind", Kind}
     || Kind := _ <- Owns, not lists:member(Kind, Kinds)
    ] ++
        [
            {owns, ~"tokens must be a list of non-empty binaries", Kind}
         || Kind := Tokens <- Owns, lists:member(Kind, Kinds), not is_token_list(Tokens)
        ];
owns_problems(Owns) ->
    [{owns, ~"must be a map", Owns}].

is_token_list(Tokens) when is_list(Tokens) ->
    lists:all(fun(T) -> is_binary(T) andalso T =/= ~"" end, Tokens);
is_token_list(_) ->
    false.

%% A bare code would sit in core's cross-cutting namespace (`internal`,
%% `forbidden`), which no extension owns and the reserved set cannot protect.
%% Requiring a domain is what makes an extension code checkable at all.
codes_problems(Codes) when is_map(Codes) ->
    [
        {codes, ~"code must be <domain>.<name> mapped to #{status, message}", Code}
     || Code := Spec <- Codes, not is_code_spec(Code, Spec)
    ];
codes_problems(Codes) ->
    [{codes, ~"must be a map", Codes}].

is_code_spec(Code, #{status := Status, message := Message}) when
    is_integer(Status), Status >= 100, Status =< 599, is_binary(Message), Message =/= ~""
->
    is_dotted(Code);
is_code_spec(_Code, _Spec) ->
    false.

%% OTP already knows what a valid child spec is. Running its check here turns
%% a boot-time supervisor crash into a build-time line naming the extension.
sup_problems([]) ->
    [];
sup_problems(Specs) when is_list(Specs) ->
    case supervisor:check_childspecs(Specs) of
        ok -> [];
        {error, Reason} -> [{sup, ~"invalid child specs", Reason}]
    end;
sup_problems(Specs) ->
    [{sup, ~"must be a list of child specs", Specs}].

%%====================================================================
%% Validation
%%====================================================================

-doc """
Namespace disjointness across the declared set, and against core's reserved
names.

The claim set per namespace is `owns/0` **plus** what the extension's own code
already implies, and every kind derives:

| Kind | Derived from |
|---|---|
| `rpc` | the prefixes in `rpc/0` and the domains in `codes/0` |
| `lua` | the namespaces in `lua/0` |
| `tables` | `table/0` on the extension's `kura_schema` modules |
| `queues` | `queue/0` on the extension's `shigoto_worker` modules |

So two extensions installing the same `game.quests`, or the same job queue,
collide before either has bothered with `owns/0`.

The last two derive through `asobi_extension_reserved`, the same rule that
finds core's own tables and queues, so a name core reserves and a name an
extension claims can never be found two different ways.

That leaves `owns/0` doing one job, and it is worth stating because it is no
longer the source of anything: it is the **closed-set assertion** over what was
derived. Naming a kind at all says "this is the complete set", and anything
derived outside it is `undeclared_claim` - which is what turns a typo in
`owns.queues` from an invisible no-op into a build failure. Nothing in
`owns/0` is load-bearing for collision detection any more.
""".
-spec validate([extension()]) -> ok | {error, [problem(), ...]}.
validate([]) ->
    ok;
validate(Extensions) ->
    Reserved = asobi_extension_reserved:namespaces(),
    Problems =
        duplicate_names(Extensions) ++
            lists:append([
                kind_problems(Kind, Extensions, maps:get(Kind, Reserved, []))
             || Kind <- asobi_extension_reserved:kinds()
            ]),
    case Problems of
        [] -> ok;
        [_ | _] -> {error, Problems}
    end.

duplicate_names(Extensions) ->
    [
        {duplicate_name, Name, A, B}
     || {Name, A, B} <- pairs([{Name, App} || #{name := Name, app := App} <- Extensions])
    ].

kind_problems(Kind, Extensions, ReservedTokens) ->
    Claims = [{Token, App} || #{app := App} = E <- Extensions, Token <- claims(E, Kind)],
    [{namespace_conflict, Kind, Token, A, B} || {Token, A, B} <- pairs(Claims)] ++
        [
            {reserved_namespace, Kind, Token, App}
         || {Token, App} <- lists:usort(Claims), lists:member(Token, ReservedTokens)
        ] ++
        undeclared(Kind, Extensions).

%% `owns/0` is the closed statement of what an extension claims. Once it names
%% a kind at all, anything the manifest derives for that kind and the owned set
%% does not contain is a typo or a land grab.
undeclared(Kind, Extensions) ->
    [
        {undeclared_claim, Kind, Token, App}
     || #{app := App, owns := Owns} = E <- Extensions,
        Owned <- [maps:get(Kind, Owns, [])],
        Owned =/= [],
        Token <- derived(E, Kind),
        not lists:member(Token, Owned)
    ].

claims(Extension, Kind) ->
    #{owns := Owns} = Extension,
    lists:usort(maps:get(Kind, Owns, []) ++ derived(Extension, Kind)).

%% An error-code domain and an RPC prefix are the same token by construction,
%% so `codes/0` claims the rpc namespace exactly as `rpc/0` does. That is what
%% keeps an extension from minting codes inside core's set, or another
%% extension's, without a second reservation mechanism.
derived(#{rpc := Rpc, codes := Codes}, rpc) ->
    lists:usort(
        [Prefix || Method := _ <- Rpc, Prefix <- prefix(Method)] ++
            [Domain || Code := _ <- Codes, Domain <- prefix(Code)]
    );
derived(#{lua := Lua}, lua) ->
    lists:usort(maps:keys(Lua));
%% A shigoto queue is only ever what the worker's own `queue/0` returns -
%% nothing reads `owns.queues` at runtime - so deriving it here is what makes
%% the claim enforceable at all. Same for a table and its schema.
derived(#{app := App}, tables) ->
    asobi_extension_reserved:schema_tables(modules(App));
derived(#{app := App}, queues) ->
    asobi_extension_reserved:worker_queues(modules(App)).

prefix(Method) when is_binary(Method) ->
    case binary:split(Method, ~".") of
        [Prefix, _Rest] -> [Prefix];
        _ -> []
    end;
prefix(_Method) ->
    [].

%% Every token claimed more than once, anchored on its first claimant so a
%% three-way collision reports two pairs rather than one unhelpful set.
pairs(Claims) ->
    pairs(lists:usort(Claims), []).

pairs([{Token, A}, {Token, B} | Rest], Acc) ->
    pairs([{Token, A} | Rest], [{Token, A, B} | Acc]);
pairs([_ | Rest], Acc) ->
    pairs(Rest, Acc);
pairs([], Acc) ->
    lists:reverse(Acc).

%%====================================================================
%% Reporting
%%====================================================================

-doc "Renders validation problems as lines a human can act on.".
-spec describe([problem()]) -> [binary()].
describe(Problems) ->
    [describe_one(Problem) || Problem <- Problems].

describe_one({bad_manifest, App, Module, Detail}) ->
    line("~s: ~s is not a valid manifest (~0p).", [App, Module, Detail]);
describe_one({duplicate_name, Name, A, B}) ->
    line(
        "~s and ~s both call themselves \"~s\". info().name is the extension's identity.",
        [A, B, Name]
    );
describe_one({namespace_conflict, Kind, Token, A, B}) ->
    line(
        "~s and ~s both claim the ~s \"~s\". Namespaces are exclusive; rename one.",
        [A, B, singular(Kind), Token]
    );
describe_one({reserved_namespace, Kind, Token, App}) ->
    line("~s claims the ~s \"~s\", which asobi reserves.", [App, singular(Kind), Token]);
describe_one({undeclared_claim, Kind, Token, App}) ->
    line(
        "~s uses the ~s \"~s\" but does not list it in owns().~s.",
        [App, singular(Kind), Token, Kind]
    ).

line(Format, Args) ->
    iolist_to_binary(io_lib:format(Format, Args)).

singular(tables) -> ~"table";
singular(rpc) -> ~"RPC prefix";
singular(lua) -> ~"Lua namespace";
singular(queues) -> ~"queue".
