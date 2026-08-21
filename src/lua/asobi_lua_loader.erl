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
-export([collect_state/1, state_words/0]).
-ifdef(TEST).
-export([next_gc/4, gc_budget_us/1]).
-endif.

-export_type([pre_install/0]).

-type pre_install() :: fun((dynamic()) -> dynamic()).

-include_lib("kernel/include/file.hrl").
-include_lib("kernel/include/logger.hrl").

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
%% `collectgarbage()` from Lua or `luerl:gc/1` from Erlang reclaims anything.
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
%% The scaled budget has to stay under the abandon ceiling, because the
%% abandon clause is tested first: a budget above it makes the "this
%% collection overran, back off" branch unreachable, and then every
%% collection that does not abandon looks cheap and drives the interval
%% down to its minimum. That inverts the whole loop on the largest states -
%% exactly the ones #536 is about - so the ceiling is load-bearing, not a
%% tidy-up. A quarter leaves the back-off a working range either side.
-define(GC_BUDGET_CEILING_US, (?GC_ABANDON_US div 4)).
-define(GC_ANCHOR, ~"__asobi_gc_anchor").

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
%% spawn round-trip (it is not a sandbox boundary, see
%% guides/security-trust-model.md).
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
        {Ref, StateWords, Result} ->
            erlang:demonitor(MonRef, [flush]),
            _ = put(?STATE_WORDS_KEY, StateWords),
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
        {Ref, StateWords, Result} ->
            erlang:demonitor(MonRef, [flush]),
            _ = put(?STATE_WORDS_KEY, StateWords),
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
    Words = take_state_words(),
    Gc1 = report_state_size(Words, State, Gc0),
    Anchor = maps:get(game_state, State, nil),
    {St1, Gc2} = maybe_gc(St, Anchor, Words, Gc1),
    State#{lua_state => St1, lua_gc => Gc2};
collect_state(State) ->
    State.

-doc """
Size in words of the Luerl state the last bounded callback was handed, or
`undefined` before one has run on this process.

`call/4` spawns a worker and the spawn copies the state into it, so the
worker's heap at its first instruction is that state, exactly, and reading it
there costs nothing. Sizing the same term on the calling side would mean
walking it. Callbacks that run inline (`call/3`, and `handle_input`, which is
not a sandbox boundary - see `guides/security-trust-model.md`) never spawn, so
they do not refresh this; on a bridge that ticks, the tick does.

It belongs to **the last bounded call on this process, whichever state that
was**, not necessarily to the state you are holding. A process that boots a
throwaway VM - `asobi_lua_world:init_zone_state/2` does, to read
`spawn_templates` - measures that one. `collect_state/1` consumes the value
rather than reading it, so a stale measurement can be attributed at most once.
""".
-spec state_words() -> non_neg_integer() | undefined.
state_words() ->
    normalise_words(erlang:get(?STATE_WORDS_KEY)).

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
%% so twice. A threshold of 0 silences it.
warn_large_state(Words, State, Gc) ->
    Threshold = state_warn_words(),
    case Threshold > 0 andalso Words >= Threshold of
        false ->
            Gc#{warned => false};
        true ->
            case maps:get(warned, Gc, false) of
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

maybe_gc(St, _Anchor, _Words, #{enabled := false} = Gc) ->
    {St, Gc};
maybe_gc(St, _Anchor, _Words, #{countdown := N} = Gc) when N > 1 ->
    {St, Gc#{countdown := N - 1}};
maybe_gc(St, Anchor, Words, #{interval := Interval} = Gc) ->
    case gc_disabled() of
        true ->
            {St, Gc#{enabled := false}};
        false ->
            {Us, St1} = timer:tc(fun() -> collect(St, Anchor) end),
            {St1, next_gc(Us, gc_budget_us(Words), Interval, Gc)}
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
    Gc#{enabled := false, countdown := Interval};
next_gc(Us, Budget, Interval, Gc) ->
    Interval1 =
        if
            Us > Budget -> min(?GC_MAX_INTERVAL, Interval * 2);
            Us < Budget div 4 -> max(?GC_MIN_INTERVAL, Interval div 2);
            true -> Interval
        end,
    Gc#{interval := Interval1, countdown := Interval1}.

%% A failed anchor leaves the state exactly as it was: skipping a collection
%% costs memory, collecting without the anchor corrupts the caller's refs.
collect(St, Anchor) ->
    case anchor(Anchor, St) of
        {ok, St1} -> unanchor(luerl:gc(St1));
        error -> St
    end.

anchor(Anchor, St) ->
    case luerl:set_table_keys([?GC_ANCHOR], Anchor, St) of
        {ok, St1} -> {ok, St1};
        _ -> error
    end.

unanchor(St) ->
    case luerl:set_table_keys([?GC_ANCHOR], nil, St) of
        {ok, St1} -> St1;
        _ -> St
    end.

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
