-module(asobi_chat_ws_SUITE).
-moduledoc """
H1 (2026-05-19): the WS chat entrypoints must enforce
`asobi_chat_acl:authorized/2`. A third party must not be able to join or
send to a DM channel `dm:<a>:<b>` it is not a party to; the two members
must be able to. Covers the wiring, not just the predicate (which is unit
tested in asobi_chat_acl_tests).
""".

-include_lib("nova_test/include/nova_test.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([
    dm_third_party_join_rejected/1,
    dm_member_join_allowed/1,
    dm_third_party_send_rejected/1
]).

all() ->
    [
        dm_third_party_join_rejected,
        dm_member_join_allowed,
        dm_third_party_send_rejected
    ].

init_per_suite(Config) ->
    asobi_test_helpers:start(Config).

end_per_suite(_Config) ->
    ok.

dm_third_party_join_rejected(Config) ->
    {Alice, _} = register_player(~"alice", Config),
    {Bob, _} = register_player(~"bob", Config),
    {_Eve, EveTok} = register_player(~"eve", Config),
    Conn = ws_connect_authed(EveTok, Config),
    Channel = <<"dm:", Alice/binary, ":", Bob/binary>>,
    ok = nova_test_ws:send_json(
        #{
            ~"type" => ~"chat.join",
            ~"cid" => ~"j1",
            ~"payload" => #{~"channel_id" => Channel}
        },
        Conn
    ),
    {ok, Reply} = recv_until(fun(M) -> maps:get(~"cid", M, undefined) =:= ~"j1" end, Conn),
    nova_test_ws:close(Conn),
    ?assertEqual(~"error", maps:get(~"type", Reply)),
    ?assertEqual(~"not_authorized", maps:get(~"reason", maps:get(~"payload", Reply))),
    Config.

dm_member_join_allowed(Config) ->
    {Alice, AliceTok} = register_player(~"alice2", Config),
    {Bob, _} = register_player(~"bob2", Config),
    Conn = ws_connect_authed(AliceTok, Config),
    Channel = <<"dm:", Alice/binary, ":", Bob/binary>>,
    ok = nova_test_ws:send_json(
        #{
            ~"type" => ~"chat.join",
            ~"cid" => ~"j2",
            ~"payload" => #{~"channel_id" => Channel}
        },
        Conn
    ),
    {ok, Reply} = recv_until(fun(M) -> maps:get(~"cid", M, undefined) =:= ~"j2" end, Conn),
    nova_test_ws:close(Conn),
    ?assertEqual(~"chat.joined", maps:get(~"type", Reply)),
    Config.

dm_third_party_send_rejected(Config) ->
    {Alice, _} = register_player(~"alice3", Config),
    {Bob, _} = register_player(~"bob3", Config),
    {_Eve, EveTok} = register_player(~"eve3", Config),
    Conn = ws_connect_authed(EveTok, Config),
    Channel = <<"dm:", Alice/binary, ":", Bob/binary>>,
    ok = nova_test_ws:send_json(
        #{
            ~"type" => ~"chat.send",
            ~"cid" => ~"s1",
            ~"payload" => #{~"channel_id" => Channel, ~"content" => ~"leak?"}
        },
        Conn
    ),
    {ok, Reply} = recv_until(fun(M) -> maps:get(~"cid", M, undefined) =:= ~"s1" end, Conn),
    nova_test_ws:close(Conn),
    ?assertEqual(~"error", maps:get(~"type", Reply)),
    ?assertEqual(~"not_authorized", maps:get(~"reason", maps:get(~"payload", Reply))),
    Config.

%% --- helpers (mirrors asobi_world_lobby_ws_SUITE) ---

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
    <<"chatprobe_", N/binary, "_", Suffix/binary>>.

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
