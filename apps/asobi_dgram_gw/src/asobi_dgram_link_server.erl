-module(asobi_dgram_link_server).
-moduledoc """
The gateway's end of the engine link: listens, authenticates, applies.

One *authenticated* peer at a time, and authentication rather than arrival is
what decides who holds it. ADR 0013 accepts the datagram plane in its single-node
form only - one gateway, one engine - so two attached engines would fight over
one binding table.

Accepting only while unattached was the obvious way to enforce that and it is
wrong: a half-open socket left by a crashed engine would sit in the accepted slot
until TCP noticed, and block the replacement engine that is trying to reconnect
right now. So connections are always accepted, each gets a nonce and a deadline,
and the one that proves the shared secret becomes the peer and displaces whoever
held it. A prober that cannot authenticate displaces nothing.

## What it will do, and what it refuses to do

It applies `register` and `unregister` to the binding table and forwards nothing.
The engine cannot ask it a question, because the protocol has no question to ask.
That is the whole reason this is a hand-written frame format rather than dist.

## Failure is not fatal

The link going down does not stop the gateway. Existing bindings keep working -
they are already in the table - so players on the plane stay on it while the
engine restarts. What stops is new mints and revocations, and a revocation that
cannot be delivered is bounded by the mint's own expiry, which is why every
binding carries one.
""".

-behaviour(gen_server).

-export([start_link/0, connected/0, send/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(NONCE_BYTES, 16).
-define(AUTH_TIMEOUT_MS, 5_000).

%% Bounded: loopback-only makes a flood unlikely rather than impossible, and an
%% unbounded map of half-authenticated sockets is a leak either way.
-define(MAX_PENDING, 8).

-type state() :: #{
    listen := gen_tcp:socket() | undefined,
    %% The authenticated peer, and its parse buffer.
    peer := gen_tcp:socket() | undefined,
    buffer := binary(),
    %% Accepted but not yet authenticated: socket -> the nonce it was given.
    pending := #{gen_tcp:socket() => binary()}
}.

-spec start_link() -> gen_server:start_ret().
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-doc "Whether an engine is currently attached. For ops and for tests.".
-spec connected() -> boolean().
connected() ->
    try gen_server:call(?MODULE, connected, 1000) of
        true -> true;
        _ -> false
    catch
        _:_ -> false
    end.

-doc """
Sends one message up to the attached engine.

Asynchronous and lossy by design: this carries `input`, which is a datagram the
client will re-send in 50ms anyway. Blocking a receiver shard on a TCP socket to
deliver one movement packet would let a slow engine stall the whole plane.
""".
-spec send(asobi_dgram_link:message()) -> ok | {error, term()}.
send(Msg) ->
    try gen_server:call(?MODULE, {send, Msg}, 1000) of
        ok -> ok;
        {error, Reason} -> {error, Reason};
        Other -> {error, {unexpected_reply, Other}}
    catch
        _:Reason -> {error, Reason}
    end.

%% --- gen_server ---

-spec init([]) -> {ok, state()} | {stop, term()}.
init([]) ->
    Port = link_port(),
    Opts = [
        binary,
        {active, false},
        {reuseaddr, true},
        %% Loopback only. The link carries mint secrets and has no transport
        %% security of its own; binding it to a routable address would put those
        %% on the network in the clear. A deployment that needs them on separate
        %% hosts needs a tunnel, and that is an operator decision rather than a
        %% default.
        {ip, {127, 0, 0, 1}}
    ],
    case gen_tcp:listen(Port, Opts) of
        {ok, Listen} ->
            self() ! accept,
            {ok, #{listen => Listen, peer => undefined, buffer => <<>>, pending => #{}}};
        {error, Reason} ->
            {stop, {link_listen_failed, Reason}}
    end.

-type request() :: connected | {send, asobi_dgram_link:message()}.

-spec handle_call(request(), gen_server:from(), state()) -> {reply, term(), state()}.
handle_call(connected, _From, #{peer := Peer} = State) ->
    {reply, Peer =/= undefined, State};
handle_call({send, _Msg}, _From, #{peer := undefined} = State) ->
    {reply, {error, no_engine}, State};
handle_call({send, Msg}, _From, #{peer := Peer} = State) ->
    case gen_tcp:send(Peer, asobi_dgram_link:encode(Msg)) of
        ok ->
            {reply, ok, State};
        {error, Reason} ->
            _ = close(Peer),
            asobi_dgram_telemetry:link_closed(),
            {reply, {error, Reason}, State#{peer => undefined, buffer => <<>>}}
    end;
handle_call(_Request, _From, State) ->
    {reply, {error, unknown_call}, State}.

-spec handle_cast(term(), state()) -> {noreply, state()}.
handle_cast(_Msg, State) -> {noreply, State}.

-spec handle_info(term(), state()) -> {noreply, state()}.
handle_info(accept, #{listen := Listen} = State) when Listen =/= undefined ->
    case gen_tcp:accept(Listen, 100) of
        {ok, Socket} ->
            self() ! accept,
            {noreply, greet(Socket, State)};
        {error, timeout} ->
            self() ! accept,
            {noreply, State};
        {error, closed} ->
            {noreply, State};
        {error, Reason} ->
            asobi_dgram_telemetry:link_error(Reason),
            self() ! accept,
            {noreply, State}
    end;
%% Bytes from the authenticated peer are frames.
handle_info({tcp, Peer, Data}, #{peer := Peer, buffer := Buffer} = State) when
    Peer =/= undefined, is_binary(Data), is_binary(Buffer)
->
    ok = inet:setopts(Peer, [{active, once}]),
    {noreply, consume(<<Buffer/binary, Data/binary>>, State)};
%% Bytes from a pending connection are its auth tag and nothing else.
handle_info({tcp, Socket, Data}, #{pending := Pending} = State) when
    is_map_key(Socket, Pending), is_binary(Data)
->
    {noreply, authenticate(Socket, Data, State)};
handle_info({tcp_closed, Peer}, #{peer := Peer} = State) when Peer =/= undefined ->
    %% Existing bindings survive: they are already in the table, so players on
    %% the plane stay on it while the engine restarts.
    asobi_dgram_telemetry:link_closed(),
    {noreply, State#{peer => undefined, buffer => <<>>}};
handle_info({tcp_closed, Socket}, #{pending := Pending} = State) ->
    {noreply, State#{pending => maps:remove(Socket, Pending)}};
%% A connection that arrived and never proved itself does not get to hold a
%% pending slot indefinitely.
handle_info({auth_deadline, Socket}, #{pending := Pending} = State) when
    is_map_key(Socket, Pending)
->
    asobi_dgram_telemetry:link_error(auth_timeout),
    _ = close(Socket),
    {noreply, State#{pending => maps:remove(Socket, Pending)}};
handle_info({auth_deadline, _Settled}, State) ->
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

-spec terminate(term(), state()) -> ok.
terminate(_Reason, #{listen := Listen, peer := Peer, pending := Pending}) ->
    _ = close(Peer),
    _ = [close(S) || S <- maps:keys(Pending)],
    _ = close(Listen),
    ok.

%% --- Internal ---

greet(Socket, #{pending := Pending} = State) when map_size(Pending) >= ?MAX_PENDING ->
    asobi_dgram_telemetry:link_error(too_many_pending),
    _ = close(Socket),
    State;
greet(Socket, #{pending := Pending} = State) ->
    Nonce = crypto:strong_rand_bytes(?NONCE_BYTES),
    case gen_tcp:send(Socket, Nonce) of
        ok ->
            ok = inet:setopts(Socket, [{active, once}]),
            _ = erlang:send_after(?AUTH_TIMEOUT_MS, self(), {auth_deadline, Socket}),
            State#{pending => Pending#{Socket => Nonce}};
        {error, Reason} ->
            asobi_dgram_telemetry:link_error(Reason),
            _ = close(Socket),
            State
    end.

%% The tag is the only thing a pending connection may send, and it must arrive
%% whole. Anything else closes it: a peer that starts framing before proving
%% itself is not the peer this link is for.
authenticate(Socket, Data, #{pending := Pending, peer := Old} = State) ->
    Nonce = maps:get(Socket, Pending),
    case Data of
        <<Tag:32/binary, Rest/binary>> ->
            case crypto:hash_equals(asobi_dgram_link:auth_tag(Nonce, secret()), Tag) of
                true ->
                    %% Displaces whoever held the link, which is what makes an
                    %% engine restart behind a stale socket recover on its own.
                    _ = close(Old),
                    asobi_dgram_telemetry:link_up(),
                    ok = inet:setopts(Socket, [{active, once}]),
                    consume(Rest, State#{
                        peer => Socket, buffer => <<>>, pending => maps:remove(Socket, Pending)
                    });
                false ->
                    asobi_dgram_telemetry:link_error(bad_auth),
                    _ = close(Socket),
                    State#{pending => maps:remove(Socket, Pending)}
            end;
        _ ->
            asobi_dgram_telemetry:link_error(short_auth),
            _ = close(Socket),
            State#{pending => maps:remove(Socket, Pending)}
    end.

consume(Buffer, #{peer := Peer} = State) ->
    case Buffer of
        <<Len:32/little, _/binary>> when Len > 65_535 ->
            %% A frame larger than anything this protocol produces. Refused
            %% before allocation rather than after.
            asobi_dgram_telemetry:link_error(frame_too_large),
            _ = close(Peer),
            State#{peer => undefined, buffer => <<>>};
        <<Len:32/little, Payload:Len/binary, Rest/binary>> ->
            _ = apply_message(asobi_dgram_link:decode(Payload)),
            consume(Rest, State);
        _ ->
            State#{buffer => Buffer}
    end.

apply_message({ok, {register, Binding}}) ->
    asobi_dgram_table:register(Binding#{
        state => registered,
        handle => undefined,
        pending_handle => undefined,
        challenge => undefined,
        cseq => 0,
        rebinds => []
    });
apply_message({ok, {unregister, ConnId}}) ->
    asobi_dgram_table:unregister(ConnId);
apply_message({ok, {pose, SharedBody, ConnIds}}) ->
    %% The fan-out happens here rather than in the engine, which is the whole
    %% reason the engine hands over one body and a list: the prefix is built per
    %% subscriber and the body is referenced, never copied.
    asobi_dgram_sender:send(pose, SharedBody, targets(ConnIds, []));
apply_message({ok, {input, _ConnId, _Body}}) ->
    %% Wrong direction. The engine never sends input to the gateway, so this is a
    %% confused or hostile peer either way.
    asobi_dgram_telemetry:link_error(unexpected_input);
apply_message({error, Reason}) ->
    asobi_dgram_telemetry:link_error(Reason).

%% Only connections that have completed a challenge get a datagram. One that has
%% not is skipped in silence: it is mid-handshake, not broken, and the next pose
%% is 50ms away.
targets([], Acc) ->
    lists:reverse(Acc);
targets([ConnId | Rest], Acc) ->
    case asobi_dgram_table:sendable(ConnId) of
        {ok, Handle} -> targets(Rest, [{ConnId, 0, Handle} | Acc]);
        error -> targets(Rest, Acc)
    end.

close(undefined) -> ok;
close(Socket) -> gen_tcp:close(Socket).

link_port() ->
    #{link_port := Port} = asobi_dgram_gw_sup:config(),
    Port.

secret() ->
    case application:get_env(asobi, dgram_link_secret) of
        {ok, S} when is_binary(S) -> S;
        _ -> <<>>
    end.
