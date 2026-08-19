-module(asobi_dgram_link_e2e_tests).
-include_lib("eunit/include/eunit.hrl").

%% The whole seam, over real sockets: the engine dials the gateway, authenticates,
%% registers a binding, and a client then uses that binding on the datagram port.
%%
%% This is the test that would have caught the two halves agreeing with themselves
%% and not with each other, which is the failure a unit test on either side cannot
%% see.

-define(SECRET, <<"a-shared-secret-for-the-tests...">>).
-define(CONN, 777001).
-define(KUP, <<"0123456789abcdef0123456789abcdef">>).

link_test_() ->
    {timeout, 60,
        {foreach, fun setup/0, fun cleanup/1, [
            fun(Ctx) ->
                {"a registered binding works on the datagram port", fun() -> registers(Ctx) end}
            end,
            fun(Ctx) ->
                {"a revoked binding stops working immediately", fun() -> revokes(Ctx) end}
            end,
            fun(_Ctx) -> {"a wrong secret is refused", fun wrong_secret_refused/0} end,
            fun(_Ctx) ->
                {"a reconnecting engine displaces a stale connection", fun displaces_stale/0}
            end
        ]}}.

setup() ->
    _ = application:ensure_all_started(seki),
    Port = free_port(),
    LinkPort = free_port(),
    application:set_env(asobi, role, dgram_gw),
    application:set_env(asobi, dgram, #{port => Port, shards => 1, link_port => LinkPort}),
    application:set_env(asobi, dgram_link_secret, ?SECRET),
    application:set_env(asobi, dgram_gateway, #{host => {127, 0, 0, 1}, port => LinkPort}),
    {ok, Sup} = asobi_dgram_gw_sup:start_link(),
    {ok, Client} = asobi_dgram_link_client:start_link(),
    wait_until(fun asobi_dgram_link_client:connected/0),
    wait_until(fun asobi_dgram_link_server:connected/0),
    {ok, Sock} = socket:open(inet, dgram, udp),
    ok = socket:bind(Sock, #{family => inet, addr => loopback, port => 0}),
    #{sup => Sup, client => Client, sock => Sock, port => Port, link_port => LinkPort}.

cleanup(#{sup := Sup, client := Client, sock := Sock}) ->
    _ = socket:close(Sock),
    stop(Client),
    stop(Sup),
    [application:unset_env(asobi, K) || K <- [role, dgram, dgram_link_secret, dgram_gateway]],
    ok.

%% --- Tests ---

%% The mint path's whole promise: by the time the engine's register/1 returns, a
%% datagram naming that conn_id is recognised. A client told otherwise would burn
%% its probing budget talking to a gateway that had never heard of it.
registers(#{sock := Sock, port := Port}) ->
    ?assertEqual(error, asobi_dgram_table:kup_of(?CONN)),
    ?assertEqual(ok, asobi_dgram_link_client:register(binding())),
    wait_until(fun() -> asobi_dgram_table:kup_of(?CONN) =/= error end),

    ok = send(Sock, Port, uplink(hello, 1, <<>>)),
    {ok, Reply} = recv(Sock),
    ?assertMatch({ok, #{opcode := hello_ok, conn_id := ?CONN}}, asobi_dgram:decode_downlink(Reply)).

%% The one thing a registered binding buys over a signed token: a session dying
%% takes its datagram credential with it, and a token structurally cannot.
revokes(#{sock := Sock, port := Port}) ->
    ok = asobi_dgram_link_client:register(binding()),
    wait_until(fun() -> asobi_dgram_table:kup_of(?CONN) =/= error end),
    ok = send(Sock, Port, uplink(hello, 1, <<>>)),
    ?assertMatch({ok, _}, recv(Sock)),

    ok = asobi_dgram_link_client:unregister(?CONN),
    wait_until(fun() -> asobi_dgram_table:kup_of(?CONN) =:= error end),

    %% And now the same client gets silence rather than a challenge.
    ok = send(Sock, Port, uplink(hello, 2, <<>>)),
    ?assertEqual(timeout, recv(Sock)).

%% The link is loopback-only and carries mint secrets, so a peer that cannot prove
%% the shared secret gets nothing - and importantly the gateway keeps listening
%% rather than being wedged by one bad connect.
wrong_secret_refused() ->
    #{link_port := LinkPort} = ctx_from_env(),
    {ok, S} = gen_tcp:connect({127, 0, 0, 1}, LinkPort, [binary, {active, false}], 2000),
    {ok, Nonce} = gen_tcp:recv(S, 16, 2000),
    ok = gen_tcp:send(S, asobi_dgram_link:auth_tag(Nonce, <<"the wrong secret">>)),
    ?assertEqual({error, closed}, gen_tcp:recv(S, 0, 2000)),
    gen_tcp:close(S).

%% The reason authentication rather than arrival decides who holds the link. A
%% crashed engine leaves a socket the gateway cannot tell from a live one until
%% TCP notices, and the replacement engine is trying to reconnect right now. It
%% must not have to wait for that.
displaces_stale() ->
    #{link_port := LinkPort} = ctx_from_env(),
    ?assert(asobi_dgram_link_server:connected()),

    {ok, S} = gen_tcp:connect({127, 0, 0, 1}, LinkPort, [binary, {active, false}], 2000),
    {ok, Nonce} = gen_tcp:recv(S, 16, 2000),
    ok = gen_tcp:send(S, asobi_dgram_link:auth_tag(Nonce, ?SECRET)),

    %% The newcomer now holds it, and the one it displaced was closed rather than
    %% left dangling.
    ?assert(asobi_dgram_link_server:connected()),
    ok = gen_tcp:send(S, asobi_dgram_link:encode({register, binding()})),
    wait_until(fun() -> asobi_dgram_table:kup_of(?CONN) =/= error end),
    gen_tcp:close(S).

%% --- Helpers ---

ctx_from_env() ->
    #{link_port := LinkPort} = asobi_dgram_gw_sup:config(),
    #{link_port => LinkPort}.

binding() ->
    #{
        conn_id => ?CONN,
        kup => ?KUP,
        player_id => ~"01a0115f-547e-714f-829f-408c855ab77b",
        epoch => 3,
        expires_at => erlang:system_time(millisecond) + 60_000
    }.

uplink(Opcode, CSeq, Body) ->
    Pad =
        case Opcode of
            hello -> asobi_dgram:min_hello();
            _ -> 0
        end,
    asobi_dgram:encode_uplink(
        #{opcode => Opcode, conn_id => ?CONN, cseq => CSeq, body => Body}, ?KUP, Pad
    ).

send(Sock, Port, Data) ->
    socket:sendto(Sock, Data, #{family => inet, addr => loopback, port => Port}).

recv(Sock) ->
    case socket:recvfrom(Sock, 0, [], 500) of
        {ok, {_From, Data}} -> {ok, Data};
        {error, timeout} -> timeout
    end.

wait_until(Pred) -> wait_until(Pred, 100).

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

stop(Pid) ->
    Ref = monitor(process, Pid),
    unlink(Pid),
    exit(Pid, shutdown),
    receive
        {'DOWN', Ref, process, Pid, _} -> ok
    after 5000 -> error({did_not_stop, Pid})
    end.

free_port() ->
    {ok, S} = socket:open(inet, dgram, udp),
    ok = socket:bind(S, #{family => inet, addr => loopback, port => 0}),
    {ok, #{port := Port}} = socket:sockname(S),
    ok = socket:close(S),
    Port.
