-module(asobi_dgram_socket_tests).
-include_lib("eunit/include/eunit.hrl").

%% The gateway against a REAL socket. Everything else in the datagram suite is a
%% function call; this is the only thing that proves the sockets bind, that
%% SO_REUSEPORT lets several shards share a port, and that a handshake completes
%% over the wire rather than over a map.

-define(KUP, <<"0123456789abcdef0123456789abcdef">>).
-define(CONN, 90210).

%% Arity-1 instantiators, because eunit runs the fixture in a different process
%% from the test body: anything stashed in a process dictionary during setup is
%% not there when the assertion runs.
socket_test_() ->
    {timeout, 60,
        {foreach, fun setup/0, fun cleanup/1, [
            fun(Ctx) -> {"several shards bind the same port", fun() -> shards_share(Ctx) end} end,
            fun(Ctx) ->
                {"a full handshake completes over the wire", fun() -> handshake(Ctx) end}
            end,
            fun(Ctx) ->
                {"a hello from an unknown conn_id is answered with silence", fun() ->
                    unknown_conn_silent(Ctx)
                end}
            end,
            fun(Ctx) ->
                {"a malformed datagram is answered with silence", fun() -> garbage_silent(Ctx) end}
            end,
            fun(Ctx) ->
                {"every reply leaves from the public port", fun() ->
                    replies_from_public_port(Ctx)
                end}
            end,
            fun(Ctx) ->
                {"the gateway binds no socket a receiver is not draining", fun() ->
                    no_undrained_socket(Ctx)
                end}
            end,
            fun(Ctx) ->
                {"a sender that restarted after the receivers still answers", fun() ->
                    sender_recovers_after_restart(Ctx)
                end}
            end,
            fun(_Ctx) ->
                {"the canary proves the gateway by talking to it", fun canary_probes/0}
            end,
            fun(_Ctx) -> {"a wedged receive loop fails readiness", fun canary_detects_wedge/0} end
        ]}}.

setup() ->
    _ = application:ensure_all_started(seki),
    Port = free_port(),
    %% A free port for the engine link too, not just the datagram one. Leaving it
    %% at the default made every fixture in this module bind the same fixed port
    %% in turn, which passed locally and failed on CI with eaddrinuse - a fixed
    %% port in a test is a race waiting for a slower machine.
    application:set_env(asobi, role, dgram_gw),
    application:set_env(asobi, dgram, #{port => Port, shards => 3, link_port => free_port()}),
    {ok, Sup} = asobi_dgram_gw_sup:start_link(),
    ok = asobi_dgram_table:register(binding(?CONN)),
    {ok, Client} = socket:open(inet, dgram, udp),
    ok = socket:bind(Client, #{family => inet, addr => loopback, port => 0}),
    #{sup => Sup, client => Client, port => Port}.

cleanup(#{sup := Sup, client := Client}) ->
    _ = socket:close(Client),
    %% Synchronously, and that matters: every child here is locally registered,
    %% so a teardown that returns before the tree is actually down makes the next
    %% fixture fail with already_started rather than with anything informative.
    Ref = monitor(process, Sup),
    unlink(Sup),
    exit(Sup, shutdown),
    receive
        {'DOWN', Ref, process, Sup, _} -> ok
    after 5000 -> error(gateway_did_not_stop)
    end,
    application:unset_env(asobi, role),
    application:unset_env(asobi, dgram),
    ok.

%% Three sockets on one port is the entire reason SO_REUSEPORT is in the design.
%% Without both options set before bind, only the first shard binds and the rest
%% fail - which looks like a port conflict rather than a missing socket option,
%% so it is worth an assertion rather than a comment.
shards_share(_Ctx) ->
    Children = supervisor:which_children(asobi_dgram_rx_sup),
    ?assertEqual(3, length(Children)),
    ?assert(lists:all(fun({_, Pid, _, _}) -> is_pid(Pid) end, Children)).

%% A reply that does not leave from the public port never reaches a real client:
%% conntrack will not reverse-map a different 4-tuple, and an SDK that connect()s
%% its socket filters it on arrival. This suite could not see that, because
%% `recv/1` discarded the source (asobi#515).
%%
%% Connected, deliberately - that is what the Godot SDK does, so a reply from the
%% wrong port is not merely wrong here, it never arrives at all. The assertion is
%% a timeout, which is exactly what the player saw.
replies_from_public_port(#{port := Port}) ->
    {ok, Client} = socket:open(inet, dgram, udp),
    ok = socket:connect(Client, #{family => inet, addr => loopback, port => Port}),
    try
        ok = socket:send(Client, uplink(hello, 1, <<>>)),
        {ok, #{opcode := hello_ok, body := Challenge}} = decode(connected_recv(Client), hello_ok),

        ok = socket:send(Client, uplink(hello_confirm, 2, Challenge)),
        wait_until(fun() -> asobi_dgram_table:sendable(?CONN) =/= error end),

        ok = socket:send(Client, uplink(ping, 3, <<7:64>>)),
        {ok, #{opcode := pong}} = decode(connected_recv(Client), pong)
    after
        _ = socket:close(Client)
    end.

%% The fix that looks obvious and is wrong: bind a second, send-only socket to
%% the public port with SO_REUSEPORT. It joins the receive group, and the kernel
%% hashes per 4-tuple rather than per packet - so what it swallows is not a share
%% of everyone's datagrams but every datagram of the clients that hashed onto it.
%% One player in `shards + 1` would never complete a handshake.
%%
%% Distinct source ports are the only thing that catches this. A single client
%% hashes to one socket and passes or fails by luck; twenty-four make the odds of
%% missing an undrained socket among three shards about one in a thousand.
no_undrained_socket(#{port := Port}) ->
    [
        begin
            ConnId = 700_000 + N,
            ok = asobi_dgram_table:register(binding(ConnId)),
            {ok, C} = socket:open(inet, dgram, udp),
            ok = socket:bind(C, #{family => inet, addr => loopback, port => 0}),
            ok = send(C, Port, uplink(ConnId, hello, 1, <<>>)),
            case recv(C) of
                {ok, From, _Data} -> ?assertEqual(Port, maps:get(port, From));
                timeout -> erlang:error({flow_never_answered, N, ConnId})
            end,
            _ = socket:close(C)
        end
     || N <- lists:seq(1, 24)
    ].

%% The receivers offer their sockets as they start, which covers a normal boot
%% because they start after the sender. A sender that crashed and came back later
%% missed every offer, so it has to ask - and if it does not, the gateway is mute
%% from then on with nothing server-side to say so.
sender_recovers_after_restart(#{client := Client, port := Port}) ->
    Pid = sender_pid(),
    Ref = monitor(process, Pid),
    exit(Pid, kill),
    receive
        {'DOWN', Ref, process, Pid, _} -> ok
    after 5000 -> error(sender_did_not_die)
    end,
    wait_until(fun() ->
        case whereis(asobi_dgram_sender) of
            New when is_pid(New) -> New =/= Pid;
            _NotYet -> false
        end
    end),

    %% Retried the way a client's probe ladder would: the datagram that finds no
    %% socket is the one that asks for it, so the answer arrives for the next.
    ok = send(Client, Port, uplink(hello, 1, <<>>)),
    From =
        case recv(Client) of
            {ok, First, _} ->
                First;
            timeout ->
                ok = send(Client, Port, uplink(hello, 2, <<>>)),
                {ok, Second, _} = recv(Client),
                Second
        end,
    ?assertEqual(Port, maps:get(port, From)).

handshake(#{client := Client, port := Port}) ->
    ok = send(Client, Port, uplink(hello, 1, <<>>)),
    {ok, HelloFrom, Reply} = recv(Client),
    ?assertEqual(Port, maps:get(port, HelloFrom)),
    {ok, #{opcode := hello_ok, conn_id := ?CONN, body := Challenge}} =
        asobi_dgram:decode_downlink(Reply),

    %% Nothing may be sendable until the echo returns: that is the whole claim
    %% the two-phase exchange makes.
    ?assertEqual(error, asobi_dgram_table:sendable(?CONN)),

    ok = send(Client, Port, uplink(hello_confirm, 2, Challenge)),
    ?assertEqual(timeout, recv(Client)),
    wait_until(fun() -> asobi_dgram_table:sendable(?CONN) =/= error end),

    %% ...and the handle it bound is the client's real return path, learned from
    %% the datagram rather than from anything the client claimed.
    ?assertMatch({ok, #{addr := _, port := _}}, asobi_dgram_table:sendable(?CONN)),

    %% ping answers, and the answer is not larger than the question.
    Ping = uplink(ping, 3, <<42:64>>),
    ok = send(Client, Port, Ping),
    {ok, PongFrom, Pong} = recv(Client),
    ?assertEqual(Port, maps:get(port, PongFrom)),
    ?assert(byte_size(Pong) =< byte_size(Ping)),
    ?assertMatch({ok, #{opcode := pong}}, asobi_dgram:decode_downlink(Pong)).

%% The gateway emits no error datagram of any kind. A prober learns nothing about
%% which gate it hit, and gets no bytes to amplify.
unknown_conn_silent(#{client := Client, port := Port}) ->
    Bogus = asobi_dgram:encode_uplink(
        #{opcode => hello, conn_id => 12345, cseq => 1, body => <<>>}, ?KUP, asobi_dgram:min_hello()
    ),
    ok = send(Client, Port, Bogus),
    ?assertEqual(timeout, recv(Client)).

garbage_silent(#{client := Client, port := Port}) ->
    [
        begin
            ok = send(Client, Port, crypto:strong_rand_bytes(N)),
            ?assertEqual(timeout, recv(Client))
        end
     || N <- [0, 1, 16, 40, 64, 200]
    ].

%% A port-bound check would pass while the receive loop was wedged. This proves
%% the whole pipeline instead, by being an ordinary client with an ordinary
%% binding: nothing is special-cased for the canary anywhere.
canary_probes() ->
    ?assertEqual(ok, asobi_dgram_canary:probe_now()),
    ?assert(asobi_dgram_canary:ready()).

%% The property that makes it worth having. Killing the receivers leaves the port
%% bound from the outside's point of view for as long as the sockets are open, so
%% only a real exchange notices - and two consecutive misses are what flips it,
%% not one, so a single scheduler hiccup does not restart a healthy node.
canary_detects_wedge() ->
    ?assertEqual(ok, asobi_dgram_canary:probe_now()),
    ?assert(asobi_dgram_canary:ready()),

    %% Take the receive side away. Since the sender writes through a receiver's
    %% socket, this now silences the reply path too - which is the honest result:
    %% there is no socket left that could answer while nothing is being read.
    ok = supervisor:terminate_child(asobi_dgram_gw_sup, asobi_dgram_rx_sup),

    ?assertMatch({error, _}, asobi_dgram_canary:probe_now()),
    ?assert(asobi_dgram_canary:ready()),
    ?assertMatch({error, _}, asobi_dgram_canary:probe_now()),
    ?assert(asobi_dgram_canary:ready()),
    ?assertMatch({error, _}, asobi_dgram_canary:probe_now()),
    ?assertNot(asobi_dgram_canary:ready()).

%% --- Helpers ---

send(Client, Port, Data) ->
    socket:sendto(Client, Data, #{family => inet, addr => loopback, port => Port}).

%% The source is returned, not discarded. Throwing it away is what let a reply
%% from an ephemeral port pass every assertion in this file (asobi#515).
recv(Client) ->
    case socket:recvfrom(Client, 0, [], 500) of
        {ok, {From, Data}} -> {ok, From, Data};
        {error, timeout} -> timeout
    end.

connected_recv(Client) ->
    socket:recv(Client, 0, 500).

sender_pid() ->
    case whereis(asobi_dgram_sender) of
        Pid when is_pid(Pid) -> Pid;
        _ -> error(sender_not_running)
    end.

decode({ok, Data}, _Expected) ->
    asobi_dgram:decode_downlink(Data);
decode({error, timeout}, Expected) ->
    %% The shape of the bug: the gateway generated the reply and the kernel
    %% refused to hand it over, because its source was not the endpoint.
    erlang:error({no_reply_reached_a_connected_client, Expected}).

wait_until(Pred) -> wait_until(Pred, 50).

wait_until(Pred, 0) ->
    ?assert(Pred());
wait_until(Pred, N) ->
    case Pred() of
        true ->
            ok;
        false ->
            timer:sleep(20),
            wait_until(Pred, N - 1)
    end.

free_port() ->
    {ok, S} = socket:open(inet, dgram, udp),
    ok = socket:bind(S, #{family => inet, addr => loopback, port => 0}),
    {ok, #{port := Port}} = socket:sockname(S),
    ok = socket:close(S),
    Port.

uplink(Opcode, CSeq, Body) ->
    uplink(?CONN, Opcode, CSeq, Body).

uplink(ConnId, Opcode, CSeq, Body) ->
    Pad =
        case Opcode of
            hello -> asobi_dgram:min_hello();
            _ -> 0
        end,
    asobi_dgram:encode_uplink(
        #{opcode => Opcode, conn_id => ConnId, cseq => CSeq, body => Body}, ?KUP, Pad
    ).

binding(ConnId) ->
    #{
        conn_id => ConnId,
        kup => ?KUP,
        player_id => ~"p1",
        epoch => 1,
        expires_at => erlang:system_time(millisecond) + 60_000,
        state => registered,
        handle => undefined,
        pending_handle => undefined,
        challenge => undefined,
        cseq => 0,
        rebinds => []
    }.
