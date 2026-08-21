-module(asobi_lua_vm_spike).
-moduledoc """
#536 spike, not shipped: a gen_server that owns the Luerl state so callbacks
stop copying it.

Today `asobi_lua_loader:call/4` spawns a worker per callback and the spawn
copies the whole persistent state into it - measured at ~7 ms per MB, which is
the dominant cost of a Lua tick and the reason a zone with a large state stops
ticking. Here the state never moves: the bridge holds a pid and opaque Luerl
refs, and every `luerl:*` call the bridge used to make on its own heap becomes
a small message to the process that owns the state.

What this exists to measure is the cost of moving `asobi_lua_world`,
`asobi_lua_match` and `asobi_lua_api` onto that shape - roughly 50 direct
`luerl:*` call sites - not to be that shape.
""".
-behaviour(gen_server).

-export([start_link/1, call/3, encode/2, decode/2, get_table_keys/2, stop/1]).
-export([init/1, handle_call/3, handle_cast/2]).

start_link(LuaSt) ->
    gen_server:start_link(?MODULE, LuaSt, []).

call(Vm, FuncPath, Args) ->
    gen_server:call(Vm, {call, FuncPath, Args}, 5000).

encode(Vm, Term) ->
    gen_server:call(Vm, {encode, Term}, 5000).

decode(Vm, Ref) ->
    gen_server:call(Vm, {decode, Ref}, 5000).

get_table_keys(Vm, Path) ->
    gen_server:call(Vm, {get_table_keys, Path}, 5000).

stop(Vm) ->
    gen_server:stop(Vm).

init(LuaSt) ->
    {ok, #{lua_state => LuaSt}}.

handle_call({call, FuncPath, Args}, _From, #{lua_state := St} = S) ->
    case asobi_lua_loader:call(FuncPath, Args, St) of
        {ok, Rets, St1} -> {reply, {ok, Rets}, S#{lua_state => St1}};
        {error, _} = E -> {reply, E, S}
    end;
handle_call({encode, Term}, _From, #{lua_state := St} = S) ->
    {Ref, St1} = luerl:encode(Term, St),
    {reply, Ref, S#{lua_state => St1}};
handle_call({decode, Ref}, _From, #{lua_state := St} = S) ->
    {reply, luerl:decode(Ref, St), S};
handle_call({get_table_keys, Path}, _From, #{lua_state := St} = S) ->
    {ok, Value, St1} = luerl:get_table_keys(Path, St),
    {reply, Value, S#{lua_state => St1}}.

handle_cast(_, S) ->
    {noreply, S}.
