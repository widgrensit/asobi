-module(asobi_dgram_shard).
-moduledoc """
One `SO_REUSEPORT` receiver socket and its loop.

There is one of these per shard and the kernel picks which one an incoming flow
lands on. All they do is read bytes and hand them to `asobi_dgram_rx`, which is
where the pipeline lives; this module holds no policy, so a crash here loses at
most one datagram on one socket.

**The shard count is fixed at boot.** Adding or removing a socket reshuffles the
kernel's hash and moves existing flows to a different shard, which for a plane
whose whole point is not keeping per-flow state is survivable but pointless
churn. There is no rescaling path and that is a property of `SO_REUSEPORT`
rather than a limitation worth working around.

## Why it drains in bounded passes rather than looping

`socket:recvfrom` in `nowait` mode drains what is ready and then parks on a
select message, so the process returns to the gen_server loop between passes and
stays answerable to a shutdown. A blocking loop inside a callback would be
simpler and would make this process unkillable while a flood is in progress -
the shape where "the supervisor restarted it" quietly stops being true.

Each pass is capped. Under a flood an uncapped drain never returns either, so
the cap is what turns "responsive unless attacked" into "responsive".
""".

-behaviour(gen_server).

-export([start_link/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_continue/2, handle_info/2, terminate/2]).

%% Datagrams per drain pass. Big enough that the common case costs one select
%% round trip, small enough that a flood cannot hold the process inside a single
%% callback.
-define(DRAIN_LIMIT, 64).

-type state() :: #{socket := socket:socket(), index := non_neg_integer()}.

-spec start_link(non_neg_integer(), inet:port_number()) -> gen_server:start_ret().
start_link(Index, Port) ->
    gen_server:start_link(?MODULE, {Index, Port}, []).

-spec init({non_neg_integer(), inet:port_number()}) ->
    {ok, state(), {continue, recv}} | {stop, term()}.
init({Index, Port}) ->
    process_flag(trap_exit, true),
    case open(Port) of
        {ok, Socket} ->
            {ok, #{socket => Socket, index => Index}, {continue, recv}};
        {error, Reason} ->
            {stop, {socket_open_failed, Reason}}
    end.

-spec handle_call(term(), gen_server:from(), state()) -> {reply, term(), state()}.
handle_call(_Request, _From, State) -> {reply, {error, unknown_call}, State}.

-spec handle_cast(term(), state()) -> {noreply, state()}.
handle_cast(drain, State) -> drain(State);
handle_cast(_Msg, State) -> {noreply, State}.

-spec handle_continue(recv, state()) -> {noreply, state()} | {stop, term(), state()}.
handle_continue(recv, State) -> drain(State).

-spec handle_info(term(), state()) -> {noreply, state()} | {stop, term(), state()}.
%% The socket is ready again. Nothing in the message is needed beyond the fact
%% that it arrived, and matching the socket keeps a stale select from a previous
%% incarnation out.
handle_info({'$socket', Socket, select, _Ref}, #{socket := Socket} = State) ->
    drain(State);
handle_info({'$socket', Socket, abort, {_Ref, Reason}}, #{socket := Socket} = State) ->
    asobi_telemetry:dgram_recv_failed(Reason),
    {stop, {recv_aborted, Reason}, State};
handle_info(_Info, State) ->
    {noreply, State}.

-spec terminate(term(), state()) -> ok.
terminate(_Reason, #{socket := Socket}) ->
    _ = socket:close(Socket),
    ok.

%% --- Internal ---

open(Port) ->
    maybe
        {ok, Socket} ?= socket:open(inet, dgram, udp),
        %% Both options, and both before bind. Without them only the first shard
        %% binds and the rest fail, which would look like a port conflict rather
        %% than a missing socket option.
        ok ?= socket:setopt(Socket, {socket, reuseaddr}, true),
        ok ?= socket:setopt(Socket, {socket, reuseport}, true),
        ok ?= socket:bind(Socket, #{family => inet, addr => any, port => Port}),
        {ok, Socket}
    else
        {error, _} = Err -> Err
    end.

drain(State) -> drain(State, ?DRAIN_LIMIT).

drain(State, 0) ->
    %% Budget spent with more possibly waiting. Re-arm through the mailbox rather
    %% than recursing, so a shutdown queued behind this gets its turn.
    gen_server:cast(self(), drain),
    {noreply, State};
drain(#{socket := Socket} = State, Budget) ->
    case socket:recvfrom(Socket, 0, [], nowait) of
        {ok, {Handle, Data}} ->
            _ = dispatch(Data, Handle),
            drain(State, Budget - 1);
        {select, _SelectInfo} ->
            %% Nothing ready. Park until the socket says otherwise.
            {noreply, State};
        {error, closed} ->
            {stop, normal, State};
        {error, Reason} ->
            %% One bad read must not take the shard down: a restart rebinds the
            %% socket and the kernel reshuffles every flow that was landing here.
            asobi_telemetry:dgram_recv_failed(Reason),
            {noreply, State}
    end.

%% Every datagram is handled inline. Spawning per packet would hand an
%% unauthenticated flood a process-creation budget, which is the same mistake as
%% doing MAC work before the limiters.
dispatch(Data, Handle) ->
    case asobi_dgram_rx:handle(Data, Handle, deps()) of
        drop ->
            ok;
        {reply, Datagram} ->
            asobi_dgram_sender:send_one(Datagram, Handle, asobi_dgram_sender);
        {teardown, ConnId} ->
            asobi_dgram_table:unregister(ConnId);
        {input, ConnId, Body} ->
            asobi_dgram_uplink:deliver(ConnId, Body)
    end.

deps() ->
    #{
        kup_of => fun asobi_dgram_table:kup_of/1,
        hello => fun asobi_dgram_table:hello/4,
        confirm => fun asobi_dgram_table:confirm/4,
        note_uplink => fun asobi_dgram_table:note_uplink/2,
        challenge => fun() -> crypto:strong_rand_bytes(8) end
    }.
