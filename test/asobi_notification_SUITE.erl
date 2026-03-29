-module(asobi_notification_SUITE).

-include_lib("nova_test/include/nova_test.hrl").

-export([all/0, groups/0, init_per_suite/1, end_per_suite/1]).
-export([
    list_empty/1,
    create_and_list/1,
    mark_read/1,
    delete_notification/1,
    unauthorized_access/1
]).

all() -> [{group, notifications}].

groups() ->
    [
        {notifications, [sequence], [
            list_empty, create_and_list, mark_read, delete_notification, unauthorized_access
        ]}
    ].

init_per_suite(Config) ->
    Config0 = asobi_test_helpers:start(Config),
    U1 = asobi_test_helpers:unique_username(~"notif_p1"),
    U2 = asobi_test_helpers:unique_username(~"notif_p2"),
    {ok, R1} = nova_test:post(
        ~"/api/v1/auth/register",
        #{json => #{~"username" => U1, ~"password" => ~"testpass123"}},
        Config0
    ),
    B1 = nova_test:json(R1),
    {ok, R2} = nova_test:post(
        ~"/api/v1/auth/register",
        #{json => #{~"username" => U2, ~"password" => ~"testpass123"}},
        Config0
    ),
    B2 = nova_test:json(R2),
    [
        {player1_id, maps:get(~"player_id", B1)},
        {player1_token, maps:get(~"session_token", B1)},
        {player2_token, maps:get(~"session_token", B2)}
        | Config0
    ].

end_per_suite(Config) ->
    nova_test:stop(Config).

auth(Config, Player) ->
    Key = list_to_atom(atom_to_list(Player) ++ "_token"),
    Token = proplists:get_value(Key, Config),
    [{~"authorization", iolist_to_binary([~"Bearer ", Token])}].

list_empty(Config) ->
    {ok, Resp} = nova_test:get(
        ~"/api/v1/notifications",
        #{headers => auth(Config, player1)},
        Config
    ),
    ?assertStatus(200, Resp),
    ?assertJson(#{~"notifications" := []}, Resp),
    Config.

create_and_list(Config) ->
    PlayerId = proplists:get_value(player1_id, Config),
    {ok, Notif} = asobi_notify:send(
        PlayerId,
        ~"system",
        ~"Welcome",
        #{~"message" => ~"Welcome to the game!"}
    ),
    NotifId = maps:get(id, Notif),
    {ok, Resp} = nova_test:get(
        ~"/api/v1/notifications",
        #{headers => auth(Config, player1)},
        Config
    ),
    ?assertStatus(200, Resp),
    #{~"notifications" := Notifs} = nova_test:json(Resp),
    ?assert(length(Notifs) >= 1),
    [{notif_id, NotifId} | Config].

mark_read(Config) ->
    NotifId = proplists:get_value(notif_id, Config),
    {ok, Resp} = nova_test:put(
        iolist_to_binary([~"/api/v1/notifications/", NotifId, ~"/read"]),
        #{headers => auth(Config, player1)},
        Config
    ),
    ?assertStatus(200, Resp),
    Body = nova_test:json(Resp),
    ?assertMatch(#{~"read" := true}, Body),
    Config.

delete_notification(Config) ->
    NotifId = proplists:get_value(notif_id, Config),
    {ok, Resp} = nova_test:delete(
        iolist_to_binary([~"/api/v1/notifications/", NotifId]),
        #{headers => auth(Config, player1)},
        Config
    ),
    ?assertStatus(200, Resp),
    Config.

unauthorized_access(Config) ->
    %% Create notification for player1, try to read it as player2
    PlayerId = proplists:get_value(player1_id, Config),
    {ok, Notif} = asobi_notify:send(PlayerId, ~"test", ~"Test", #{~"msg" => ~"hi"}),
    NotifId = maps:get(id, Notif),
    {ok, Resp} = nova_test:put(
        iolist_to_binary([~"/api/v1/notifications/", NotifId, ~"/read"]),
        #{headers => auth(Config, player2)},
        Config
    ),
    ?assertStatus(403, Resp),
    Config.
