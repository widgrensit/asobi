-module(asobi_lua_loader).
-moduledoc """
Loads Lua scripts into a hardened Luerl state.

The state is built on top of `luerl:init/0` and then has every dangerous
standard-library entry point cleared:

- `os.execute`, `os.exit`, `os.getenv`, `os.remove`, `os.rename`,
  `os.tmpname`
- `io` (the whole library)
- `dofile`, `loadfile`, `load`, `loadstring`
- `collectgarbage` - asobi collects on its own schedule via `luerl:gc/1`;
  letting a script force a synchronous mark-and-sweep on the zone process is
  both a DoS surface and a way to free references Erlang is still holding
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

-export([new/1, new/2, new/3, new_copied/3, init_sandboxed/0, call/3, call/4, do_with_timeout/3]).
-export([is_defined/2]).
-export([collect_state/1]).
-export([anchor_ref/2, unanchor_ref/1, ref_anchored/2]).
%% ADR 0015: the five luerl operations the bridges use, behind one door so a
%% bridge does not care whether it is holding a Luerl state or a pid.
-export([encode/2, decode/2, get_table_key/3, get_table_keys/2, set_table_keys/3]).
-export([vm_mode/0, vm_max_heap_words/0, release/1, revert/1]).
%% Called back by asobi_lua_vm, which runs these against the state it owns.
-export([do_inline/2, gc_now/2]).
-ifdef(TEST).
-export([next_gc/4, gc_budget_us/1, state_words/0]).
-endif.

-export_type([pre_install/0]).

-type pre_install() :: fun((dynamic()) -> dynamic()).

-include_lib("kernel/include/file.hrl").
-include_lib("kernel/include/logger.hrl").
%% For `#luerl.g` - the authoritative `_G`, needed to write the collector's
%% anchor past whatever metatable a script has put on it. See `collect/2`.
-include_lib("luerl/include/luerl.hrl").

-define(LOADED_TABLE, ~"_ASOBI_LOADED").
%% M-2/M-3/H-1: any luerl:do/2 invocation that runs script-author code
%% must enforce a wall-clock budget; otherwise a `while true do end`
%% in the top-level body hangs the calling gen_server (or the BEAM
%% itself, when the call happens during application start). 2s is
%% generous for normal scripts and short enough that an operator
%% notices the hang.
-define(DEFAULT_INIT_TIMEOUT_MS, 2000).

%% Per-eval heap budget: what one callback may allocate *on top of* the
%% state it was handed, not a cap on the process. #536: as an absolute
%% `max_heap_size` at spawn this bounded the persistent Luerl state
%% instead - the state is copied into the eval worker by the spawn
%% itself, so a handler that allocated nothing was killed once the state
%% behind it was large enough, and it was killed again on every tick
%% until the collector next ran. `bounded_eval` therefore measures the
%% worker's heap after the copy and caps it at that plus this budget, so
%% the number means what it says here regardless of state size.
%% Configurable via `asobi_lua.max_heap_words`. `kill => true` makes the
%% VM kill the eval process if it allocates past the limit; the parent
%% receives `{'DOWN', _, _, _, killed}` and surfaces
%% `{error, heap_exhausted}` so the caller can distinguish heap-blow
%% from timeout.
-define(DEFAULT_MAX_HEAP_WORDS, 5_000_000).

%% #348: CPU bound, expressed as reductions allowed per millisecond of the
%% callback's own wall-clock budget. The timeout bounds latency but not work:
%% a script that spins is killed at its deadline and then does it again on the
%% next tick, burning a whole scheduler indefinitely.
%%
%% The rate is per-ms rather than absolute because the budgets it has to serve
%% span two orders of magnitude (50 ms for `think`, 5000 ms for
%% `generate_world`); scaling keeps their relative weights. 50,000 is measured
%% against Luerl on this workload: a 200-entity tick costs ~24k reductions
%% total, while a spin sustains ~284k reductions/ms, so the budget sits ~1000x
%% above a normal tick and cuts a spin at ~18% of its wall-clock window. Set
%% `asobi_lua.max_reductions_per_ms` to 0 to disable the check.
-define(DEFAULT_MAX_REDUCTIONS_PER_MS, 50_000).

%% How often the parent samples the worker's reduction count. Overshoot is
%% bounded by one interval's worth of work (~2.8M reductions at the rate
%% above), an order of magnitude under the smallest budget this produces.
-define(REDUCTION_POLL_MS, 10).

%% #426: Luerl never collects a long-lived state on its own - only an explicit
%% `luerl:gc/1` from Erlang reclaims anything, and since `collectgarbage` is
%% stripped from the sandbox that call is asobi's alone to make.
%% Every per-tick `luerl:encode/2` therefore leaks: measured at ~3900 words per
%% tick for a 50-entity zone, which is ~625 KB/s per zone at a 50 ms tick, and
%% `bounded_eval` copies the whole state into the eval worker and back on every
%% call, so the cost of a tick grows with everything the zone has ever
%% allocated. Left alone a busy zone reaches a tick that outruns `tick_rate`
%% and the world ticker's back-pressure starts dropping its ticks.
%%
%% The interval adapts on measured cost rather than being fixed, because
%% Luerl's mark phase is an `ordsets` list insert per live object - quadratic
%% in the live set. A zone holding little across ticks wants to collect often
%% (the state stays small, so both the collection and the per-tick copies stay
%% cheap); a zone holding a large persistent Lua table wants to collect rarely
%% (each collection is expensive and reclaims the same per-tick garbage either
%% way). Measured per-tick cost for a 50-entity zone: 6.09 ms uncollected and
%% still climbing, 0.10 ms adaptive.
-define(GC_MIN_INTERVAL, 8).
-define(GC_MAX_INTERVAL, 1024).
-define(GC_BUDGET_US, 5_000).
%% #536: a flat budget is the wrong yardstick, because what a collection buys
%% is not measured in ticks - it is measured against the copy `call/4` makes
%% on every callback. That copy costs ~51us per 1000 words of state (~7ms per
%% MB): a no-op callback measured 1.8ms against a 0.4MB state, 41ms against
%% 6MB and 418ms against 62MB. So a collection that shrinks a large state pays
%% for itself many times over before the next one, and the flat 5ms ceiling
%% backed the interval off to its maximum on exactly the states that could
%% least afford it - the sawtooth in #536, whose peak still outgrew the eval
%% budget. The budget therefore scales with the state being collected, capped
%% at a quarter of one copy: past that the collection is visible in the tick
%% itself, which is the only cost this trade is really spending.
-define(GC_BUDGET_WORDS_PER_US, 80).
%% Past this a single collection costs more than the leak does over the
%% interval that would follow it, so stop rather than freeze the zone.
-define(GC_ABANDON_US, 500_000).
%% ...but stop for a cool-down, not for the life of the bridge. One collection
%% over the ceiling is as likely to be a BEAM GC pause or a busy scheduler as
%% proof the live set is permanently uncollectable, and a collector that never
%% re-arms fails open: the state then grows unbounded with one warning to show
%% for it. Retrying every few minutes costs at most one overrun per interval.
-define(GC_RETRY_MS, 300_000).
%% The scaled budget has to stay under the abandon ceiling, because the
%% abandon clause is tested first: a budget above it makes the "this
%% collection overran, back off" branch unreachable, and then every
%% collection that does not abandon looks cheap and drives the interval
%% down to its minimum. That inverts the whole loop on the largest states -
%% exactly the ones #536 is about - so the ceiling is load-bearing, not a
%% tidy-up. A quarter leaves the back-off a working range either side.
-define(GC_BUDGET_CEILING_US, (?GC_ABANDON_US div 4)).
-define(GC_ANCHOR, ~"__asobi_gc_anchor").
%% A second root, for a value Erlang holds across `call/3` invocations rather
%% than across a collection. Distinct from ?GC_ANCHOR so the two never evict
%% each other: a collection can run while an input batch is mid-flight.
-define(REF_ANCHOR, ~"__asobi_ref_anchor").

%% How often `collect_state/1` reports the measured state size. The collector's
%% own interval is adaptive and can be off entirely, so the size cannot ride on
%% a collection - it has to be reported on its own cadence or it goes silent
%% exactly when an operator needs it.
%%
%% Wall-clock rather than a tick count, for the reason ADR 0005 gives for
%% `[asobi, world, tick]`: a per-call counter is a rate that depends on the
%% world's tick rate, and this one is emitted per *bridge*, so a hundred live
%% zones multiply it. One event per second per bridge is a sink an operator can
%% keep. Override with `asobi_lua.state_sample_interval_ms`.
-define(DEFAULT_STATE_SAMPLE_INTERVAL_MS, 1000).

%% One warning per excursion when the copy `call/4` makes crosses ~100MB. There
%% is no longer an absolute heap cap to trip (see ?DEFAULT_MAX_HEAP_WORDS),
%% which is the point - but a state this size costs ~700ms per callback in
%% copying alone, so it needs to be said out loud rather than only in
%% telemetry. What "too large" means depends on the world's tick budget, which
%% asobi_lua_loader cannot see, so it is a knob:
%% `asobi_lua.state_warn_words`, 0 to silence.
-define(DEFAULT_STATE_WARN_WORDS, 12_500_000).

%% Written by `bounded_eval` on the calling process - the zone, world or match
%% gen_server - and read by `collect_state/1` on that same process. The eval
%% worker's own heap immediately after the spawn *is* the copied state, so
%% this measurement is exact and costs nothing; nothing else on the calling
%% side can size the state without walking it.
-define(STATE_WORDS_KEY, {?MODULE, state_words}).

%% Ceiling on one un-budgeted VM operation. An encode or a table read is
%% microseconds; anything reaching this is a VM wedged by something the caller
%% cannot see, and waiting forever on it would hang the zone.
-define(VM_OP_TIMEOUT, 5_000).

-doc """
Whether a bridge holds the Luerl state itself or a process that owns it.

`copy` (the default) is the original path: the state lives in the bridge's own
map and `call/4` spawns a worker per callback, which copies it in and back.
`owned` is ADR 0015: an `asobi_lua_vm` process holds the state and the bridge
holds a handle.

Defaulting to `copy` for at least one release is ADR 0015's own decision item 6.
The two paths differ in what a runaway callback costs - a tick under `copy`, the
state under `owned` - and that is not a difference to flip on under an operator
without warning.
""".
-spec vm_mode() -> copy | owned.
vm_mode() ->
    case asobi_lua_env:get_env(lua_vm_mode) of
        {ok, owned} -> owned;
        {ok, copy} -> copy;
        _ -> copy
    end.

-doc """
Absolute heap ceiling for an `asobi_lua_vm`, in words. 0 disables it.

Meaningful only under `owned`: this is the first time an absolute cap bounds the
persistent state rather than a copy of it, because the capped process is the one
holding it. Under `copy` the equivalent knob (`max_heap_words`) has to be
relative to the state, which is why it cannot be a ceiling on the state.
""".
-spec vm_max_heap_words() -> non_neg_integer().
vm_max_heap_words() ->
    case asobi_lua_env:get_env(vm_max_heap_words) of
        {ok, N} when is_integer(N), N >= 0 -> N;
        _ -> 0
    end.

-doc """
Undo the last `call/3,4` against this state.

Under `copy` this is a no-op, because a caller reverts simply by carrying on
with the state variable it had before the call - a Luerl state is immutable and
the mutated one is dropped. Under `owned` the mutation has already happened
inside the VM, so the same intent has to be said out loud.

Callers that rely on it are the ones where a *successful* call is rejected on
its answer rather than on an error: a refused `join`, and an input in a batch
that returned nothing usable. Both are load-bearing - a refused join that could
still advance the game state lets a client drive a script by being turned away
over and over, and an input that keeps what it touched without returning it can
mutate another player's entity. An error needs no revert: the VM keeps the
pre-call state on a raise, exactly as the copying path did by dropping the
state the failed call produced.
""".
-spec revert(dynamic()) -> dynamic().
revert(St) ->
    case asobi_lua_vm:is_handle(St) of
        true ->
            _ = asobi_lua_vm:op(St, revert, ?VM_OP_TIMEOUT),
            St;
        false ->
            St
    end.

-doc """
Release whatever `new/3` returned. A no-op for a copied state; stops the VM for
an owned one.
""".
-spec release(dynamic()) -> ok.
release(St) ->
    case asobi_lua_vm:is_handle(St) of
        true -> asobi_lua_vm:stop(St);
        false -> ok
    end.

-doc """
Load a script into a plain copied state, with no `game.*` API installed.

`new/1` and `new/2` are always the copying path, whatever `lua_vm_mode` says.
ADR 0015 is about the bridges whose state is ticked thousands of times - zones
and matches, which come through `new/3` - and its callers here are either
one-shot (`asobi_lua_config`, `asobi_lua_validate`) or a separate lifecycle
(bots). Moving those is a later step, not a wider blast radius for the first
release of a default-off flag.
""".
-spec new(binary() | string()) -> {ok, dynamic()} | {error, term()}.
new(ScriptPath) ->
    new_copied(ScriptPath, ?DEFAULT_INIT_TIMEOUT_MS, fun(St) -> St end).

-spec new(binary() | string(), non_neg_integer()) -> {ok, dynamic()} | {error, term()}.
new(ScriptPath, TimeoutMs) ->
    new_copied(ScriptPath, TimeoutMs, fun(St) -> St end).

%% Lua closures capture `_ENV` at compile time, so any global installed
%% AFTER the script chunk is evaluated is invisible to functions the
%% script defined. The `PreInstall` hook runs between sandbox setup and
%% script eval — that is the only window in which adding tables to `_G`
%% (e.g. the `game.*` API) makes them reachable from every callback the
%% script defines, including `handle_input` which doesn't go through a
%% spawn round-trip (it is not a sandbox boundary, see
%% guides/security-trust-model.md).
-spec new(binary() | string(), non_neg_integer(), pre_install()) ->
    {ok, dynamic()} | {error, term()}.
new(ScriptPath, TimeoutMs, PreInstall) when is_function(PreInstall, 1) ->
    new_1(ScriptPath, TimeoutMs, PreInstall, vm_mode()).

new_1(ScriptPath, TimeoutMs, PreInstall, Mode) when is_function(PreInstall, 1) ->
    BaseDir = filename:dirname(to_string(ScriptPath)),
    FileName = filename:basename(to_string(ScriptPath)),
    St0 = sandboxed_state(BaseDir),
    St1 = PreInstall(St0),
    FullPath = filename:join(BaseDir, FileName),
    case file:read_file(FullPath) of
        {ok, Code} ->
            CodeStr = binary_to_list(Code),
            %% The script body is evaluated the copying way whatever the mode:
            %% it is script-author code with no state worth preserving if it
            %% runs away, and a VM is only worth starting around a state that
            %% loaded. Under `owned` the loaded state is then handed to a VM and
            %% never copied again.
            own(do_with_timeout(CodeStr, St1, TimeoutMs), Mode);
        {error, Reason} ->
            {error, {file_error, FullPath, Reason}}
    end.

-doc """
Like `new/3`, but always a plain copied state, never an owned VM.

For the throwaway probe states a bridge boots to ask a script one question and
then drops (`spawn_templates`, `phases`, `terrain_provider`, `generate_world`
from a raw config). Under `owned` those would each start a process that nothing
ever stops, and they would gain nothing by it: the whole point of an owned VM is
to amortise a state across many callbacks, and these see exactly one.
""".
-spec new_copied(binary() | string(), non_neg_integer(), pre_install()) ->
    {ok, dynamic()} | {error, term()}.
new_copied(ScriptPath, TimeoutMs, PreInstall) ->
    new_1(ScriptPath, TimeoutMs, PreInstall, copy).

-spec own({ok, dynamic()} | {error, term()}, copy | owned) ->
    {ok, dynamic()} | {error, term()}.
own({ok, St}, copy) -> {ok, St};
own({ok, St}, owned) -> asobi_lua_vm:start_link(St);
own({error, _} = Err, _Mode) -> Err.

%% M-2/M-3/H-1: spawn-and-kill wrapper around `luerl:do/2`. Required
%% any time the input is script-author-controlled — that includes the
%% top-level body of the loaded script, hot-reload code, and config
%% manifests evaluated during app start.
-doc """
Evaluate `Code` against the state, in the calling process.

Public only for `asobi_lua_vm`. Under `copy` the spawn-and-kill wrapper in
`do_with_timeout/3` is what bounds script-author code; under `owned` the VM
process is itself the killable thing, so the wrapper would be a copy of the
state for no guard that the VM does not already have.
""".
-spec do_inline(string() | binary(), dynamic()) -> {ok, dynamic()} | {error, term()}.
do_inline(Code, St) ->
    try luerl:do(ensure_string(Code), St) of
        {ok, _Results, St1} -> {ok, St1};
        {error, Errors, _} -> {error, {lua_error, Errors}};
        {lua_error, Reason, _} -> {error, {lua_error, Reason}}
    catch
        error:{lua_error, Reason, _} -> {error, {lua_error, Reason}};
        error:Reason -> {error, Reason}
    end.

-spec do_with_timeout(string() | binary(), dynamic(), non_neg_integer()) ->
    {ok, dynamic()} | {error, term()}.
do_with_timeout(Code, St, TimeoutMs) ->
    case asobi_lua_vm:is_handle(St) of
        true ->
            %% Hot reload re-runs the script body against the live state, so
            %% under `owned` it has to happen where the state is. The VM is the
            %% killable thing here, which is the same guard the spawn gave -
            %% except that overrunning now costs the state rather than a copy of
            %% it, so a reload that hangs takes the zone's VM with it and the
            %% bridge rebuilds. That is ADR 0015's stated price, paid on the one
            %% path where the code being run is definitely new.
            case asobi_lua_vm:op(St, {do, Code}, TimeoutMs) of
                ok -> {ok, St};
                {error, _} = Err -> Err
            end;
        false ->
            bounded_eval(fun() -> do_inline(Code, St) end, TimeoutMs)
    end.

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
    case asobi_lua_vm:is_handle(St) of
        true -> asobi_lua_vm:op(St, {is_defined, FuncName}, ?VM_OP_TIMEOUT) =:= true;
        false -> inline_is_defined(FuncName, St)
    end.

inline_is_defined(FuncName, St) ->
    try luerl:get_table_keys([atom_to_binary(FuncName)], St) of
        {ok, nil, _} -> false;
        {ok, _, _} -> true;
        _ -> false
    catch
        _:_ -> false
    end.

%% --- ADR 0015 facade -------------------------------------------------------
%%
%% Each of these takes whatever `new/3` handed the bridge and threads it back,
%% so a bridge reads the same either way. Under `copy` that value is the Luerl
%% state and these are thin wrappers; under `owned` it is a handle and the work
%% happens in the process that owns the state.
%%
%% The returned "state" is deliberately the same value that went in under
%% `owned`: a handle does not change when the state behind it does, which is the
%% entire point - nothing is copied back.

-doc "Encode an Erlang term into the Lua heap, returning an opaque reference.".
-spec encode(term(), dynamic()) -> {term(), dynamic()}.
encode(Term, St) ->
    case asobi_lua_vm:is_handle(St) of
        false ->
            luerl:encode(Term, St);
        true ->
            case asobi_lua_vm:op(St, {encode, Term}, ?VM_OP_TIMEOUT) of
                {ok, Ref} -> {Ref, St};
                {error, _} -> {nil, St}
            end
    end.

-doc "Decode an opaque Lua reference back to an Erlang term.".
-spec decode(dynamic(), dynamic()) -> term().
decode(Ref, St) ->
    case asobi_lua_vm:is_handle(St) of
        false ->
            luerl:decode(Ref, St);
        true ->
            case asobi_lua_vm:op(St, {decode, Ref}, ?VM_OP_TIMEOUT) of
                {ok, Term} -> Term;
                {error, _} -> nil
            end
    end.

-spec get_table_key(dynamic(), dynamic(), dynamic()) -> {ok, term(), dynamic()} | term().
get_table_key(Tab, Key, St) ->
    case asobi_lua_vm:is_handle(St) of
        false ->
            luerl:get_table_key(Tab, Key, St);
        true ->
            case asobi_lua_vm:op(St, {get_table_key, Tab, Key}, ?VM_OP_TIMEOUT) of
                {ok, Value} -> {ok, Value, St};
                Other -> Other
            end
    end.

-spec get_table_keys([dynamic()], dynamic()) -> {ok, term(), dynamic()} | term().
get_table_keys(Path, St) ->
    case asobi_lua_vm:is_handle(St) of
        false ->
            luerl:get_table_keys(Path, St);
        true ->
            case asobi_lua_vm:op(St, {get_table_keys, Path}, ?VM_OP_TIMEOUT) of
                {ok, Value} -> {ok, Value, St};
                Other -> Other
            end
    end.

-spec set_table_keys([dynamic()], dynamic(), dynamic()) -> {ok, dynamic()} | term().
set_table_keys(Path, Value, St) ->
    case asobi_lua_vm:is_handle(St) of
        false ->
            luerl:set_table_keys(Path, Value, St);
        true ->
            case asobi_lua_vm:op(St, {set_table_keys, Path, Value}, ?VM_OP_TIMEOUT) of
                ok -> {ok, St};
                Other -> Other
            end
    end.

-spec call(atom() | [atom() | binary()], [term()], dynamic()) ->
    {ok, [term()], dynamic()} | {error, term()}.
call(FuncName, Args, St) when is_atom(FuncName) ->
    call([atom_to_binary(FuncName)], Args, St);
call(FuncPath, Args, St) ->
    case asobi_lua_vm:is_handle(St) of
        true -> vm_call(FuncPath, Args, St, ?VM_OP_TIMEOUT);
        false -> inline_call(FuncPath, Args, St)
    end.

%% Under `owned` the wall-clock budget IS the gen_server:call timeout, and a
%% timeout kills the VM - see asobi_lua_vm:op/3. `call/3` has no budget of its
%% own by design (it is the unbounded path, used where the caller already has
%% one), so it gets the default rather than none: an unbounded call into another
%% process would hang the zone forever on a script that spins, which is strictly
%% worse than the copying path it replaces.
vm_call(FuncPath, Args, St, Timeout) ->
    case asobi_lua_vm:op(St, {call, FuncPath, Args}, Timeout) of
        {ok, Result} -> {ok, Result, St};
        {error, _} = Err -> Err
    end.

inline_call(FuncPath, Args, St) ->
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
    case asobi_lua_vm:is_handle(St) of
        true -> vm_call(FuncPath, Args, St, TimeoutMs);
        false -> bounded_eval(fun() -> call(FuncPath, Args, St) end, TimeoutMs)
    end.

%% Spawn the work in a child with a bounded wall-clock budget, a bounded
%% heap AND a bounded reduction count, monitor it, and translate the four
%% terminal states the parent might observe into return values:
%%   - normal exit + {Ref, Result} message    → Result
%%   - timeout (we kill it, exit reason `kill`) → {error, timeout}
%%   - VM kills it for heap (exit reason `killed`) → {error, heap_exhausted}
%%   - reduction budget passed (we kill it) → {error, reductions_exhausted}
%% A heap kill happens *before* the worker can send {Ref, _}, so the
%% DOWN message races. We give the message a tiny grace window in case
%% it is in flight.
%%
%% Callers treat all three failures the same way - discard the result, keep
%% the previous Luerl state, log, carry on - so a callback that overruns
%% costs its tick, never the match or the zone. `reductions_exhausted` is a
%% distinct tag only so an operator can tell "burned CPU" apart from "was
%% slow" and from "allocated too much" in the logs.
-spec bounded_eval(fun(() -> R), non_neg_integer()) ->
    R | {error, timeout | heap_exhausted | reductions_exhausted | {worker_exit, term()}}.
bounded_eval(Fun, TimeoutMs) ->
    Self = self(),
    Ref = make_ref(),
    HeapBudget = max_heap_words(),
    {Pid, MonRef} =
        spawn_opt(
            fun() ->
                %% Bound before the body: tuple elements are evaluated in an
                %% unspecified order, so the cap cannot be an argument to the
                %% message it is meant to protect.
                Base = cap_heap_above_state(HeapBudget),
                %% Sent separately, and first. A callback killed on heap, time
                %% or reductions never sends its result - and that is exactly
                %% the state whose size an operator needs, because a bridge
                %% stuck in a failing-tick loop would otherwise stop reporting
                %% at the moment the trouble starts. Nothing has allocated yet
                %% at this point, so this send always lands.
                Self ! {Ref, {state_words, Base}},
                Self ! {Ref, Base, Fun()}
            end,
            %% Full sweeps only. The worker's heap is one big live term (the
            %% copied state) plus whatever the callback allocates on top, so
            %% generational collection has nothing to be clever about: it
            %% promotes the state into an old heap and then keeps re-copying
            %% it. Measured against the same callback: 132ms -> 64ms at a
            %% 13MB state, 218ms -> 98ms at 39MB. It also makes the peak
            %% predictable, which is what lets the cap below be relative.
            [monitor, {fullsweep_after, 0}]
        ),
    Deadline = erlang:monotonic_time(millisecond) + TimeoutMs,
    await_eval(Pid, Ref, MonRef, Deadline, reduction_budget(TimeoutMs)).

%% #536: the cap has to be set from inside the worker, because the term it has
%% to exclude - the persistent Luerl state - is copied in by the spawn before
%% the first instruction runs. Whatever is on the heap at that point is the
%% state the caller handed us; the budget is what the callback may add to it.
%% Nothing can allocate before this runs, so there is no uncapped window.
%%
%% The state is counted twice on purpose. A collection of an all-live heap
%% copies it, so a worker that never allocates a word of its own still needs
%% room for one more copy of what it was handed the moment it collects at all
%% - with `Base + Budget` a large state is killed by its own first GC, which
%% is the bug over again with a different arithmetic. `fullsweep_after = 0`
%% above is what keeps that at one copy rather than an unbounded number of
%% generational ones: measured peak is 1.2-1.5x Base across states from 0.3MB
%% to 39MB, so 2x Base leaves the budget doing the deciding.
-spec cap_heap_above_state(pos_integer()) -> non_neg_integer().
cap_heap_above_state(Budget) ->
    {total_heap_size, Base} = process_info(self(), total_heap_size),
    _ = process_flag(max_heap_size, #{
        size => 2 * Base + Budget,
        kill => true,
        error_logger => true,
        include_shared_binaries => false
    }),
    Base.

await_eval(Pid, Ref, MonRef, Deadline, Budget) ->
    receive
        {Ref, {state_words, Base}} ->
            _ = put(?STATE_WORDS_KEY, Base),
            await_eval(Pid, Ref, MonRef, Deadline, Budget);
        {Ref, _Base, Result} ->
            erlang:demonitor(MonRef, [flush]),
            Result;
        {'DOWN', MonRef, process, Pid, killed} ->
            {error, heap_exhausted};
        {'DOWN', MonRef, process, Pid, Reason} ->
            {error, {worker_exit, Reason}}
    after wait_slice(Deadline, Budget) ->
        case erlang:monotonic_time(millisecond) >= Deadline of
            true ->
                kill_and_settle(Pid, Ref, MonRef, timeout);
            false ->
                case over_budget(Pid, Budget) of
                    true -> kill_and_settle(Pid, Ref, MonRef, reductions_exhausted);
                    false -> await_eval(Pid, Ref, MonRef, Deadline, Budget)
                end
        end
    end.

%% With no reduction budget this is one receive for the whole window, exactly
%% as before the budget existed - the poll costs nothing when it is disabled,
%% and nothing when the eval returns inside the first slice.
wait_slice(Deadline, infinity) ->
    max(0, Deadline - erlang:monotonic_time(millisecond));
wait_slice(Deadline, _Budget) ->
    min(?REDUCTION_POLL_MS, max(0, Deadline - erlang:monotonic_time(millisecond))).

over_budget(Pid, Budget) ->
    case process_info(Pid, reductions) of
        {reductions, N} -> N > Budget;
        %% Already gone: the DOWN is in flight, let the next receive take it.
        undefined -> false
    end.

kill_and_settle(Pid, Ref, MonRef, Reason) ->
    exit(Pid, kill),
    receive
        %% Drain the measurement rather than leaving it in the bridge's
        %% mailbox, and keep it: a killed callback is when its size matters.
        {Ref, {state_words, Base}} ->
            _ = put(?STATE_WORDS_KEY, Base),
            kill_and_settle(Pid, Ref, MonRef, Reason);
        {Ref, _Base, Result} ->
            erlang:demonitor(MonRef, [flush]),
            Result;
        {'DOWN', MonRef, process, Pid, _} ->
            {error, Reason}
    after 0 ->
        erlang:demonitor(MonRef, [flush]),
        {error, Reason}
    end.

-spec reduction_budget(non_neg_integer()) -> pos_integer() | infinity.
reduction_budget(TimeoutMs) ->
    case max_reductions_per_ms() of
        0 -> infinity;
        Rate -> Rate * max(TimeoutMs, 1)
    end.

-spec max_reductions_per_ms() -> non_neg_integer().
max_reductions_per_ms() ->
    case asobi_lua_env:get_env(max_reductions_per_ms) of
        {ok, N} when is_integer(N), N >= 0 -> N;
        _ -> ?DEFAULT_MAX_REDUCTIONS_PER_MS
    end.

-spec max_heap_words() -> pos_integer().
max_heap_words() ->
    case asobi_lua_env:get_env(max_heap_words) of
        {ok, N} when is_integer(N), N > 0 -> N;
        _ -> ?DEFAULT_MAX_HEAP_WORDS
    end.

-doc """
Collect the Luerl state carried in a bridge state map, every so often.

Call this once per tick from a bridge that holds a long-lived `lua_state`,
**before** the tick's own callback. Luerl never collects such a state on its
own, so without this the per-tick `luerl:encode/2` of entities or inputs
accumulates in it forever - and `call/4` copies the whole state into its eval
worker and back on every callback, so the cost of a tick grows with everything
the state has ever allocated. Collect on the calling process: it costs no
extra copy there, and `luerl:gc/1` runs no Lua code so it cannot hang on a
script.

#536: collecting *before* the callback rather than after it is what makes the
collection worth its cost - the expensive moment is the copy, and this is the
last point before it. It also breaks the wedge the collector was added to
prevent but could not: a callback that fails on heap or timeout never reached
a collection placed after it, so the state that caused the failure was carried
into the next tick untouched, and every tick after that failed the same way.

`game_state` is the one Luerl value asobi holds between callbacks. It is
unreachable from the Lua root set while Erlang is between them, so the
collector would free the tables underneath it and the next `luerl:decode/2`
on it would crash. It is rooted in a global for the duration of the collection
and unrooted again straight after, so a script never observes the anchor.

Bookkeeping is kept under `lua_gc` in the same map. Set
`{asobi, [{lua_gc, false}]}` to turn the collector off entirely.
""".
-spec collect_state(map()) -> map().
collect_state(#{lua_state := St} = State) ->
    Gc0 = maps:get(lua_gc, State, new_gc()),
    Words = state_size(St),
    Gc1 = report_state_size(Words, State, Gc0),
    Anchor = maps:get(game_state, State, nil),
    {St1, Gc2} = maybe_gc(St, Anchor, Words, Gc1),
    State#{lua_state => St1, lua_gc => Gc2};
collect_state(State) ->
    State.

%% Size in words of the Luerl state the last bounded callback was handed. Not
%% public, and TEST-only: it belongs to the last bounded call on *this process*,
%% whichever state that was, so it is only meaningful to a caller that knows
%% the call history. `collect_state/1` does, because it runs on the bridge
%% between that bridge's own calls, and it uses `take_state_words/0` below. A
%% process that boots a throwaway VM (`init_zone_state/2` does, to read
%% `spawn_templates`) measures that one instead.
-ifdef(TEST).
-spec state_words() -> non_neg_integer() | undefined.
state_words() ->
    normalise_words(erlang:get(?STATE_WORDS_KEY)).
-endif.

%% Under `copy` the eval worker's heap immediately after the spawn *is* the
%% copied state, so bounded_eval measures it exactly and for free. Under `owned`
%% there is no copy to measure, and the process that holds the state can size
%% itself for the same price - which is the one measurement that got cheaper
%% rather than harder under ADR 0015.
state_size(St) ->
    case asobi_lua_vm:is_handle(St) of
        false ->
            take_state_words();
        true ->
            case asobi_lua_vm:op(St, state_words, ?VM_OP_TIMEOUT) of
                {ok, Words} -> Words;
                {error, _} -> undefined
            end
    end.

%% Consume rather than read: a value left behind outlives the call it belongs
%% to, and `gc_budget_us/1` acts on it, so staleness is not merely cosmetic.
%% With collect-before-callback the order is collect (take) then call (write),
%% so a bridge that ticks always has a fresh one and nothing is lost.
take_state_words() ->
    normalise_words(erlang:erase(?STATE_WORDS_KEY)).

normalise_words(N) when is_integer(N), N >= 0 -> N;
normalise_words(_) -> undefined.

new_gc() ->
    #{interval => ?GC_MIN_INTERVAL, countdown => ?GC_MIN_INTERVAL, enabled => true}.

%% #536: before this, a state's size was invisible until zones started dying
%% of it - there was no metric to alert on and no number in the logs. The
%% sample rides on `collect_state/1` rather than on a collection, because the
%% collector's interval is adaptive and can be off entirely.
report_state_size(undefined, _State, Gc) ->
    Gc;
report_state_size(Words, State, Gc) ->
    Now = erlang:monotonic_time(millisecond),
    %% Defaulting the deadline to `Now` rather than 0 makes the first call
    %% sample: monotonic time has an arbitrary origin and is routinely
    %% negative, so 0 is a deadline in the future on a fresh node.
    Gc1 =
        case Now >= maps:get(sample_at, Gc, Now) of
            true ->
                asobi_telemetry:lua_state_size(bridge_meta(State), Words),
                Gc#{sample_at => Now + state_sample_interval_ms()};
            false ->
                Gc
        end,
    warn_large_state(Words, State, Gc1).

%% ADR 0005: `script` is the label-safe one and `kind` is a fixed enum; the
%% world/zone/match identifiers are unbounded and are metadata only. Without
%% them every live zone reports under one identical label set, which reads as a
%% single flapping gauge rather than one series per bridge.
bridge_meta(State) ->
    Meta = maps:get(lua_bridge, State, #{}),
    Meta#{script => maps:get(script, State, undefined)}.

-spec state_sample_interval_ms() -> non_neg_integer().
state_sample_interval_ms() ->
    case asobi_lua_env:get_env(state_sample_interval_ms) of
        {ok, N} when is_integer(N), N >= 0 -> N;
        _ -> ?DEFAULT_STATE_SAMPLE_INTERVAL_MS
    end.

-spec state_warn_words() -> non_neg_integer().
state_warn_words() ->
    case asobi_lua_env:get_env(state_warn_words) of
        {ok, N} when is_integer(N), N >= 0 -> N;
        _ -> ?DEFAULT_STATE_WARN_WORDS
    end.

%% One warning per excursion, not per state: `warned` is cleared again once the
%% state comes back under the threshold, so a state that crosses it twice says
%% so twice. The clearing point is 10% below the warning point rather than the
%% same number - `collect_state/1` runs every tick, so without the gap a state
%% hovering on the threshold logs on every upward crossing, which is once a
%% tick. A threshold of 0 silences it.
warn_large_state(Words, State, Gc) ->
    Threshold = state_warn_words(),
    Warned = maps:get(warned, Gc, false),
    Over =
        case Warned of
            true -> Words >= Threshold * 9 div 10;
            false -> Words >= Threshold
        end,
    case Threshold > 0 andalso Over of
        false when Warned ->
            Gc#{warned => false};
        false ->
            Gc;
        true ->
            case Warned of
                true ->
                    Gc;
                false ->
                    ?LOG_WARNING(#{
                        event => lua_state_large,
                        state_words => Words,
                        state_mb => (Words * erlang:system_info(wordsize)) div 1048576,
                        script => maps:get(script, State, undefined),
                        msg =>
                            ~"The Luerl state behind this bridge is large enough that copying it into each bounded callback dominates the tick. Every callback pays it. Reduce what the script keeps alive between callbacks."
                    }),
                    Gc#{warned => true}
            end
    end.

maybe_gc(St, Anchor, Words, #{enabled := false, retry_at := At} = Gc) ->
    case erlang:monotonic_time(millisecond) >= At of
        true -> maybe_gc(St, Anchor, Words, Gc#{enabled := true, countdown => 1});
        false -> {St, Gc}
    end;
maybe_gc(St, _Anchor, _Words, #{enabled := false} = Gc) ->
    {St, Gc};
maybe_gc(St, _Anchor, _Words, #{countdown := N} = Gc) when N > 1 ->
    {St, Gc#{countdown := N - 1}};
maybe_gc(St, Anchor, Words, #{interval := Interval} = Gc) ->
    case gc_disabled() of
        true ->
            %% Dropping `retry_at` matters: leaving it makes the re-arm clause
            %% above match on every tick, so a bridge with the collector
            %% switched off pays an application:get_env per tick forever
            %% instead of short-circuiting on `enabled := false`.
            {St, maps:remove(retry_at, Gc#{enabled := false})};
        false ->
            {Us, St1} = timer:tc(fun() -> do_collect(St, Anchor) end),
            {St1, next_gc(Us, gc_budget_us(Words), Interval, Gc)}
    end.

%% The scheduling decision stays here on the bridge; only the collection itself
%% has to move, because under `owned` the state is not here to collect.
do_collect(St, Anchor) ->
    case asobi_lua_vm:is_handle(St) of
        true ->
            _ = asobi_lua_vm:op(St, {gc, Anchor}, ?VM_OP_TIMEOUT),
            St;
        false ->
            collect(St, Anchor)
    end.

%% What one collection may cost, in us. Scales with the state so that the
%% interval only backs off when collecting really is worse than carrying the
%% garbage - see ?GC_BUDGET_WORDS_PER_US.
-spec gc_budget_us(non_neg_integer() | undefined) -> pos_integer().
gc_budget_us(undefined) ->
    ?GC_BUDGET_US;
gc_budget_us(Words) when is_integer(Words) ->
    case Words div ?GC_BUDGET_WORDS_PER_US of
        Scaled when Scaled > ?GC_BUDGET_CEILING_US -> ?GC_BUDGET_CEILING_US;
        Scaled when Scaled > ?GC_BUDGET_US -> Scaled;
        _ -> ?GC_BUDGET_US
    end.

next_gc(Us, _Budget, Interval, Gc) when Us > ?GC_ABANDON_US ->
    ?LOG_WARNING(#{
        event => lua_gc_abandoned,
        duration_ms => Us div 1000,
        msg =>
            ~"Luerl collection outran a tick budget and is now off for this state. Luerl's collector is quadratic in the live set, so a script holding a large table across callbacks cannot be collected cheaply. Lua memory here will grow unbounded until the script keeps less alive across callbacks."
    }),
    Gc#{
        enabled := false,
        countdown := Interval,
        retry_at => erlang:monotonic_time(millisecond) + ?GC_RETRY_MS
    };
next_gc(Us, Budget, Interval, Gc) ->
    Interval1 =
        if
            Us > Budget -> min(?GC_MAX_INTERVAL, Interval * 2);
            Us < Budget div 4 -> max(?GC_MIN_INTERVAL, Interval div 2);
            true -> Interval
        end,
    Gc#{interval := Interval1, countdown := Interval1}.

%% The anchor is asobi's bookkeeping, not the script's data, so it is written
%% raw. The metamethod-honouring setter would run a script's `_G` `__newindex`
%% on the bridge gen_server, outside `bounded_eval`, on every collection - see
%% `guides/security-trust-model.md`. A raw write cannot fail and cannot run
%% script code, which is why there is no longer an "anchor failed" path.
%% `luerl_heap` is internal to luerl, hence the patch-range pin on the dep;
%% asobi already depends on `luerl_lib` the same way.
collect(St, Anchor) ->
    unanchor(luerl:gc(raw_anchor(Anchor, St))).

-doc """
Collect now, rooting `Anchor` across it.

Public only for `asobi_lua_vm`, which owns the state under ADR 0015 and so is
the only process that can run a collection on it. The adaptive scheduling that
decides *whether* to collect stays with the bridge in `collect_state/1`; this is
just the collection.
""".
-spec gc_now(term(), dynamic()) -> dynamic().
gc_now(Anchor, St) ->
    collect(St, Anchor).

unanchor(St) ->
    raw_anchor(nil, St).

raw_anchor(Value, St) ->
    raw_anchor_key(?GC_ANCHOR, Value, St).

raw_anchor_key(Key, Value, #luerl{g = G} = St) ->
    luerl_heap:raw_set_table_key(G, Key, Value, St).

-doc """
Root a Luerl reference in `_G` for as long as Erlang holds it between calls.

Luerl's root set is `_G`, the stack and the live call frames, so a table that
Erlang is carrying across `call/3` is reachable only while some frame happens to
name it. A script that ignores an argument - `function handle_input(p, i)` when
three were passed - drops it from the frame. If anything then collects, the
table is freed, its slot returns to the free list, and the next
`luerl:encode/2` recycles it: the reference Erlang still holds now aliases
somebody else's data.

`collectgarbage` is stripped from the sandbox, so no script can force that
today, and this is the second layer rather than the only one. It is still the
load-bearing one, because the strip closes one reachable path while this closes
the class: any Erlang-side collection between two calls - which ADR 0015 makes
the normal shape by holding refs across every call - has the same effect.

Anchoring costs one raw `_G` write. Raw, for the reason `collect/2` gives: the
metamethod-honouring setter would run a script's `__newindex` on the bridge
process, outside `bounded_eval`.

Pair every `anchor_ref/2` with an `unanchor_ref/1`, or the anchored table stays
reachable and no collection can reclaim it.
""".
-spec anchor_ref(term(), dynamic()) -> dynamic().
anchor_ref(Value, St) ->
    case asobi_lua_vm:is_handle(St) of
        true ->
            _ = asobi_lua_vm:op(St, {anchor_ref, Value}, ?VM_OP_TIMEOUT),
            St;
        false ->
            raw_anchor_key(?REF_ANCHOR, Value, St)
    end.

-doc "Drop the `anchor_ref/2` root.".
-spec unanchor_ref(dynamic()) -> dynamic().
unanchor_ref(St) ->
    case asobi_lua_vm:is_handle(St) of
        true ->
            _ = asobi_lua_vm:op(St, unanchor_ref, ?VM_OP_TIMEOUT),
            St;
        false ->
            raw_anchor_key(?REF_ANCHOR, nil, St)
    end.

-doc """
Is `Value` still the value `anchor_ref/2` rooted?

The raw write cannot be intercepted by a script's `_G` metatable, but the slot
it writes to lives in `_G`, which scripts can assign to. `__asobi_ref_anchor =
nil` from Lua drops asobi's root, and anything Erlang still holds is then one
collection away from naming a recycled slot. A caller carrying a reference
across `call/3` therefore has to re-check rather than assume, and treat `false`
as "nothing I am holding is safe to decode".
""".
-spec ref_anchored(term(), dynamic()) -> boolean().
ref_anchored(Value, St) ->
    case asobi_lua_vm:is_handle(St) of
        true -> asobi_lua_vm:op(St, {ref_anchored, Value}, ?VM_OP_TIMEOUT) =:= true;
        false -> inline_ref_anchored(Value, St)
    end.

inline_ref_anchored(Value, #luerl{g = G} = St) ->
    luerl_heap:raw_get_table_key(G, ?REF_ANCHOR, St) =:= Value.

gc_disabled() ->
    asobi_lua_env:get_env(lua_gc) =:= {ok, false}.

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
    %% `collectgarbage` is stripped for two reasons, both in
    %% `guides/security-sandbox.md`: it is a synchronous, superlinear
    %% mark-and-sweep on the shared zone process, and it lets a script decide
    %% when references asobi holds between calls are freed. asobi collects on
    %% its own schedule through `luerl:gc/1`, which is Erlang-side.
    Paths = [
        [~"collectgarbage"],
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
