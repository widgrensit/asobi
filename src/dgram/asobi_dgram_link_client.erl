-module(asobi_dgram_link_client).
-moduledoc """
The engine's end of the gateway link: dials, authenticates, sends.

Started in the **engine** role and only when a gateway is configured, so a
deployment with no datagram plane starts nothing and pays nothing.

## Mint waits for the ack; revocation does not

`register/1` is synchronous, because ADR 0012's mint replies to the player only
after the gateway has the binding. A client told it may open the plane before the
gateway would recognise it would spend its whole probing budget being ignored.

`unregister/1` is asynchronous. A revocation that cannot be delivered is bounded
by the mint's own expiry, which every binding carries precisely so that this
choice is available - and blocking a dying session on a socket is how one dead
gateway becomes a stuck engine.

## An unreachable gateway is a degraded plane, not an error

Every call returns `{error, _}` rather than raising, and the mint path turns that
into "no datagram plane for this session". The WebSocket carries everything
regardless, so the honest outcome of a gateway being down is that clients stay on
TCP.
""".

-behaviour(gen_server).

-export([start_link/0, enabled/0, register/1, unregister/1, pose/2, connected/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-include_lib("kernel/include/logger.hrl").

-define(RECONNECT_MS, 2_000).
-define(CONNECT_TIMEOUT_MS, 2_000).
-define(NONCE_BYTES, 16).

%% At most one dial-failure warning per minute. Reconnects are two seconds apart,
%% so an unreachable gateway is 30 lines a minute un-throttled - and the failure
%% it has to report is a permanent one (a wrong address, a link port bound to a
%% loopback the engine is not on), which is exactly the case where a flood buries
%% the line that says so.
-define(DIAL_LOG_INTERVAL_MS, 60_000).

-type state() :: #{
    socket := gen_tcp:socket() | undefined,
    buffer := binary(),
    dial_logged_at := integer() | undefined
}.

-doc """
Whether this engine has a gateway to talk to.

Configuring `dgram_gateway` is the opt-in. Without it nothing is dialled and the
datagram plane simply does not exist for this deployment.
""".
-spec enabled() -> boolean().
enabled() -> gateway() =/= undefined.

-spec start_link() -> gen_server:start_ret().
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-doc "Whether the link is currently up.".
-spec connected() -> boolean().
connected() ->
    try gen_server:call(?MODULE, connected, 1000) of
        true -> true;
        _ -> false
    catch
        _:_ -> false
    end.

-doc "Registers a minted binding, waiting for the gateway to have it.".
-spec register(map()) -> ok | {error, term()}.
register(Binding) ->
    try gen_server:call(?MODULE, {send, {register, Binding}}, 3000) of
        ok -> ok;
        {error, Reason} -> {error, Reason};
        Other -> {error, {unexpected_reply, Other}}
    catch
        _:Reason -> {error, Reason}
    end.

-doc """
Sends one zone's pose body and the connections it goes to.

Fire and forget, and lossy on purpose: this is called on a zone's tick budget and
the next pose is 50ms behind it. Blocking a zone on a socket to deliver one
movement frame is how a slow gateway becomes a stalled simulation.
""".
-spec pose(binary(), [non_neg_integer()]) -> ok.
pose(SharedBody, ConnIds) ->
    _ =
        try
            gen_server:cast(?MODULE, {send, {pose, SharedBody, ConnIds}})
        catch
            _:_ -> ok
        end,
    ok.

-doc "Revokes a binding. Fire and forget: see the module doc.".
-spec unregister(non_neg_integer()) -> ok.
unregister(ConnId) ->
    _ =
        try
            gen_server:cast(?MODULE, {send, {unregister, ConnId}})
        catch
            %% Not running: the plane is not configured, or is restarting. The
            %% mint's own expiry bounds an undelivered revocation, which is why
            %% every binding carries one.
            _:_ -> ok
        end,
    ok.

%% --- gen_server ---

-spec init([]) -> {ok, state()}.
init([]) ->
    self() ! connect,
    {ok, #{socket => undefined, buffer => <<>>, dial_logged_at => undefined}}.

-type request() :: connected | {send, asobi_dgram_link:message()}.

-spec handle_call(request(), gen_server:from(), state()) -> {reply, term(), state()}.
handle_call(connected, _From, #{socket := Socket} = State) ->
    {reply, Socket =/= undefined, State};
handle_call({send, _Msg}, _From, #{socket := undefined} = State) ->
    {reply, {error, no_gateway}, State};
handle_call({send, Msg}, _From, #{socket := Socket} = State) ->
    case gen_tcp:send(Socket, asobi_dgram_link:encode(Msg)) of
        ok ->
            {reply, ok, State};
        {error, Reason} ->
            {reply, {error, Reason}, disconnected(State)}
    end;
handle_call(_Request, _From, State) ->
    {reply, {error, unknown_call}, State}.

-type cast() :: {send, asobi_dgram_link:message()}.

-spec handle_cast(cast(), state()) -> {noreply, state()}.
handle_cast({send, _Msg}, #{socket := undefined} = State) ->
    {noreply, State};
handle_cast({send, Msg}, #{socket := Socket} = State) when Socket =/= undefined ->
    case gen_tcp:send(Socket, asobi_dgram_link:encode(Msg)) of
        ok -> {noreply, State};
        {error, _Reason} -> {noreply, disconnected(State)}
    end;
handle_cast(_Msg, State) ->
    {noreply, State}.

-spec handle_info(term(), state()) -> {noreply, state()}.
handle_info(connect, State) ->
    {noreply, connect(State)};
handle_info({tcp, Socket, Data}, #{socket := Socket, buffer := Buffer} = State) when
    Socket =/= undefined, is_binary(Data), is_binary(Buffer)
->
    ok = inet:setopts(Socket, [{active, once}]),
    {noreply, consume(<<Buffer/binary, Data/binary>>, State)};
handle_info({tcp_closed, Socket}, #{socket := Socket} = State) ->
    {noreply, disconnected(State)};
handle_info(_Info, State) ->
    {noreply, State}.

-spec terminate(term(), state()) -> ok.
terminate(_Reason, #{socket := undefined}) -> ok;
terminate(_Reason, #{socket := Socket}) -> gen_tcp:close(Socket).

%% --- Internal ---

connect(State) ->
    case gateway() of
        undefined ->
            State;
        {Host, Port} ->
            case dial(Host, Port) of
                {ok, Socket} ->
                    asobi_telemetry:dgram_link_up(),
                    State#{socket => Socket, dial_logged_at => undefined};
                {error, Reason} ->
                    asobi_telemetry:dgram_link_error(Reason),
                    _ = erlang:send_after(?RECONNECT_MS, self(), connect),
                    log_dial_failure(Host, Port, Reason, State#{socket => undefined})
            end
    end.

%% A telemetry counter was the only thing this emitted, so an engine that could
%% not reach its gateway looked exactly like one with no gateway configured: every
%% client was answered `datagram_unavailable` and no log on either side said why
%% (asobi#511). The gateway binds its link port on loopback, so the two roles have
%% to share a network namespace; that is the first thing to check and the line
%% says so.
-spec log_dial_failure(term(), inet:port_number(), term(), state()) -> state().
log_dial_failure(Host, Port, Reason, #{dial_logged_at := At} = State) ->
    %% Monotonic, not system time: a clock stepped backwards over an NTP
    %% correction would suppress the line for the size of the step. `undefined`
    %% rather than 0 for the same reason - monotonic time can start negative.
    Now = erlang:monotonic_time(millisecond),
    case At =:= undefined orelse Now - At >= ?DIAL_LOG_INTERVAL_MS of
        false ->
            State;
        true ->
            ?LOG_WARNING(#{
                msg => ~"dgram link unreachable, datagram plane is down",
                %% Not `list_to_binary/1`: `dgram_gateway` can also be written
                %% into sys.config by hand, where a binary host is the natural
                %% form, and raising here would take the plane's supervisor down
                %% on the one path that only runs when something is already wrong.
                host => iolist_to_binary(io_lib:format("~ts", [Host])),
                port => Port,
                error => Reason,
                detail => ~"the gateway binds its link port on loopback only"
            }),
            State#{dial_logged_at => Now}
    end.

dial(Host, Port) ->
    Opts = [binary, {active, false}, {packet, raw}],
    maybe
        {ok, Socket} ?= gen_tcp:connect(Host, Port, Opts, ?CONNECT_TIMEOUT_MS),
        %% The gateway speaks first with a nonce, so the tag cannot be replayed
        %% by anyone who watched an earlier connect.
        {ok, Nonce} ?= recv_nonce(Socket),
        ok ?= gen_tcp:send(Socket, asobi_dgram_link:auth_tag(Nonce, secret())),
        ok ?= inet:setopts(Socket, [{active, once}]),
        {ok, Socket}
    else
        {error, _} = Err -> Err
    end.

%% `{packet, raw}` on a binary socket only ever yields a binary. The guard is what
%% says so rather than assuming it, and an HTTP packet term arriving here would
%% mean a socket configured somewhere other than dial/2.
recv_nonce(Socket) ->
    case gen_tcp:recv(Socket, ?NONCE_BYTES, ?CONNECT_TIMEOUT_MS) of
        {ok, Nonce} when is_binary(Nonce) -> {ok, Nonce};
        {ok, _Other} -> {error, unexpected_packet};
        {error, _} = Err -> Err
    end.

disconnected(#{socket := Socket} = State) ->
    _ = (Socket =/= undefined) andalso gen_tcp:close(Socket),
    asobi_telemetry:dgram_link_closed(),
    _ = erlang:send_after(?RECONNECT_MS, self(), connect),
    State#{socket => undefined, buffer => <<>>}.

%% The gateway sends exactly one kind of message: verified uplink input. Anything
%% else on this socket is a protocol violation, and a decoder that shrugged at one
%% would be the trust boundary this whole hand-written format exists to keep
%% narrow.
consume(Buffer, #{socket := Socket} = State) ->
    case Buffer of
        <<Len:32/little, _/binary>> when Len > 65_535 ->
            asobi_telemetry:dgram_link_error(frame_too_large),
            disconnected(State#{socket => Socket});
        <<Len:32/little, Payload:Len/binary, Rest/binary>> ->
            _ = accept_from_gateway(asobi_dgram_link:decode(Payload)),
            consume(Rest, State);
        _ ->
            State#{buffer => Buffer}
    end.

accept_from_gateway({ok, {input, ConnId, Body}}) ->
    asobi_dgram_input:apply(ConnId, Body);
accept_from_gateway({ok, _Other}) ->
    %% register and unregister travel engine-to-gateway only. Receiving one means
    %% the peer is confused or is not the gateway.
    asobi_telemetry:dgram_link_error(unexpected_direction);
accept_from_gateway({error, Reason}) ->
    asobi_telemetry:dgram_link_error(Reason).

%% `{Host, Port}` or nothing. Deliberately not defaulted to localhost: a plane
%% nobody configured must not quietly start dialling.
gateway() ->
    case application:get_env(asobi, dgram_gateway) of
        {ok, #{host := Host, port := Port}} when is_integer(Port) -> {Host, Port};
        _ -> undefined
    end.

secret() ->
    case application:get_env(asobi, dgram_link_secret) of
        {ok, S} when is_binary(S) -> S;
        _ -> <<>>
    end.
