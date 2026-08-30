-module(asobi_kv).
-behaviour(gen_server).

-moduledoc """
A node-local, in-memory key-value store for state that has to outlive the zone
holding it, at tick rate.

## Why this exists

A world with entities that cross the map - a freighter on a trade route, a
patrol, a convoy - needs per-entity state that survives the zone. Position can
be a pure function of a clock and needs no storage; hull points, "this one is
already dead", "it has shed 4 of its 10 containers" cannot be recomputed from
anything.

Neither place a zone script already has works for that. The zone's entity map
goes with the zone. A table in the zone's Lua VM is one copy per zone and goes
with the VM. And `game.storage` - which has exactly the right semantics - is a
synchronous database read-modify-write with no atomic update, executed inside a
callback budgeted in milliseconds. Fine for "save the sector's config at boot";
not usable for "this ship just took 40 damage" (widgrensit/asobi#572).

## What it promises, and what it does not

- **In memory, on one node.** Lost on restart, and never replicated: a world
  lives entirely on one node, so this is per world in practice. Say it out
  loud in your design - anything that must survive a deploy belongs in
  `game.storage`.
- **Atomic merges.** Every write goes through this process, so a
  read-modify-write cannot interleave. Combined with the commutative operators
  in `m:asobi_merge_ops`, two zones holding the same entity across a seam can
  both apply what they saw without a lock, a version or a lost write.
- **Reads do not touch this process.** `get/3` is an ETS read from the calling
  process, so a zone tick reading state pays no message round trip.
- **Scoped per world or match.** The scope comes from the calling VM, so two
  worlds running the same mode script cannot collide on the same key.
- **TTL'd.** Every write refreshes the entry's expiry, so state in active use
  never ages out; state nothing has touched for `kv_ttl_seconds` (an hour by
  default) is swept. That is what keeps a long-lived node from accumulating
  one entry per entity that ever existed.
""".

-export([start_link/0]).
-export([get/3, set/4, set/5, merge/4, merge/5, delete/3]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-include_lib("kernel/include/logger.hrl").

-define(TABLE, asobi_kv).
-define(SWEEP_INTERVAL, 60_000).
-define(DEFAULT_TTL_SECONDS, 3600).
-define(DEFAULT_MAX_KEYS, 100_000).
-define(CALL_TIMEOUT, 5_000).

-type scope() :: binary().

%% --- Public API ---

-spec start_link() -> gen_server:start_ret().
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-doc """
Read a key. An ETS read in the calling process - no message to this server.

An entry past its expiry reads as `not_found` whether or not the sweep has got
to it yet, so a caller never sees a value the TTL says is gone.
""".
-spec get(scope(), binary(), binary()) -> {ok, map()} | not_found.
get(Scope, Collection, Key) ->
    try ets:lookup(?TABLE, {Scope, Collection, Key}) of
        [{_K, Value, ExpiresAt}] when is_map(Value) ->
            case expired(ExpiresAt) of
                true -> not_found;
                false -> {ok, Value}
            end;
        _ ->
            not_found
    catch
        %% The table is gone: this server is restarting, or it never started
        %% (a release that does not run asobi_sup's engine children). A miss is
        %% the honest answer for a store that promises nothing across a
        %% restart anyway.
        error:badarg -> not_found
    end.

-spec set(scope(), binary(), binary(), map()) -> ok | {error, term()}.
set(Scope, Collection, Key, Value) ->
    set(Scope, Collection, Key, Value, default_ttl()).

-spec set(scope(), binary(), binary(), map(), pos_integer()) -> ok | {error, term()}.
set(Scope, Collection, Key, Value, TtlSeconds) when is_map(Value) ->
    call_unit({set, {Scope, Collection, Key}, Value, TtlSeconds}).

-doc """
Apply `m:asobi_merge_ops` to the value at this key and return the result,
creating the entry from `#{}` if it is absent.

A call, not a cast: a caller merging damage into a shared entity almost always
needs to know what the value became - whether that was the hit that killed it -
and a cast cannot answer that.
""".
-spec merge(scope(), binary(), binary(), map()) -> {ok, map()} | {error, term()}.
merge(Scope, Collection, Key, Ops) ->
    merge(Scope, Collection, Key, Ops, default_ttl()).

-spec merge(scope(), binary(), binary(), map(), pos_integer()) -> {ok, map()} | {error, term()}.
merge(Scope, Collection, Key, Ops, TtlSeconds) when is_map(Ops) ->
    call_map({merge, {Scope, Collection, Key}, Ops, TtlSeconds}).

-spec delete(scope(), binary(), binary()) -> ok | {error, term()}.
delete(Scope, Collection, Key) ->
    call_unit({delete, {Scope, Collection, Key}}).

%% --- gen_server callbacks ---

-spec init([]) -> {ok, map()}.
init([]) ->
    %% Public and read_concurrency: get/3 reads it straight from the caller.
    %% Writes all come through this process, which is what makes a merge
    %% atomic without a lock.
    _ = ets:new(?TABLE, [set, public, named_table, {read_concurrency, true}]),
    schedule_sweep(),
    {ok, #{}}.

-spec handle_call(term(), gen_server:from(), map()) -> {reply, term(), map()}.
handle_call({set, Key, Value, TtlSeconds}, _From, State) ->
    case admit(Key) of
        ok ->
            ets:insert(?TABLE, {Key, Value, expires_at(TtlSeconds)}),
            {reply, ok, State};
        {error, _} = Err ->
            {reply, Err, State}
    end;
handle_call({merge, Key, Ops, TtlSeconds}, _From, State) when is_map(Ops) ->
    case admit(Key) of
        ok ->
            case asobi_merge_ops:apply_ops(current(Key), Ops) of
                {ok, Merged} ->
                    ets:insert(?TABLE, {Key, Merged, expires_at(TtlSeconds)}),
                    {reply, {ok, Merged}, State};
                {error, _} = Err ->
                    {reply, Err, State}
            end;
        {error, _} = Err ->
            {reply, Err, State}
    end;
handle_call({delete, Key}, _From, State) ->
    ets:delete(?TABLE, Key),
    {reply, ok, State};
handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

-spec handle_cast(term(), map()) -> {noreply, map()}.
handle_cast(_Msg, State) ->
    {noreply, State}.

-spec handle_info(term(), map()) -> {noreply, map()}.
handle_info(sweep, State) ->
    Now = now_ms(),
    _ = ets:select_delete(?TABLE, [{{'_', '_', '$1'}, [{'<', '$1', Now}], [true]}]),
    schedule_sweep(),
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

%% --- Internal ---

%% A cap, because nothing here has an owner that outlives it: an entry is
%% dropped by its TTL or by nothing at all, and a game that mints a key per
%% projectile would otherwise grow this table until the node died. An existing
%% key is always writable - the cap bounds distinct keys, it does not stop a
%% game updating what it already has.
%% Takes the key off the call payload, which gen_server types as term().
-spec admit(term()) -> ok | {error, kv_full}.
admit(Key) ->
    Max = max_keys(),
    case ets:info(?TABLE, size) >= Max andalso not ets:member(?TABLE, Key) of
        false ->
            ok;
        true ->
            ?LOG_WARNING(#{
                event => kv_full,
                max_keys => Max,
                msg => ~"game.kv is at kv_max_keys; new keys are refused until entries expire"
            }),
            {error, kv_full}
    end.

-spec current(term()) -> map().
current(Key) ->
    case ets:lookup(?TABLE, Key) of
        [{_K, Value, ExpiresAt}] when is_map(Value) ->
            case expired(ExpiresAt) of
                true -> #{};
                false -> Value
            end;
        _ ->
            #{}
    end.

%% Two narrowings of the same call rather than one `term()`: a gen_server reply
%% is untyped, and every caller here has a shape it must answer with.
-spec call_unit(term()) -> ok | {error, term()}.
call_unit(Msg) ->
    case call(Msg) of
        ok -> ok;
        {error, Reason} -> {error, Reason};
        Other -> {error, {unexpected_reply, Other}}
    end.

-spec call_map(term()) -> {ok, map()} | {error, term()}.
call_map(Msg) ->
    case call(Msg) of
        {ok, Value} when is_map(Value) -> {ok, Value};
        {error, Reason} -> {error, Reason};
        Other -> {error, {unexpected_reply, Other}}
    end.

-spec call(term()) -> term().
call(Msg) ->
    try
        gen_server:call(?MODULE, Msg, ?CALL_TIMEOUT)
    catch
        exit:{noproc, _} -> {error, kv_unavailable};
        exit:{timeout, _} -> {error, kv_timeout}
    end.

-spec max_keys() -> pos_integer().
max_keys() ->
    case application:get_env(asobi, kv_max_keys, ?DEFAULT_MAX_KEYS) of
        N when is_integer(N), N > 0 -> N;
        _ -> ?DEFAULT_MAX_KEYS
    end.

-spec default_ttl() -> pos_integer().
default_ttl() ->
    case application:get_env(asobi, kv_ttl_seconds, ?DEFAULT_TTL_SECONDS) of
        N when is_integer(N), N > 0 -> N;
        _ -> ?DEFAULT_TTL_SECONDS
    end.

expires_at(TtlSeconds) when is_integer(TtlSeconds), TtlSeconds > 0 ->
    now_ms() + TtlSeconds * 1000;
expires_at(_) ->
    now_ms() + default_ttl() * 1000.

expired(ExpiresAt) when is_integer(ExpiresAt) -> ExpiresAt < now_ms();
expired(_) -> false.

now_ms() ->
    erlang:monotonic_time(millisecond).

schedule_sweep() ->
    erlang:send_after(?SWEEP_INTERVAL, self(), sweep).
