-module(asobi_ws_SUITE).

-include_lib("nova_test/include/nova_test.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([
    ws_connect_invalid_token/1,
    ws_heartbeat/1,
    ws_unknown_type/1
]).

all() -> [ws_connect_invalid_token, ws_heartbeat, ws_unknown_type].

init_per_suite(Config) ->
    asobi_test_helpers:start(Config).

end_per_suite(Config) ->
    nova_test:stop(Config).

ws_connect_invalid_token(Config) ->
    {ok, Conn} = nova_test_ws:connect(~"/ws", Config),
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
    {ok, Conn} = nova_test_ws:connect(~"/ws", Config),
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
    {ok, Conn} = nova_test_ws:connect(~"/ws", Config),
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
