-module(asobi_ws_SUITE).

-include_lib("nova_test/include/nova_test.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([
    ws_connect_invalid_token/1,
    ws_heartbeat/1,
    ws_unknown_type/1,
    ws_idle_auth_timeout_closes/1
]).

all() -> [ws_connect_invalid_token, ws_heartbeat, ws_unknown_type, ws_idle_auth_timeout_closes].

init_per_suite(Config) ->
    asobi_test_helpers:start(Config).

end_per_suite(Config) ->
    Config.

ws_connect_invalid_token(Config) ->
    {ok, Conn} = nova_test_ws:connect("/ws", Config),
    nova_test_ws:send_json(
        #{
            ~"type" => ~"session.connect",
            ~"cid" => ~"1",
            ~"payload" => #{~"token" => ~"invalid_token"}
        },
        Conn
    ),
    {ok, Resp} = nova_test_ws:recv_json(Conn),
    ?assertMatch(#{~"type" := ~"error", ~"cid" := ~"1"}, Resp),
    nova_test_ws:close(Conn),
    Config.

ws_heartbeat(Config) ->
    {ok, Conn} = nova_test_ws:connect("/ws", Config),
    nova_test_ws:send_json(
        #{
            ~"type" => ~"session.heartbeat",
            ~"cid" => ~"hb1"
        },
        Conn
    ),
    {ok, Resp} = nova_test_ws:recv_json(Conn),
    ?assertMatch(#{~"type" := ~"session.heartbeat", ~"cid" := ~"hb1"}, Resp),
    nova_test_ws:close(Conn),
    Config.

ws_unknown_type(Config) ->
    {ok, Conn} = nova_test_ws:connect("/ws", Config),
    nova_test_ws:send_json(
        #{
            ~"type" => ~"nonexistent.type",
            ~"cid" => ~"u1",
            ~"payload" => #{}
        },
        Conn
    ),
    {ok, Resp} = nova_test_ws:recv_json(Conn),
    ?assertMatch(#{~"type" := ~"error", ~"payload" := #{~"reason" := ~"unknown_type"}}, Resp),
    nova_test_ws:close(Conn),
    Config.

%% A WS that opens and never sends `session.connect` must be closed by
%% the server with code 1008 once the idle-auth window elapses.
ws_idle_auth_timeout_closes(Config) ->
    Old = application:get_env(asobi, ws_idle_auth_timeout_ms),
    application:set_env(asobi, ws_idle_auth_timeout_ms, 200),
    try
        {ok, Conn} = nova_test_ws:connect("/ws", Config),
        ?assertEqual({error, {closed, 1008}}, nova_test_ws:recv(Conn, 2000))
    after
        case Old of
            {ok, V} -> application:set_env(asobi, ws_idle_auth_timeout_ms, V);
            undefined -> application:unset_env(asobi, ws_idle_auth_timeout_ms)
        end
    end,
    Config.
