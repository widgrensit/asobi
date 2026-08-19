-module(asobi_dgram_sender).
-moduledoc """
Serialises the fan-out, and writes it through a receiver's socket.

## Replies must leave from the public port

A datagram sent from a socket the kernel gave an ephemeral port to never reaches
the client (asobi#515). The client's flow is `client -> gw:7777`, so a reply
from `gw:51426` is a different 4-tuple: conntrack will not reverse-map it, which
breaks docker port-publishing and every player behind a home router, and any SDK
that `connect()`s its UDP socket to the minted endpoint filters it on arrival
anyway. The failure is silent on both ends - nothing is dropped server-side, so
it reads exactly like a blocked firewall.

Only a socket bound to that port egresses from it. But binding a second socket
there means `SO_REUSEPORT`, and a socket in that group receives a share of the
inbound traffic whether or not anyone reads it. The kernel hashes per 4-tuple,
not per packet, so what a send-only socket swallows is not a fraction of every
client's datagrams - it is every datagram of the clients that hashed onto it.
One in `shards + 1` players would simply never complete a handshake.

So this process owns no socket. Each receiver offers its own as it starts - one
already bound to the public port and already drained - and the first offer is
kept until a write says it is gone. A sender that restarted after the receivers
did missed the offers, so it asks; that is the only reason `lend_to/1` exists.

The socket is pushed rather than fetched because that is the only direction the
type survives: `gen_server:call` is typed `term()` and a socket is opaque, so a
socket pulled back through a reply cannot be narrowed to one again without an
assertion nothing checks.

The superseded rationale is worth naming because it reads plausibly: a separate
socket was said to stop the reply's source port varying with the shard. It never
could. Every shard is bound to the *same* port by `SO_REUSEPORT`, so the source
port is the public port whichever one writes.

## One process, though

What the single owner buys is ordering, not addressing: two `send/3` calls are
written in the order they arrived, which is what keeps `bseq` arriving in the
order it was assigned. That is a property of the process and survives the socket
being borrowed.

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

-export([start_link/0, send/3, send_one/3, lend/1, lend/2]).
-export([init/1, handle_call/3, handle_cast/2, terminate/2]).

-type target() :: {non_neg_integer(), non_neg_integer(), asobi_dgram_binding:handle()}.

-type cast() ::
    {fanout, asobi_dgram:opcode(), binary(), [target()]}
    | {send_one, binary(), asobi_dgram_binding:handle()}
    | {lend, socket:socket()}.

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

-doc "Offers a receiver's socket to write replies through. See the module doc.".
-spec lend(socket:socket()) -> ok.
lend(Socket) ->
    lend(?MODULE, Socket).

-doc "As `lend/1`, to a sender named explicitly - a restarted one asking again.".
-spec lend(pid() | atom(), socket:socket()) -> ok.
lend(Sender, Socket) ->
    gen_server:cast(Sender, {lend, Socket}).

%% --- gen_server ---

-spec init([]) -> {ok, state()}.
init([]) ->
    %% Nothing is opened here, and nothing may be asked for here either: the
    %% receivers start after this process, so there is nobody to ask yet. They
    %% offer as they start, and a sender that restarted asks on its first send.
    {ok, #{socket => undefined}}.

-spec handle_call(term(), gen_server:from(), state()) -> {reply, term(), state()}.
handle_call(_Request, _From, State) -> {reply, {error, unknown_call}, State}.

%% The argument is narrowed to `cast()` rather than left as `term()` on purpose:
%% it is what makes the lent socket arrive as a `socket:socket()` instead of a
%% `term()` nothing has checked. A socket cannot be narrowed back out of a
%% `gen_server:call` reply, so pushing it in is the only typed direction.
-spec handle_cast(cast(), state()) -> {noreply, state()}.
handle_cast({fanout, Opcode, SharedBody, Targets}, State) ->
    {noreply,
        through_socket(State, fun(Socket) -> fanout(Socket, Opcode, SharedBody, Targets) end)};
handle_cast({send_one, Datagram, Handle}, State) ->
    {noreply, through_socket(State, fun(Socket) -> write(Socket, Handle, [Datagram]) end)};
%% First offer wins. Every shard offers at boot and they are all bound to the
%% same port, so taking the first keeps one consistent source socket without
%% caring which shard it came from.
handle_cast({lend, Socket}, #{socket := undefined} = State) ->
    {noreply, State#{socket => Socket}};
handle_cast({lend, _Socket}, State) ->
    {noreply, State}.

-spec terminate(term(), state()) -> ok.
terminate(_Reason, _State) ->
    %% The socket belongs to a receiver, which closes it with itself. Closing a
    %% borrowed socket here would take that receiver's flows down with a process
    %% that is merely stopping.
    ok.

%% --- Internal ---

%% Runs the write, and forgets the socket if the write reported it gone - a
%% lender that restarted, or a tree on its way down. With nothing lent yet there
%% is nothing to write through: ask, count the drop, and let the next datagram
%% carry it. On this plane the next one always comes.
through_socket(#{socket := undefined} = State, _Write) ->
    ok = asobi_dgram_rx_sup:lend_to(self()),
    asobi_dgram_telemetry:send_failed(no_socket),
    State;
through_socket(#{socket := Socket} = State, Write) ->
    case Write(Socket) of
        ok ->
            State;
        stale ->
            ok = asobi_dgram_rx_sup:lend_to(self()),
            State#{socket => undefined}
    end.

fanout(_Socket, _Opcode, _SharedBody, []) ->
    ok;
fanout(Socket, Opcode, SharedBody, [{ConnId, PathTag, Handle} | Rest]) ->
    Prefix = asobi_dgram:prefix(#{opcode => Opcode, conn_id => ConnId, path_tag => PathTag}),
    %% Two elements, never one concatenated binary: the body is referenced here,
    %% and joining them would copy it once per subscriber.
    case write(Socket, Handle, [Prefix, SharedBody]) of
        ok -> fanout(Socket, Opcode, SharedBody, Rest);
        %% The socket is gone, not this subscriber. Carrying on would emit one
        %% telemetry event per remaining subscriber for a single fault.
        stale -> stale
    end.

write(Socket, Handle, IoData) ->
    case socket:sendto(Socket, iolist_to_binary(IoData), Handle) of
        ok ->
            ok;
        {error, Reason} ->
            %% Counted and dropped. There is nothing to retry: the next pose
            %% supersedes this one, which is the property that made this plane
            %% worth having.
            asobi_dgram_telemetry:send_failed(Reason),
            lender_gone(Reason)
    end.

%% Only the errors that mean the borrowed socket itself is finished. Everything
%% else - a full buffer, an unreachable peer - is about this one datagram, and
%% dropping the socket over it would re-resolve on every send under load.
lender_gone(closed) -> stale;
lender_gone(ebadf) -> stale;
lender_gone(_Reason) -> ok.
