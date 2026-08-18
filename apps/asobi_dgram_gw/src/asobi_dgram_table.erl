-module(asobi_dgram_table).
-moduledoc """
Owns the datagram plane's binding table.

A thin shell around `asobi_dgram_binding`, which holds every security-critical
transition as pure data. Everything interesting is testable there without a
process; this module exists to give that data an owner with a lifetime, and to be
the one place a credential can be revoked.

## Why a process and not ETS

The table is written on mint, on every handshake transition and on teardown, and
read on every uplink. An ETS table would make the reads concurrent, and would
also make every one of those transitions a read-modify-write race across the
receiver shards - `cseq` monotonicity and the challenge exchange are exactly the
things that must not interleave. A single owner serialises them by construction.

If read throughput ever becomes the bottleneck the answer is a read-only ETS
mirror of the `conn_id -> KUp` lookup, updated by this process, never a move of
the state machine into ETS.

## Revocation

`unregister/1` is synchronous. A session dying has to take its datagram
credential with it before the reply reaches the player, or a torn-down session
keeps a working uplink - which is the one thing a registered binding buys over a
signed token and the reason the whole plane is a table.
""".

-behaviour(gen_server).

-export([start_link/0]).
-export([register/1, unregister/1, kup_of/1, hello/4, confirm/4, note_uplink/2, sendable/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

%% ADR 0012's mint carries an expiry, and a client that never says hello would
%% otherwise hold a slot until the session dies. Swept rather than timed per
%% binding: one timer beats thousands.
-define(SWEEP_INTERVAL_MS, 30_000).

%% Spelled out rather than left as term(): every field of every request is a
%% security-relevant value, and a handle_call whose arguments type as term()
%% checks nothing about the transitions it drives.
-type request() ::
    {register, asobi_dgram_binding:binding()}
    | {unregister, non_neg_integer()}
    | {kup_of, non_neg_integer()}
    | {hello, non_neg_integer(), non_neg_integer(), asobi_dgram_binding:handle(), binary()}
    | {confirm, non_neg_integer(), non_neg_integer(), asobi_dgram_binding:handle(), binary()}
    | {note_uplink, non_neg_integer(), non_neg_integer()}
    | {sendable, non_neg_integer()}.

-type state() :: #{table := asobi_dgram_binding:table()}.

-spec start_link() -> gen_server:start_ret().
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% Every call below pattern-matches the reply rather than returning it raw. Two
%% reasons: gen_server:call/2 is typed term(), so a raw return makes the declared
%% spec a claim nothing checks; and an unexpected reply from our own handle_call
%% then fails here, loudly, instead of travelling as a wrongly-typed value.

-doc "Records a minted binding. Called from the mint path, over TLS.".
-spec register(asobi_dgram_binding:binding()) -> ok | {error, duplicate}.
register(Binding) ->
    case gen_server:call(?MODULE, {register, Binding}) of
        ok -> ok;
        {error, duplicate} -> {error, duplicate}
    end.

-doc "Revokes a binding. Synchronous: see the module doc.".
-spec unregister(non_neg_integer()) -> ok.
unregister(ConnId) ->
    ok = gen_server:call(?MODULE, {unregister, ConnId}).

-doc """
This connection's `KUp`, for the MAC check on the receive path.

Deliberately narrower than "the binding": the key is a 32-byte secret and the one
thing on the receive path that needs it is `asobi_dgram:verify/2`. Handing out a
whole struct that happens to contain it is how a secret ends up in a log line
someone added to debug something else.
""".
-spec kup_of(non_neg_integer()) -> {ok, binary()} | error.
kup_of(ConnId) ->
    case gen_server:call(?MODULE, {kup_of, ConnId}) of
        {ok, KUp} when is_binary(KUp) -> {ok, KUp};
        _ -> error
    end.

-doc "Handles a verified `hello`, returning the challenge to reply with.".
-spec hello(non_neg_integer(), non_neg_integer(), asobi_dgram_binding:handle(), binary()) ->
    {ok, binary()} | {error, atom()}.
hello(ConnId, CSeq, Handle, Challenge) ->
    case gen_server:call(?MODULE, {hello, ConnId, CSeq, Handle, Challenge}) of
        {ok, Reply} when is_binary(Reply) -> {ok, Reply};
        {error, Reason} when is_atom(Reason) -> {error, Reason}
    end.

-doc "Handles a verified `hello_confirm`, binding the downlink on success.".
-spec confirm(non_neg_integer(), non_neg_integer(), asobi_dgram_binding:handle(), binary()) ->
    ok | {error, atom()}.
confirm(ConnId, CSeq, Handle, Echo) ->
    case gen_server:call(?MODULE, {confirm, ConnId, CSeq, Handle, Echo}) of
        ok -> ok;
        {error, Reason} when is_atom(Reason) -> {error, Reason}
    end.

-doc "Advances `cseq` for an uplink that carries no binding transition.".
-spec note_uplink(non_neg_integer(), non_neg_integer()) -> ok | {error, atom()}.
note_uplink(ConnId, CSeq) ->
    case gen_server:call(?MODULE, {note_uplink, ConnId, CSeq}) of
        ok -> ok;
        {error, Reason} when is_atom(Reason) -> {error, Reason}
    end.

-doc "Where this connection's downlink goes, if a challenge has completed.".
-spec sendable(non_neg_integer()) -> {ok, asobi_dgram_binding:handle()} | error.
sendable(ConnId) ->
    case gen_server:call(?MODULE, {sendable, ConnId}) of
        {ok, Handle} -> {ok, Handle};
        _ -> error
    end.

%% --- gen_server ---

-spec init([]) -> {ok, state()}.
init([]) ->
    _ = erlang:send_after(?SWEEP_INTERVAL_MS, self(), sweep),
    {ok, #{table => asobi_dgram_binding:new()}}.

-spec handle_call(request(), gen_server:from(), state()) -> {reply, term(), state()}.
handle_call({register, Binding}, _From, #{table := T} = State) ->
    case asobi_dgram_binding:register(Binding, T) of
        {ok, T1} -> {reply, ok, State#{table => T1}};
        {error, Reason} -> {reply, {error, Reason}, State}
    end;
handle_call({unregister, ConnId}, _From, #{table := T} = State) ->
    {reply, ok, State#{table => asobi_dgram_binding:unregister(ConnId, T)}};
handle_call({kup_of, ConnId}, _From, #{table := T} = State) ->
    Reply =
        case asobi_dgram_binding:lookup(ConnId, T) of
            {ok, #{kup := KUp}} -> {ok, KUp};
            error -> error
        end,
    {reply, Reply, State};
handle_call({hello, ConnId, CSeq, Handle, Challenge}, _From, #{table := T} = State) ->
    case asobi_dgram_binding:hello(ConnId, CSeq, Handle, now_ms(), Challenge, T) of
        {ok, Reply, T1} -> {reply, {ok, Reply}, State#{table => T1}};
        {error, Reason, T1} -> {reply, {error, Reason}, State#{table => T1}}
    end;
handle_call({confirm, ConnId, CSeq, Handle, Echo}, _From, #{table := T} = State) ->
    case asobi_dgram_binding:confirm(ConnId, CSeq, Handle, Echo, T) of
        {ok, T1} -> {reply, ok, State#{table => T1}};
        {error, Reason, T1} -> {reply, {error, Reason}, State#{table => T1}}
    end;
handle_call({note_uplink, ConnId, CSeq}, _From, #{table := T} = State) ->
    case asobi_dgram_binding:note_uplink(ConnId, CSeq, T) of
        {ok, _Binding, T1} -> {reply, ok, State#{table => T1}};
        {error, Reason, T1} -> {reply, {error, Reason}, State#{table => T1}}
    end;
handle_call({sendable, ConnId}, _From, #{table := T} = State) ->
    {reply, asobi_dgram_binding:sendable(ConnId, T), State};
handle_call(_Request, _From, State) ->
    {reply, {error, unknown_call}, State}.

-spec handle_cast(term(), state()) -> {noreply, state()}.
handle_cast(_Msg, State) -> {noreply, State}.

-spec handle_info(term(), state()) -> {noreply, state()}.
handle_info(sweep, #{table := T} = State) ->
    _ = erlang:send_after(?SWEEP_INTERVAL_MS, self(), sweep),
    {Dead, T1} = asobi_dgram_binding:expire(now_ms(), T),
    _ =
        case Dead of
            [] -> ok;
            _ -> asobi_dgram_telemetry:bindings_expired(length(Dead))
        end,
    {noreply, State#{table => T1}};
handle_info(_Info, State) ->
    {noreply, State}.

%% --- Internal ---

now_ms() -> erlang:system_time(millisecond).
