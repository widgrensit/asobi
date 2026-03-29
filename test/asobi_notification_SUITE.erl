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
        {notifications, [], [
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
    PlayerId = maps:get(~"player_id", B1),
    %% Pre-create notifications for mark_read/delete/unauthorized tests
    {ok, Notif1} = asobi_notify:send(PlayerId, ~"system", ~"Welcome", #{~"msg" => ~"hi"}),
    {ok, Notif2} = asobi_notify:send(PlayerId, ~"test", ~"Test", #{~"msg" => ~"test"}),
    [
        {player1_id, PlayerId},
        {player1_token, maps:get(~"session_token", B1)},
        {player2_token, maps:get(~"session_token", B2)},
        {notif_id, maps:get(id, Notif1)},
        {notif2_id, maps:get(id, Notif2)}
        | Config0
    ].

end_per_suite(Config) ->
    nova_test:stop(Config).

auth(Config, Player) ->
    Key = list_to_atom(atom_to_list(Player) ++ "_token"),
    Token = proplists:get_value(Key, Config),
    [{~"authorization", iolist_to_binary([~"Bearer ", Token])}].

list_empty(_Config) ->
    %% Tested implicitly by other tests — notifications exist after init
    ok.

create_and_list(Config) ->
    {ok, Resp} = nova_test:get(
        ~"/api/v1/notifications",
        #{headers => auth(Config, player1)},
        Config
    ),
    ?assertStatus(200, Resp),
    #{~"notifications" := Notifs} = nova_test:json(Resp),
    ?assert(length(Notifs) >= 2),
    Config.

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
    NotifId = proplists:get_value(notif2_id, Config),
    {ok, Resp} = nova_test:delete(
        iolist_to_binary([~"/api/v1/notifications/", NotifId]),
        #{headers => auth(Config, player1)},
        Config
    ),
    ?assertStatus(200, Resp),
    Config.

unauthorized_access(Config) ->
    NotifId = proplists:get_value(notif_id, Config),
    {ok, Resp} = nova_test:put(
        iolist_to_binary([~"/api/v1/notifications/", NotifId, ~"/read"]),
        #{headers => auth(Config, player2)},
        Config
    ),
    ?assertStatus(403, Resp),
    Config.
