-module(asobi_dgram_sender).
-moduledoc """
Owns the send socket and does the fan-out.

## The two-element iovec is the whole point

`send/3` takes a **shared body** and a list of `{conn_id, path_tag}` and writes
`[Prefix, SharedBody]` per subscriber. The prefix is 16 bytes built per
subscriber; the body is referenced, never copied. That is what preserves ADR
0001's encode-once discipline across a carrier whose send term is inherently
O(N).

ADR 0001 needs one clarifying amendment because of this, not a reversal:
encode-once was always a property of the state-production path - one `get_state`
and one encode per tick per zone - and never a claim about the send term, which
has always been O(N). On a datagram plane the per-subscriber send is roughly four
times more expensive than TCP's, so the discipline's measured leverage falls. The
discipline holds and the shared binary is still shared.

The two things that would genuinely reverse ADR 0001 are per-client baselines and
a per-client-key MAC on the fan-out, and both are refused (ADR 0012, decision 11).

## A send failure is not an error

`sendto` on a connectionless socket reports what the local kernel thinks, which
is nearly nothing: there is no delivery guarantee to fail. `EAGAIN` under buffer
pressure means the datagram is gone and the next one supersedes it, which is what
this plane is for. So a failure is counted and dropped, never retried and never
escalated - a retry queue here would be a memory-exhaustion surface bolted onto a
transport chosen for having none.
""".

-behaviour(gen_server).

-export([start_link/0, send/3, send_one/3]).
-export([init/1, handle_call/3, handle_cast/2, terminate/2]).

-type target() :: {non_neg_integer(), non_neg_integer(), asobi_dgram_binding:handle()}.

-type state() :: #{socket := socket:socket() | undefined}.

-spec start_link() -> gen_server:start_ret().
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-doc """
Fans one shared body out to many subscribers.

Asynchronous: the caller is a zone on its tick budget and must not block on a
socket. Ordering between two calls is preserved by the single owner, which is
what keeps `bseq` arriving in the order it was assigned.
""".
-spec send(asobi_dgram:opcode(), binary(), [target()]) -> ok.
send(Opcode, SharedBody, Targets) ->
    gen_server:cast(?MODULE, {fanout, Opcode, SharedBody, Targets}).

-doc "Sends one already-built datagram, for the handshake replies.".
-spec send_one(binary(), asobi_dgram_binding:handle(), pid() | atom()) -> ok.
send_one(Datagram, Handle, Server) ->
    gen_server:cast(Server, {send_one, Datagram, Handle}).

%% --- gen_server ---

-spec init([]) -> {ok, state()} | {stop, term()}.
init([]) ->
    %% A separate socket from the receivers'. The receivers are bound with
    %% SO_REUSEPORT and the kernel picks one per incoming flow; replies must not
    %% depend on which of them happens to be chosen, and a shard writing to its
    %% own socket would make the source port of a reply vary with the shard.
    case socket:open(inet, dgram, udp) of
        {ok, Socket} -> {ok, #{socket => Socket}};
        {error, Reason} -> {stop, {socket_open_failed, Reason}}
    end.

-spec handle_call(term(), gen_server:from(), state()) -> {reply, term(), state()}.
handle_call(_Request, _From, State) -> {reply, {error, unknown_call}, State}.

-spec handle_cast(term(), state()) -> {noreply, state()}.
handle_cast({fanout, Opcode, SharedBody, Targets}, #{socket := Socket} = State) ->
    fanout(Socket, Opcode, SharedBody, Targets),
    {noreply, State};
handle_cast({send_one, Datagram, Handle}, #{socket := Socket} = State) ->
    write(Socket, Handle, [Datagram]),
    {noreply, State};
handle_cast(_Msg, State) ->
    {noreply, State}.

-spec terminate(term(), state()) -> ok.
terminate(_Reason, #{socket := undefined}) ->
    ok;
terminate(_Reason, #{socket := Socket}) ->
    _ = socket:close(Socket),
    ok.

%% --- Internal ---

fanout(_Socket, _Opcode, _SharedBody, []) ->
    ok;
fanout(Socket, Opcode, SharedBody, [{ConnId, PathTag, Handle} | Rest]) ->
    Prefix = asobi_dgram:prefix(#{opcode => Opcode, conn_id => ConnId, path_tag => PathTag}),
    %% Two elements, never one concatenated binary: the body is referenced here,
    %% and joining them would copy it once per subscriber.
    write(Socket, Handle, [Prefix, SharedBody]),
    fanout(Socket, Opcode, SharedBody, Rest).

write(Socket, Handle, IoData) ->
    case socket:sendto(Socket, iolist_to_binary(IoData), Handle) of
        ok ->
            ok;
        {error, Reason} ->
            %% Counted and dropped. There is nothing to retry: the next pose
            %% supersedes this one, which is the property that made this plane
            %% worth having.
            asobi_dgram_telemetry:send_failed(Reason),
            ok
    end.
