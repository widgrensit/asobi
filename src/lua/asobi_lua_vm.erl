-module(asobi_lua_vm).
-moduledoc """
A process that owns one Luerl state, so a callback stops costing a copy of it.

ADR 0015. Every bounded Lua callback used to run in a process spawned per call
(`asobi_lua_loader`'s `bounded_eval/2`), and the spawn copied the closure - which
holds the whole persistent Luerl state - into the new process and back. That
made the cost of a callback linear in the size of the state rather than in the
work it does: roughly 7 ms per MB, before the script runs a line. Measured on an
empty zone with an inert `zone_tick`, the copy was ~765 of the 883 reductions
the whole bridge spent per tick.

Here the state does not move. The bridge holds a pid and opaque Luerl
references, and every `luerl:*` operation becomes a small message to the process
that owns the state. The cost becomes O(work) instead of O(state).

**The protocol is closed on purpose.** A caller sends an operation tuple, never
a function - a `fun` crossing a module boundary cannot be checkpointed, and
would defeat any future snapshot of a VM (see the project's own rule, and ADR
0015's rejection of the Luerl trace-hook alternative for the same reason).

**What this costs, and it is the whole argument.** Under the copying path the
process killed on a timeout, heap or reduction overrun was a throwaway, so a
runaway callback cost one tick and the zone carried on. Here the only killable
thing is the process holding the state, so an overrun kills the state. What
comes back and from where is the caller's problem: `asobi_lua_world` rebuilds a
zone from its script and last snapshot, which is a path zones already had.

Selected by `lua_vm_mode` and **off by default** - see
`asobi_lua_loader:vm_mode/0`.
""".
-behaviour(gen_server).

-export([start_link/1, stop/1, is_alive/1, is_handle/1]).
-export([op/3]).
-export([init/1, handle_call/3, handle_cast/2, terminate/2]).

-include_lib("kernel/include/logger.hrl").

-export_type([handle/0, op/0]).

-opaque handle() :: {?MODULE, pid()}.

%% The closed set of things a bridge may ask of the state it no longer holds.
%% Luerl references are `dynamic()` throughout asobi for the same reason they
%% are here: they are opaque handles into a heap the type checker cannot see.
-type op() ::
    {encode, term()}
    | {decode, dynamic()}
    | {get_table_key, dynamic(), dynamic()}
    | {get_table_keys, [dynamic()]}
    | {set_table_keys, [dynamic()], dynamic()}
    | {call, atom() | [atom() | binary()], [dynamic()]}
    | {is_defined, atom()}
    | {do, string() | binary()}
    | {anchor_ref, dynamic()}
    | unanchor_ref
    | {ref_anchored, dynamic()}
    | {gc, dynamic()}
    | revert
    | state_words.

-spec start_link(dynamic()) -> {ok, handle()} | {error, term()}.
start_link(LuaSt) ->
    case gen_server:start_link(?MODULE, LuaSt, []) of
        {ok, Pid} -> {ok, {?MODULE, Pid}};
        {error, _} = Err -> Err
    end.

-spec stop(handle()) -> ok.
stop({?MODULE, Pid}) when is_pid(Pid) ->
    try
        gen_server:stop(Pid)
    catch
        %% Already gone, or going. Stopping a VM is cleanup, never a decision.
        exit:_ -> ok
    end,
    ok.

-doc """
Is this an owned-VM handle at all - alive or not?

Dispatch is on the *shape*, never on liveness. A handle whose VM has died is
still a handle, and treating it as a raw Luerl state (which is what asking
`is_alive/1` would do) hands a tuple to `luerl:encode/2` and crashes the caller
instead of reporting `{error, vm_down}`.
""".
-spec is_handle(handle() | term()) -> boolean().
is_handle({?MODULE, Pid}) -> is_pid(Pid);
is_handle(_) -> false.

-spec is_alive(handle() | term()) -> boolean().
is_alive({?MODULE, Pid}) -> is_pid(Pid) andalso is_process_alive(Pid);
is_alive(_) -> false.

-doc """
Run one operation against the owned state.

`{error, vm_down}` and `{error, timeout}` are ordinary answers, not exceptions:
the caller is a zone or match tick and must keep running whatever the script
did. A timeout kills the VM on the way out, because a `gen_server:call` that
timed out leaves the server still working on the request - and a Lua callback
that has outrun its budget is exactly the thing that must not carry on holding
the state.
""".
-spec op(handle() | term(), op(), timeout()) -> term() | {error, vm_down | timeout}.
op({?MODULE, Pid}, Op, Timeout) when is_pid(Pid) ->
    try
        gen_server:call(Pid, Op, Timeout)
    catch
        exit:{noproc, _} ->
            {error, vm_down};
        exit:{normal, _} ->
            {error, vm_down};
        exit:{shutdown, _} ->
            {error, vm_down};
        exit:{{shutdown, _}, _} ->
            {error, vm_down};
        exit:{timeout, _} ->
            _ = exit(Pid, kill),
            {error, timeout}
    end;
op(_NotAHandle, _Op, _Timeout) ->
    {error, vm_down}.

%% --- gen_server ---

-spec init(dynamic()) -> {ok, map()}.
init(LuaSt) ->
    %% For the first time the cap means what it says. Under the copying path an
    %% absolute `max_heap_size` bounded the *eval worker*, which held a copy;
    %% the real state lived in the parent and survived the kill untouched, so a
    %% 690 MB state was 690 MB before and after. Here the capped process is the
    %% one holding the state, so the number is a ceiling on the state itself.
    ok = cap_heap(asobi_lua_loader:vm_max_heap_words()),
    {ok, #{lua_state => LuaSt, prev => LuaSt}}.

-spec cap_heap(non_neg_integer()) -> ok.
cap_heap(0) ->
    ok;
cap_heap(Words) ->
    _ = process_flag(max_heap_size, #{size => Words, kill => true, error_logger => true}),
    ok.

-spec handle_call(op(), gen_server:from(), map()) -> {reply, term(), map()}.
handle_call({encode, Term}, _From, #{lua_state := St} = S) ->
    {Ref, St1} = luerl:encode(Term, St),
    {reply, {ok, Ref}, S#{lua_state => St1}};
handle_call({decode, Ref}, _From, #{lua_state := St} = S) ->
    {reply, {ok, luerl:decode(Ref, St)}, S};
handle_call({get_table_key, Tab, Key}, _From, #{lua_state := St} = S) ->
    case luerl:get_table_key(Tab, Key, St) of
        {ok, Value, St1} -> {reply, {ok, Value}, S#{lua_state => St1}};
        Other -> {reply, Other, S}
    end;
handle_call({get_table_keys, Path}, _From, #{lua_state := St} = S) ->
    case luerl:get_table_keys(Path, St) of
        {ok, Value, St1} -> {reply, {ok, Value}, S#{lua_state => St1}};
        Other -> {reply, Other, S}
    end;
handle_call({set_table_keys, Path, Value}, _From, #{lua_state := St} = S) ->
    case luerl:set_table_keys(Path, Value, St) of
        {ok, St1} -> {reply, ok, S#{lua_state => St1}};
        Other -> {reply, Other, S}
    end;
%% The pre-call state is kept so `revert` can put it back. That costs nothing:
%% a Luerl state is immutable and the post-call one shares structure with it, so
%% what is retained is exactly what the call changed - which is exactly what a
%% revert has to be able to undo. This is not the "snapshot before each risky
%% callback" that ADR 0015 rejects; that one is a copy, this one is a pointer.
%%
%% A raising call keeps the pre-call state as it stands, which is what the
%% copying path did by discarding the state the failed call produced.
handle_call({call, FuncPath, Args}, _From, #{lua_state := St} = S) ->
    case asobi_lua_loader:call(FuncPath, Args, St) of
        {ok, Result, St1} -> {reply, {ok, Result}, S#{lua_state => St1, prev => St}};
        {error, Reason} -> {reply, {error, Reason}, S}
    end;
handle_call(revert, _From, #{prev := Prev} = S) ->
    {reply, ok, S#{lua_state => Prev}};
handle_call({is_defined, Name}, _From, #{lua_state := St} = S) ->
    {reply, asobi_lua_loader:is_defined(Name, St), S};
handle_call({do, Code}, _From, #{lua_state := St} = S) ->
    case asobi_lua_loader:do_inline(Code, St) of
        {ok, St1} -> {reply, ok, S#{lua_state => St1}};
        {error, _} = Err -> {reply, Err, S}
    end;
handle_call({anchor_ref, Value}, _From, #{lua_state := St} = S) ->
    {reply, ok, S#{lua_state => asobi_lua_loader:anchor_ref(Value, St)}};
handle_call(unanchor_ref, _From, #{lua_state := St} = S) ->
    {reply, ok, S#{lua_state => asobi_lua_loader:unanchor_ref(St)}};
handle_call({ref_anchored, Value}, _From, #{lua_state := St} = S) ->
    {reply, asobi_lua_loader:ref_anchored(Value, St), S};
handle_call({gc, Anchor}, _From, #{lua_state := St} = S) ->
    {reply, ok, S#{lua_state => asobi_lua_loader:gc_now(Anchor, St)}};
handle_call(state_words, _From, #{lua_state := _} = S) ->
    %% Measured on this process, which *is* the state - no copy to size.
    {total_heap_size, Words} = process_info(self(), total_heap_size),
    {reply, {ok, Words}, S};
handle_call(_Unknown, _From, S) ->
    {reply, {error, unknown_op}, S}.

-spec handle_cast(term(), map()) -> {noreply, map()}.
handle_cast(_Msg, S) ->
    {noreply, S}.

-spec terminate(term(), map()) -> ok.
terminate(Reason, _S) when Reason =/= normal, Reason =/= shutdown ->
    ?LOG_WARNING(#{event => lua_vm_terminated, reason => Reason}),
    ok;
terminate(_Reason, _S) ->
    ok.
