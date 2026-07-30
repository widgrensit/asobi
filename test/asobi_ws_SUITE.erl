-module(asobi_ws_SUITE).

-include_lib("nova_test/include/nova_test.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([
    ws_connect_invalid_token/1,
    ws_heartbeat/1,
    ws_unknown_type/1,
    ws_idle_auth_timeout_closes/1,
    ws_match_input_not_in_match_hint/1,
    ws_match_input_hint_rate_limited/1,
    ws_script_error_rendered_as_game_error/1
]).

all() ->
    [
        ws_connect_invalid_token,
        ws_heartbeat,
        ws_unknown_type,
        ws_idle_auth_timeout_closes,
        ws_match_input_not_in_match_hint,
        ws_match_input_hint_rate_limited,
        ws_script_error_rendered_as_game_error
    ].

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

%% #236: match.input with no joined match/zone is dropped, but the sender
%% must get a `not_in_match` hint so the drop is debuggable client-side.
ws_match_input_not_in_match_hint(Config) ->
    {_, Token} = register_player(~"nomatch", Config),
    Conn = ws_connect_authed(Token, Config),
    ok = nova_test_ws:send_json(
        #{~"type" => ~"match.input", ~"payload" => #{~"message" => ~"up"}},
        Conn
    ),
    {ok, Reply} = recv_until(
        fun(M) -> maps:get(~"type", M, undefined) =:= ~"error" end, Conn
    ),
    nova_test_ws:close(Conn),
    ?assertMatch(
        #{~"payload" := #{~"reason" := ~"not_in_match", ~"type" := ~"match.input"}}, Reply
    ),
    Config.

%% #236: the hint is per-connection rate-limited - a client spamming input
%% while unjoined gets one hint per window, not a reflected stream.
ws_match_input_hint_rate_limited(Config) ->
    {_, Token} = register_player(~"nomatchrl", Config),
    Conn = ws_connect_authed(Token, Config),
    Input = #{~"type" => ~"match.input", ~"payload" => #{~"message" => ~"up"}},
    ok = nova_test_ws:send_json(Input, Conn),
    {ok, _} = recv_until(
        fun(M) -> maps:get(~"type", M, undefined) =:= ~"error" end, Conn
    ),
    ok = nova_test_ws:send_json(Input, Conn),
    ok = nova_test_ws:send_json(Input, Conn),
    ?assertEqual({error, timeout}, nova_test_ws:recv(Conn, 300)),
    nova_test_ws:close(Conn),
    Config.

%% asobi_lua#98: a {script_error, Payload} presence message (sent by the
%% Lua runtime in dev-errors mode) must reach the client as a game.error
%% wire event carrying the payload unchanged.
ws_script_error_rendered_as_game_error(Config) ->
    {PlayerId, Token} = register_player(~"scripterr", Config),
    Conn = ws_connect_authed(Token, Config),
    asobi_presence:send(
        PlayerId,
        {script_error, #{
            ~"callback" => ~"handle_input",
            ~"script" => ~"match.lua",
            ~"message" => ~"bad arithmetic + on nil, 1"
        }}
    ),
    {ok, Reply} = recv_until(
        fun(M) -> maps:get(~"type", M, undefined) =:= ~"game.error" end, Conn
    ),
    nova_test_ws:close(Conn),
    ?assertMatch(
        #{
            ~"payload" := #{
                ~"callback" := ~"handle_input",
                ~"script" := ~"match.lua",
                ~"message" := ~"bad arithmetic + on nil, 1"
            }
        },
        Reply
    ),
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

%% --- helpers (mirrors asobi_chat_ws_SUITE) ---

register_player(Suffix, Config) ->
    Username = unique_name(Suffix),
    {ok, Resp} = nova_test:post(
        "/api/v1/auth/register",
        #{json => #{~"username" => Username, ~"password" => ~"testpass123"}},
        Config
    ),
    #{~"player_id" := PlayerId, ~"access_token" := Token} = nova_test:json(Resp),
    {PlayerId, Token}.

unique_name(Suffix) ->
    N = integer_to_binary(erlang:unique_integer([positive])),
    <<"wsprobe_", N/binary, "_", Suffix/binary>>.

ws_connect_authed(Token, Config) ->
    {ok, Conn} = nova_test_ws:connect("/ws", Config),
    ok = nova_test_ws:send_json(
        #{
            ~"type" => ~"session.connect",
            ~"cid" => ~"sess",
            ~"payload" => #{~"token" => Token}
        },
        Conn
    ),
    {ok, _} = recv_until(
        fun(M) -> maps:get(~"type", M, undefined) =:= ~"session.connected" end,
        Conn
    ),
    Conn.

recv_until(Pred, Conn) ->
    recv_until(Pred, Conn, 50).

recv_until(_Pred, _Conn, 0) ->
    {error, predicate_not_matched};
recv_until(Pred, Conn, N) ->
    case nova_test_ws:recv_json(Conn) of
        {ok, Msg} ->
            case Pred(Msg) of
                true -> {ok, Msg};
                false -> recv_until(Pred, Conn, N - 1)
            end;
        {error, _} = Err ->
            Err
    end.
