-module(asobi_lua_loader).
-moduledoc """
Loads Lua scripts into a hardened Luerl state.

The state is built on top of `luerl:init/0` and then has every dangerous
standard-library entry point cleared:

- `os.execute`, `os.exit`, `os.getenv`, `os.remove`, `os.rename`,
  `os.tmpname`
- `io` (the whole library)
- `dofile`, `loadfile`, `load`, `loadstring`
- `package` (the whole library) — replaced by an `asobi_lua`-controlled
  `require/1` so scripts can still split logic across files

`require/1` resolves names relative to the directory of the script that
was loaded. Names must match `[a-zA-Z_][a-zA-Z0-9_]*(\\.[a-zA-Z_][a-zA-Z0-9_]*)*`,
so dotted module paths work (`require("bots.chaser")` →
`<base>/bots/chaser.lua`) but parent traversal (`..`), absolute paths,
and arbitrary characters are rejected. Module results are cached in a
private `_ASOBI_LOADED` table so repeat `require` calls return the same
value.

`math.random` and `math.sqrt` are overridden to call into the Erlang
`rand` and `math` modules respectively — Luerl's defaults are slower
and less deterministic than the BEAM equivalents.

Use `init_sandboxed/0` when you need a hardened state with no script
attached (e.g. for evaluating a `config.lua` manifest); use `new/1` to
load a specific script and pin its base directory for `require`.
""".

-export([new/1, new/2, new/3, init_sandboxed/0, call/3, call/4, do_with_timeout/3]).
-export([is_defined/2]).

-export_type([pre_install/0]).

-type pre_install() :: fun((dynamic()) -> dynamic()).

-include_lib("kernel/include/file.hrl").

-define(LOADED_TABLE, ~"_ASOBI_LOADED").
%% M-2/M-3/H-1: any luerl:do/2 invocation that runs script-author code
%% must enforce a wall-clock budget; otherwise a `while true do end`
%% in the top-level body hangs the calling gen_server (or the BEAM
%% itself, when the call happens during application start). 2s is
%% generous for normal scripts and short enough that an operator
%% notices the hang.
-define(DEFAULT_INIT_TIMEOUT_MS, 2000).

%% Per-eval heap cap. A correctly-written tick handler should not
%% allocate near 40MB; legitimate large state lives in the persistent
%% Luerl state held by the gen_server, not in the per-eval process.
%% Configurable via `asobi_lua.max_heap_words` for ops with unusual
%% workloads. `kill => true` makes the VM kill the eval process if it
%% allocates past the limit; the parent receives `{'DOWN', _, _, _,
%% killed}` and surfaces `{error, heap_exhausted}` so the caller can
%% distinguish heap-blow from timeout.
-define(DEFAULT_MAX_HEAP_WORDS, 5_000_000).

-spec new(binary() | string()) -> {ok, dynamic()} | {error, term()}.
new(ScriptPath) ->
    new(ScriptPath, ?DEFAULT_INIT_TIMEOUT_MS, fun(St) -> St end).

-spec new(binary() | string(), non_neg_integer()) -> {ok, dynamic()} | {error, term()}.
new(ScriptPath, TimeoutMs) ->
    new(ScriptPath, TimeoutMs, fun(St) -> St end).

%% Lua closures capture `_ENV` at compile time, so any global installed
%% AFTER the script chunk is evaluated is invisible to functions the
%% script defined. The `PreInstall` hook runs between sandbox setup and
%% script eval — that is the only window in which adding tables to `_G`
%% (e.g. the `game.*` API) makes them reachable from every callback the
%% script defines, including `handle_input` which doesn't go through a
%% spawn round-trip (see ADR 0002).
-spec new(binary() | string(), non_neg_integer(), pre_install()) ->
    {ok, dynamic()} | {error, term()}.
new(ScriptPath, TimeoutMs, PreInstall) when is_function(PreInstall, 1) ->
    BaseDir = filename:dirname(to_string(ScriptPath)),
    FileName = filename:basename(to_string(ScriptPath)),
    St0 = sandboxed_state(BaseDir),
    St1 = PreInstall(St0),
    FullPath = filename:join(BaseDir, FileName),
    case file:read_file(FullPath) of
        {ok, Code} ->
            CodeStr = binary_to_list(Code),
            do_with_timeout(CodeStr, St1, TimeoutMs);
        {error, Reason} ->
            {error, {file_error, FullPath, Reason}}
    end.

%% M-2/M-3/H-1: spawn-and-kill wrapper around `luerl:do/2`. Required
%% any time the input is script-author-controlled — that includes the
%% top-level body of the loaded script, hot-reload code, and config
%% manifests evaluated during app start.
-spec do_with_timeout(string() | binary(), dynamic(), non_neg_integer()) ->
    {ok, dynamic()} | {error, term()}.
do_with_timeout(Code, St, TimeoutMs) ->
    bounded_eval(
        fun() ->
            try luerl:do(ensure_string(Code), St) of
                {ok, _Results, St1} -> {ok, St1};
                {error, Errors, _} -> {error, {lua_error, Errors}};
                {lua_error, Reason, _} -> {error, {lua_error, Reason}}
            catch
                error:{lua_error, Reason, _} -> {error, {lua_error, Reason}};
                error:Reason -> {error, Reason}
            end
        end,
        TimeoutMs
    ).

-spec init_sandboxed() -> dynamic().
init_sandboxed() ->
    %% No script → no base dir → require is disabled. Used by
    %% asobi_lua_config to evaluate config manifests, which return a
    %% plain table and don't need to compose other files.
    sandboxed_state(undefined).

%% Whether a top-level global names a callable in the script. Optional
%% callbacks (spawn_templates, terrain_provider, phases, generate_world, ...)
%% are only ever called when this is true - call/3,4 cannot itself tell
%% "the script never defined this" apart from "the script defined it and it
%% raised", since Luerl's undefined-global call and a runtime error both
%% surface as the same {error, {lua_error, _}} shape.
-spec is_defined(atom(), dynamic()) -> boolean().
is_defined(FuncName, St) ->
    try luerl:get_table_keys([atom_to_binary(FuncName)], St) of
        {ok, nil, _} -> false;
        {ok, _, _} -> true;
        _ -> false
    catch
        _:_ -> false
    end.

-spec call(atom() | [atom() | binary()], [term()], dynamic()) ->
    {ok, [term()], dynamic()} | {error, term()}.
call(FuncName, Args, St) when is_atom(FuncName) ->
    call([atom_to_binary(FuncName)], Args, St);
call(FuncPath, Args, St) ->
    BinPath = [ensure_binary(P) || P <- FuncPath],
    try
        case luerl:call_function(BinPath, Args, St) of
            {ok, Result, St1} -> {ok, Result, St1};
            %% luerl:call_function returns (not raises) runtime Lua errors;
            %% matching only {ok, ...} used to collapse them all into an
            %% opaque {call_failed, Path} via the catch-all below.
            {lua_error, LuaReason, _} -> {error, {lua_error, LuaReason}}
        end
    catch
        error:{lua_error, Reason, _} ->
            {error, {lua_error, Reason}};
        error:{try_clause, {lua_error, Reason, _}} ->
            {error, {lua_error, Reason}};
        _:_ ->
            {error, {call_failed, BinPath}}
    end.

-spec call(atom() | [atom() | binary()], [term()], dynamic(), non_neg_integer()) ->
    {ok, [term()], dynamic()} | {error, timeout | heap_exhausted | term()}.
call(FuncPath, Args, St, TimeoutMs) ->
    bounded_eval(fun() -> call(FuncPath, Args, St) end, TimeoutMs).

%% Spawn the work in a child with a bounded wall-clock budget AND a
%% bounded heap, monitor it, and translate the three terminal states
%% the parent might observe into return values:
%%   - normal exit + {Ref, Result} message    → Result
%%   - timeout (we kill it, exit reason `kill`) → {error, timeout}
%%   - VM kills it for heap (exit reason `killed`) → {error, heap_exhausted}
%% A heap kill happens *before* the worker can send {Ref, _}, so the
%% DOWN message races. We give the message a tiny grace window in case
%% it is in flight.
-spec bounded_eval(fun(() -> R), non_neg_integer()) ->
    R | {error, timeout | heap_exhausted | {worker_exit, term()}}.
bounded_eval(Fun, TimeoutMs) ->
    Self = self(),
    Ref = make_ref(),
    SpawnOpts = [
        monitor,
        {max_heap_size, #{
            size => max_heap_words(),
            kill => true,
            error_logger => true,
            include_shared_binaries => false
        }}
    ],
    {Pid, MonRef} =
        spawn_opt(
            fun() ->
                Self ! {Ref, Fun()}
            end,
            SpawnOpts
        ),
    receive
        {Ref, Result} ->
            erlang:demonitor(MonRef, [flush]),
            Result;
        {'DOWN', MonRef, process, Pid, killed} ->
            {error, heap_exhausted};
        {'DOWN', MonRef, process, Pid, Reason} ->
            {error, {worker_exit, Reason}}
    after TimeoutMs ->
        exit(Pid, kill),
        receive
            {Ref, Result} ->
                erlang:demonitor(MonRef, [flush]),
                Result;
            {'DOWN', MonRef, process, Pid, _} ->
                {error, timeout}
        after 0 ->
            erlang:demonitor(MonRef, [flush]),
            {error, timeout}
        end
    end.

-spec max_heap_words() -> pos_integer().
max_heap_words() ->
    case asobi_lua_env:get_env(max_heap_words) of
        {ok, N} when is_integer(N), N > 0 -> N;
        _ -> ?DEFAULT_MAX_HEAP_WORDS
    end.

%% --- Internal: state construction & sandbox ---

-spec sandboxed_state(string() | binary() | undefined) -> dynamic().
sandboxed_state(BaseDir) ->
    St0 = luerl:init(),
    St1 = strip_dangerous_globals(St0),
    St2 = install_loaded_table(St1),
    St3 = install_require(BaseDir, St2),
    install_helpers(St3).

-spec strip_dangerous_globals(dynamic()) -> dynamic().
strip_dangerous_globals(St) ->
    %% Replace each entry with `nil` (rather than the atom `sandboxed`
    %% Luerl's bundled sandbox uses) so that `os.execute == nil` is the
    %% predicate scripts can check. luerl:set_table_keys/3 works on the
    %% encoded global table; setting a leaf to nil clears it without
    %% deleting the parent table.
    %%
    %% L-1: `print` and `eprint` are stripped here because Luerl's
    %% defaults call `io:format` directly to the BEAM stdout, which
    %% breaks the structured JSON log stream and lets a tight loop
    %% flood the runtime's logging driver. Scripts log through
    %% `game.log` (asobi_lua_api), which routes structured reports
    %% through the host logger behind a rate limit - closing exactly
    %% the two holes print was removed for.
    Paths = [
        [~"os", ~"execute"],
        [~"os", ~"exit"],
        [~"os", ~"getenv"],
        [~"os", ~"remove"],
        [~"os", ~"rename"],
        [~"os", ~"tmpname"],
        [~"dofile"],
        [~"loadfile"],
        [~"load"],
        [~"loadstring"],
        [~"io"],
        [~"package"],
        [~"require"],
        [~"print"],
        [~"eprint"]
    ],
    lists:foldl(
        fun(Path, Acc) ->
            {ok, Next} = luerl:set_table_keys(Path, nil, Acc),
            Next
        end,
        St,
        Paths
    ).

%% --- require: validation & resolution ---

-spec install_loaded_table(dynamic()) -> dynamic().
install_loaded_table(St) ->
    {Tab, St1} = luerl:encode(#{}, St),
    {ok, St2} = luerl:set_table_keys([?LOADED_TABLE], Tab, St1),
    St2.

-spec install_require(string() | binary() | undefined, dynamic()) -> dynamic().
install_require(undefined, St) ->
    %% No base directory → require always errors. Scripts that try it
    %% see a Lua-level error rather than a confusing nil dereference.
    Fn = fun(_Args, St0) ->
        error({lua_error, ~"require: no base directory configured", St0})
    end,
    {Enc, St1} = luerl:encode(Fn, St),
    {ok, St2} = luerl:set_table_keys([~"require"], Enc, St1),
    St2;
install_require(BaseDir, St) ->
    BaseDirBin = ensure_binary(BaseDir),
    Fn = fun(Args, St0) ->
        case Args of
            [Name | _] when is_binary(Name) ->
                handle_require(Name, BaseDirBin, St0);
            _ ->
                error({lua_error, ~"require: argument must be a string", St0})
        end
    end,
    {Enc, St1} = luerl:encode(Fn, St),
    {ok, St2} = luerl:set_table_keys([~"require"], Enc, St1),
    St2.

-spec handle_require(binary(), binary(), dynamic()) -> {[term()], dynamic()}.
handle_require(Name, BaseDir, St) ->
    case validate_module_name(Name) of
        ok ->
            case lookup_loaded(Name, St) of
                {hit, Cached, St1} ->
                    {[Cached], St1};
                {miss, St1} ->
                    load_module(Name, BaseDir, St1)
            end;
        error ->
            error({lua_error, <<"require: invalid module name: ", Name/binary>>, St})
    end.

-spec validate_module_name(binary()) -> ok | error.
validate_module_name(Name) ->
    %% Allowed: identifier (letters/digits/underscore) optionally
    %% followed by `.identifier` segments. Rejects empty, "..", "/",
    %% leading dots, trailing dots, double dots, and non-ASCII bytes.
    %% M-1: `dollar_endonly` makes `$` mean strict end-of-input rather
    %% than "before a final newline", so `require("foo\n")` no longer
    %% slips through the validator.
    case
        re:run(
            Name,
            ~"^[A-Za-z_][A-Za-z0-9_]*(\\.[A-Za-z_][A-Za-z0-9_]*)*$",
            [{capture, none}, dollar_endonly]
        )
    of
        match -> ok;
        nomatch -> error
    end.

-spec lookup_loaded(binary(), dynamic()) -> {hit, term(), dynamic()} | {miss, dynamic()}.
lookup_loaded(Name, St) ->
    case luerl:get_table_keys([?LOADED_TABLE, Name], St) of
        {ok, nil, St1} ->
            {miss, St1};
        {ok, Value, St1} ->
            {hit, Value, St1};
        %% I-2: a script can `_ASOBI_LOADED = nil` or otherwise clobber
        %% the cache table. Surface a clean Lua-level error instead of
        %% letting the case_clause crash propagate.
        {lua_error, _Reason, St1} ->
            error({lua_error, ~"_ASOBI_LOADED was clobbered by script", St1})
    end.

-spec load_module(binary(), binary(), dynamic()) -> {[term()], dynamic()}.
load_module(Name, BaseDir, St) ->
    Rel = binary:replace(Name, ~".", ~"/", [global]),
    Path = filename:join(BaseDir, <<Rel/binary, ".lua">>),
    %% L-4: refuse symlinks at resolve time. file:read_file follows them,
    %% so a symlink at <base>/foo.lua → /etc/passwd would otherwise be
    %% read and parsed as Lua, with the parser's error potentially
    %% leaking content into logs (I-4).
    case file:read_link_info(Path, [{time, posix}]) of
        {ok, #file_info{type = symlink}} ->
            error({lua_error, {require_failed, Name, symlink}, St});
        _ ->
            ok
    end,
    case file:read_file(Path) of
        {ok, Code} ->
            CodeStr = binary_to_list(Code),
            case luerl:do(CodeStr, St) of
                {ok, [Module | _], St1} ->
                    cache_and_return(Name, Module, St1);
                {ok, [], St1} ->
                    %% Lua convention: a module without an explicit
                    %% return is treated as `true`.
                    cache_and_return(Name, true, St1);
                {error, Errors, _} ->
                    error({lua_error, {require_failed, Name, truncate_errors(Errors)}, St});
                Other ->
                    error({lua_error, {require_failed, Name, Other}, St})
            end;
        {error, Reason} ->
            error({lua_error, {require_not_found, Name, Reason}, St})
    end.

%% I-4: keep the error tail short so a non-Lua file (e.g. a binary
%% mistakenly placed under the game dir) cannot dump arbitrary bytes
%% into structured logs via the lua compiler's error message. Luerl's
%% compiler returns a list of error records; cap to the first few
%% entries so logs stay bounded even if the underlying format ever
%% widens.
-spec truncate_errors([term()]) -> [term()].
truncate_errors(L) when is_list(L) ->
    case length(L) > 3 of
        true -> lists:sublist(L, 3) ++ [truncated];
        false -> L
    end.

-spec cache_and_return(binary(), term(), dynamic()) -> {[term()], dynamic()}.
cache_and_return(Name, Module, St) ->
    {ok, St1} = luerl:set_table_keys([?LOADED_TABLE, Name], Module, St),
    {[Module], St1}.

%% --- math overrides ---

-spec install_helpers(dynamic()) -> dynamic().
install_helpers(St) ->
    RandFn = fun(Args, St0) ->
        case Args of
            [] ->
                {[rand:uniform()], St0};
            [M, N | _] when is_number(M), is_number(N) ->
                Lo = trunc(M),
                Hi = trunc(N),
                case Hi >= Lo of
                    true ->
                        {[Lo - 1 + rand:uniform(Hi - Lo + 1)], St0};
                    false ->
                        %% Upstream Lua raises "interval is empty";
                        %% badarg_error throws a proper lua_error, so
                        %% pcall in script code traps it.
                        luerl_lib:badarg_error(random, Args, St0)
                end;
            [N | _] when is_number(N), N >= 1 ->
                {[rand:uniform(trunc(N))], St0};
            _ ->
                {[rand:uniform()], St0}
        end
    end,
    SqrtFn = fun(Args, St0) ->
        case Args of
            [N | _] when is_number(N), N >= 0 -> {[math:sqrt(N)], St0};
            %% math:sqrt errors on negatives; upstream Lua returns NaN.
            %% Returning 0.0 is a pragmatic compromise — game scripts
            %% shouldn't be feeding sqrt negative numbers, and 0.0
            %% keeps the bridge call from crashing.
            [N | _] when is_number(N) -> {[0.0], St0};
            _ -> {[0.0], St0}
        end
    end,
    {EncRand, St1} = luerl:encode(RandFn, St),
    {ok, St2} = luerl:set_table_keys([~"math", ~"random"], EncRand, St1),
    {EncSqrt, St3} = luerl:encode(SqrtFn, St2),
    {ok, St4} = luerl:set_table_keys([~"math", ~"sqrt"], EncSqrt, St3),
    St4.

%% --- utilities ---

-spec ensure_binary(binary() | atom() | string()) -> binary().
ensure_binary(B) when is_binary(B) -> B;
ensure_binary(A) when is_atom(A) -> atom_to_binary(A);
ensure_binary(L) when is_list(L) -> list_to_binary(L).

-spec to_string(binary() | string()) -> string().
to_string(B) when is_binary(B) -> binary_to_list(B);
to_string(L) when is_list(L) -> L.

-spec ensure_string(binary() | string()) -> string().
ensure_string(B) when is_binary(B) -> binary_to_list(B);
ensure_string(L) when is_list(L) -> L.
