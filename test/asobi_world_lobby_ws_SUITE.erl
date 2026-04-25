-module(asobi_world_lobby_ws_SUITE).
-moduledoc """
End-to-end WebSocket coverage for `world.find_or_create`.

The in-process suite (`asobi_world_lobby_SUITE`) pins the lobby logic.
This suite drives the actual WebSocket protocol with multiple real
clients to catch bugs that only manifest through the full WS handler
path — auth, session bookkeeping, world join, and the resulting world
identity returned to the client.
""".

-include_lib("nova_test/include/nova_test.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1, init_per_testcase/2, end_per_testcase/2]).
-export([
    two_clients_share_hub_world/1,
    sequential_clients_reuse_existing_world/1,
    different_modes_get_different_worlds/1,
    full_world_spawns_a_new_one/1
]).

-define(MODE_HUB, ~"test_ws_hub").
-define(MODE_ARENA, ~"test_ws_arena").
-define(MODE_SOLO, ~"test_ws_solo").

all() ->
    [
        two_clients_share_hub_world,
        sequential_clients_reuse_existing_world,
        different_modes_get_different_worlds,
        full_world_spawns_a_new_one
    ].

init_per_suite(Config) ->
    Config1 = asobi_test_helpers:start(Config),
    application:set_env(asobi, game_modes, #{
        ?MODE_HUB => #{
            type => world,
            module => asobi_test_world_game,
            max_players => 4,
            grid_size => 1,
            zone_size => 100,
            tick_rate => 50
        },
        ?MODE_ARENA => #{
            type => world,
            module => asobi_test_world_game,
            max_players => 4,
            grid_size => 1,
            zone_size => 100,
            tick_rate => 50
        },
        ?MODE_SOLO => #{
            type => world,
            module => asobi_test_world_game,
            max_players => 1,
            grid_size => 1,
            zone_size => 100,
            tick_rate => 50
        }
    }),
    Config1.

end_per_suite(_Config) ->
    application:unset_env(asobi, game_modes),
    ok.

init_per_testcase(_TC, Config) ->
    cleanup_worlds(),
    Config.

end_per_testcase(_TC, _Config) ->
    cleanup_worlds(),
    ok.

%% --- tests ---

two_clients_share_hub_world(Config) ->
    {_P1, Tok1} = register_player(~"a", Config),
    {_P2, Tok2} = register_player(~"b", Config),
    Conn1 = ws_connect_authed(Tok1, Config),
    Conn2 = ws_connect_authed(Tok2, Config),
    World1 = ws_find_or_create(?MODE_HUB, ~"a1", Conn1),
    World2 = ws_find_or_create(?MODE_HUB, ~"b1", Conn2),
    nova_test_ws:close(Conn1),
    nova_test_ws:close(Conn2),
    ?assertEqual(
        World1,
        World2,
        "two WS clients in the same mode must share a single world"
    ),
    Config.

sequential_clients_reuse_existing_world(Config) ->
    {_P1, Tok1} = register_player(~"s1", Config),
    Conn1 = ws_connect_authed(Tok1, Config),
    World1 = ws_find_or_create(?MODE_HUB, ~"s1c1", Conn1),
    nova_test_ws:close(Conn1),

    {_P2, Tok2} = register_player(~"s2", Config),
    Conn2 = ws_connect_authed(Tok2, Config),
    World2 = ws_find_or_create(?MODE_HUB, ~"s2c1", Conn2),
    nova_test_ws:close(Conn2),

    ?assertEqual(
        World1,
        World2,
        "a sequential second WS client must reuse the still-running hub world"
    ),
    Config.

different_modes_get_different_worlds(Config) ->
    {_P, Tok} = register_player(~"d", Config),
    Conn = ws_connect_authed(Tok, Config),
    Hub = ws_find_or_create(?MODE_HUB, ~"d1", Conn),
    Arena = ws_find_or_create(?MODE_ARENA, ~"d2", Conn),
    nova_test_ws:close(Conn),
    ?assertNotEqual(Hub, Arena),
    Config.

full_world_spawns_a_new_one(Config) ->
    %% Solo mode has max_players = 1; two clients can't share.
    {_P1, Tok1} = register_player(~"f1", Config),
    {_P2, Tok2} = register_player(~"f2", Config),
    Conn1 = ws_connect_authed(Tok1, Config),
    Conn2 = ws_connect_authed(Tok2, Config),
    World1 = ws_find_or_create(?MODE_SOLO, ~"f11", Conn1),
    World2 = ws_find_or_create(?MODE_SOLO, ~"f21", Conn2),
    nova_test_ws:close(Conn1),
    nova_test_ws:close(Conn2),
    ?assertNotEqual(
        World1,
        World2,
        "second client in a full solo world must get a fresh world"
    ),
    Config.

%% --- helpers ---

register_player(Suffix, Config) ->
    Username = unique_name(Suffix),
    {ok, Resp} = nova_test:post(
        "/api/v1/auth/register",
        #{json => #{~"username" => Username, ~"password" => ~"testpass123"}},
        Config
    ),
    #{~"player_id" := PlayerId, ~"session_token" := Token} = nova_test:json(Resp),
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

ws_find_or_create(Mode, Cid, Conn) ->
    ok = nova_test_ws:send_json(
        #{
            ~"type" => ~"world.find_or_create",
            ~"cid" => Cid,
            ~"payload" => #{~"mode" => Mode}
        },
        Conn
    ),
    {ok, Joined} = recv_until(
        fun(M) ->
            maps:get(~"type", M, undefined) =:= ~"world.joined" andalso
                maps:get(~"cid", M, undefined) =:= Cid
        end,
        Conn
    ),
    Payload = maps:get(~"payload", Joined),
    maps:get(~"world_id", Payload).

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

cleanup_worlds() ->
    case erlang:whereis(asobi_world_instance_sup) of
        undefined ->
            ok;
        _ ->
            Children = supervisor:which_children(asobi_world_instance_sup),
            [
                supervisor:terminate_child(asobi_world_instance_sup, Pid)
             || {_, Pid, _, _} <- Children, is_pid(Pid)
            ],
            timer:sleep(20),
            ok
    end.
