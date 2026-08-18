-module(asobi_dgram_canary).
-moduledoc """
Readiness, proved by a real datagram exchange against ourselves.

A port-bound check would pass while the receive loop was wedged, which is the
failure this exists to catch: the socket stays bound as long as the process is
alive, so "is the port open" answers a question nobody is asking. This sends a
genuine `ping` to the gateway's own port over loopback and waits for the `pong`,
which only comes back if the guard, the limiters, the binding table, the MAC
check, the dispatcher and the sender are all working.

## It uses a real binding, because a fake one would prove less

The canary registers its own `conn_id` with a freshly generated `KUp` at boot and
completes the whole handshake. Nothing is special-cased for it anywhere in the
pipeline, so what it exercises is what a player exercises. A synthetic bypass
would test the code around the bypass.

The key is random per boot and the binding is only ever reachable over loopback.
Someone who obtained it could send pings, which is what it is for.

## What it does NOT prove

`SO_REUSEPORT` means the kernel picks which shard receives a given flow, and
nothing can target a specific one. So a healthy canary proves **at least one**
shard is alive, not all of them. A wedged shard shows up as a fraction of players
timing out rather than as a failed readiness probe, and the honest place to catch
that is `asobi.dgram.recv_failed` plus client-side telemetry.

Stated rather than glossed: an operator who believes this covers every shard will
misread a partial outage.

## Readiness stays local

It must not depend on the public internet or on the engine being up. A transient
upstream fault restarting a healthy gateway is a worse outage than the fault.
""".

-behaviour(gen_server).

-export([start_link/0, ready/0, probe_now/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_continue/2, handle_info/2, terminate/2]).

%% Every 5 s, failing after two consecutive misses. Ten seconds of grace before a
%% restart, against a probe that completes in microseconds when healthy: slow
%% enough not to flap on a scheduler hiccup, fast enough that a wedged loop is
%% caught inside a deployment's usual readiness window.
-define(INTERVAL_MS, 5_000).
-define(TIMEOUT_MS, 500).
-define(MISSES_ALLOWED, 2).

-type state() :: #{
    socket := socket:socket() | undefined,
    conn_id := non_neg_integer(),
    kup := binary(),
    cseq := non_neg_integer(),
    misses := non_neg_integer(),
    ready := boolean()
}.

-spec start_link() -> gen_server:start_ret().
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-doc """
Whether the gateway is answering its own datagrams.

`false` before the first successful probe, so a freshly started gateway is not
ready until it has actually proved itself rather than merely finished booting.
""".
-spec ready() -> boolean().
ready() ->
    try gen_server:call(?MODULE, ready, 1000) of
        Ready when is_boolean(Ready) -> Ready
    catch
        %% Not running at all - the engine role, or a gateway mid-restart.
        %% Neither is ready.
        _:_ -> false
    end.

-doc "Runs a probe immediately and reports the result. For tests and for ops.".
-spec probe_now() -> ok | {error, term()}.
probe_now() ->
    case gen_server:call(?MODULE, probe, 5000) of
        ok -> ok;
        {error, Reason} -> {error, Reason}
    end.

%% --- gen_server ---

-spec init([]) -> {ok, state(), {continue, register}} | {stop, term()}.
init([]) ->
    case socket:open(inet, dgram, udp) of
        {ok, Socket} ->
            case socket:bind(Socket, #{family => inet, addr => loopback, port => 0}) of
                ok ->
                    {ok,
                        #{
                            socket => Socket,
                            %% 32 bits, like any other conn_id. Random rather
                            %% than reserved so it cannot collide with a
                            %% deployment that hard-codes one.
                            conn_id => binary:decode_unsigned(crypto:strong_rand_bytes(4)),
                            kup => crypto:strong_rand_bytes(32),
                            cseq => 0,
                            misses => 0,
                            ready => false
                        },
                        {continue, register}};
                {error, Reason} ->
                    {stop, {canary_bind_failed, Reason}}
            end;
        {error, Reason} ->
            {stop, {canary_socket_failed, Reason}}
    end.

-spec handle_call(ready | probe, gen_server:from(), state()) -> {reply, term(), state()}.
handle_call(ready, _From, #{ready := Ready} = State) ->
    {reply, Ready, State};
handle_call(probe, _From, State) ->
    {Result, State1} = probe(State),
    {reply, Result, State1};
handle_call(_Request, _From, State) ->
    {reply, {error, unknown_call}, State}.

-spec handle_cast(term(), state()) -> {noreply, state()}.
handle_cast(_Msg, State) -> {noreply, State}.

-spec handle_info(term(), state()) -> {noreply, state()}.
handle_info(probe, State) ->
    _ = erlang:send_after(?INTERVAL_MS, self(), probe),
    {_Result, State1} = probe(State),
    {noreply, State1};
handle_info(_Info, State) ->
    {noreply, State}.

-spec terminate(term(), state()) -> ok.
terminate(_Reason, #{socket := undefined, conn_id := ConnId}) ->
    _ =
        try
            asobi_dgram_table:unregister(ConnId)
        catch
            _:_ -> ok
        end,
    ok;
terminate(_Reason, #{socket := Socket, conn_id := ConnId}) ->
    %% The table may already be gone if the whole tree is coming down, and a
    %% canary that crashed its own shutdown would mask the reason for it.
    _ =
        try
            asobi_dgram_table:unregister(ConnId)
        catch
            _:_ -> ok
        end,
    _ = socket:close(Socket),
    ok.

%% Registering is a continue rather than part of init/1 so a table that is still
%% starting does not deadlock the boot: this process is supervised alongside it,
%% not under it.
-spec handle_continue(register, state()) -> {noreply, state()}.
handle_continue(register, #{conn_id := ConnId, kup := KUp} = State) ->
    _ = asobi_dgram_table:register(#{
        conn_id => ConnId,
        kup => KUp,
        player_id => ~"__canary__",
        epoch => 0,
        %% Effectively never: the sweep must not reap the thing that proves the
        %% gateway is alive.
        expires_at => erlang:system_time(millisecond) + 365 * 24 * 60 * 60 * 1000,
        state => registered,
        handle => undefined,
        pending_handle => undefined,
        challenge => undefined,
        cseq => 0,
        rebinds => []
    }),
    _ = erlang:send_after(?INTERVAL_MS, self(), probe),
    {noreply, State}.

%% --- Internal ---

probe(#{socket := Socket, conn_id := ConnId, kup := KUp, cseq := CSeq} = State) ->
    #{port := Port} = asobi_dgram_gw_sup:config(),
    Next = CSeq + 1,
    Ping = asobi_dgram:encode_uplink(
        #{opcode => ping, conn_id => ConnId, cseq => Next, body => <<Next:64/little>>}, KUp, 0
    ),
    State1 = State#{cseq => Next},
    Target = #{family => inet, addr => loopback, port => Port},
    case socket:sendto(Socket, Ping, Target) of
        ok -> await_pong(Socket, ConnId, State1);
        {error, Reason} -> {{error, Reason}, miss(Reason, State1)}
    end.

await_pong(Socket, ConnId, State) ->
    case socket:recvfrom(Socket, 0, [], ?TIMEOUT_MS) of
        {ok, {_From, Data}} ->
            case asobi_dgram:decode_downlink(Data) of
                {ok, #{opcode := pong, conn_id := ConnId}} ->
                    {ok, hit(State)};
                _ ->
                    %% Something else answered. Nothing else should be talking to
                    %% this socket, so it counts as a miss rather than a retry.
                    {{error, unexpected_reply}, miss(unexpected_reply, State)}
            end;
        {error, Reason} ->
            {{error, Reason}, miss(Reason, State)}
    end.

hit(State) ->
    State#{misses => 0, ready => true}.

miss(Reason, #{misses := Misses} = State) ->
    Next = Misses + 1,
    Ready = Next =< ?MISSES_ALLOWED,
    asobi_dgram_telemetry:canary_missed(Reason, Next),
    State#{misses => Next, ready => Ready}.
