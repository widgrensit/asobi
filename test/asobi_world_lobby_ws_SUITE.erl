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
    full_world_spawns_a_new_one/1,
    create_reply_reflects_creator_in_player_count/1,
    join_rejects_when_player_already_in_other_world/1
]).

-define(MODE_HUB, ~"test_ws_hub").
-define(MODE_ARENA, ~"test_ws_arena").
-define(MODE_SOLO, ~"test_ws_solo").

all() ->
    [
        two_clients_share_hub_world,
        sequential_clients_reuse_existing_world,
        different_modes_get_different_worlds,
        full_world_spawns_a_new_one,
        create_reply_reflects_creator_in_player_count,
        join_rejects_when_player_already_in_other_world
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

create_reply_reflects_creator_in_player_count(Config) ->
    %% Pre-fix, world.create replied with Info captured BEFORE the implicit
    %% join, so player_count was always 0 even though the creator was about
    %% to be in the world. Lobby UIs rendering "0/N" on freshly-created
    %% worlds is the user-visible symptom.
    {_P, Tok} = register_player(~"crc", Config),
    Conn = ws_connect_authed(Tok, Config),
    {WorldId, PlayerCount} = ws_create(?MODE_HUB, ~"crc1", Conn),
    nova_test_ws:close(Conn),
    ?assert(is_binary(WorldId)),
    ?assertEqual(
        1,
        PlayerCount,
        "world.create reply must report player_count=1 because the creator was joined"
    ),
    Config.

join_rejects_when_player_already_in_other_world(Config) ->
    %% A single player connected via WS must not be able to be in two worlds
    %% at once. world.join into a different world while still in another must
    %% reply with `error` and reason=already_in_world.
    {_P, Tok} = register_player(~"al", Config),
    Conn = ws_connect_authed(Tok, Config),
    %% Create world A.
    {WorldA, _} = ws_create(?MODE_HUB, ~"al1", Conn),
    %% Create world B (forces a new world by going through full mode capacity).
    %% Easier path: spawn a second hub world by filling the first... but max=4.
    %% Instead, use ARENA mode for B so we deterministically get a different world.
    {WorldB, _} = ws_create(?MODE_ARENA, ~"al2", Conn),
    %% At this point, player is implicitly in WorldB (the most recent join).
    %% Now try to world.join WorldA — should be rejected.
    Result = ws_join(WorldA, ~"al3", Conn),
    nova_test_ws:close(Conn),
    ?assertNotEqual(WorldA, WorldB),
    case Result of
        {error, Reason} ->
            ?assertEqual(~"already_in_world", Reason);
        {ok, _} ->
            ct:fail("world.join must reject when player is already in another world")
    end,
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

ws_create(Mode, Cid, Conn) ->
    ok = nova_test_ws:send_json(
        #{
            ~"type" => ~"world.create",
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
    {maps:get(~"world_id", Payload), maps:get(~"player_count", Payload, undefined)}.

ws_join(WorldId, Cid, Conn) ->
    ok = nova_test_ws:send_json(
        #{
            ~"type" => ~"world.join",
            ~"cid" => Cid,
            ~"payload" => #{~"world_id" => WorldId}
        },
        Conn
    ),
    {ok, Reply} = recv_until(
        fun(M) ->
            maps:get(~"cid", M, undefined) =:= Cid
        end,
        Conn
    ),
    case maps:get(~"type", Reply) of
        ~"world.joined" -> {ok, maps:get(~"payload", Reply)};
        ~"error" -> {error, maps:get(~"reason", maps:get(~"payload", Reply))}
    end.

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
