-module(asobi_social_SUITE).

-include_lib("nova_test/include/nova_test.hrl").

-export([all/0, groups/0, init_per_suite/1, end_per_suite/1]).
-export([
    send_friend_request/1,
    accept_friend_request/1,
    list_friends/1,
    remove_friend/1,
    create_group/1,
    join_group/1
]).

all() -> [{group, friends}, {group, groups}].

groups() ->
    [
        {friends, [sequence], [
            send_friend_request, accept_friend_request, list_friends, remove_friend
        ]},
        {groups, [sequence], [create_group, join_group]}
    ].

init_per_suite(Config) ->
    Config0 = nova_test:start(asobi) ++ Config,
    {ok, R1} = nova_test:post(
        ~"/api/v1/auth/register",
        #{
            json => #{~"username" => ~"social_p1", ~"password" => ~"testpass123"}
        },
        Config0
    ),
    B1 = nova_test:json(R1),
    {ok, R2} = nova_test:post(
        ~"/api/v1/auth/register",
        #{
            json => #{~"username" => ~"social_p2", ~"password" => ~"testpass123"}
        },
        Config0
    ),
    B2 = nova_test:json(R2),
    [
        {player1_id, maps:get(~"player_id", B1)},
        {player1_token, maps:get(~"session_token", B1)},
        {player2_id, maps:get(~"player_id", B2)},
        {player2_token, maps:get(~"session_token", B2)}
        | Config0
    ].

end_per_suite(Config) ->
    nova_test:stop(Config).

auth_headers(Config, Player) ->
    Token = proplists:get_value(list_to_atom(atom_to_list(Player) ++ "_token"), Config),
    [{~"authorization", iolist_to_binary([~"Bearer ", Token])}].

send_friend_request(Config) ->
    P2 = proplists:get_value(player2_id, Config),
    {ok, Resp} = nova_test:post(
        ~"/api/v1/friends",
        #{
            headers => auth_headers(Config, player1),
            json => #{~"friend_id" => P2}
        },
        Config
    ),
    ?assertStatus(200, Resp),
    Config.

accept_friend_request(Config) ->
    P1 = proplists:get_value(player1_id, Config),
    {ok, Resp} = nova_test:put(
        iolist_to_binary([~"/api/v1/friends/", P1]),
        #{
            headers => auth_headers(Config, player2),
            json => #{~"status" => ~"accepted"}
        },
        Config
    ),
    ?assertStatus(200, Resp),
    Config.

list_friends(Config) ->
    {ok, Resp} = nova_test:get(
        ~"/api/v1/friends",
        #{headers => auth_headers(Config, player1)},
        Config
    ),
    ?assertStatus(200, Resp),
    #{~"friends" := Friends} = nova_test:json(Resp),
    ?assert(length(Friends) >= 1),
    Config.

remove_friend(Config) ->
    P2 = proplists:get_value(player2_id, Config),
    {ok, Resp} = nova_test:delete(
        iolist_to_binary([~"/api/v1/friends/", P2]),
        #{headers => auth_headers(Config, player1)},
        Config
    ),
    ?assertStatus(200, Resp),
    Config.

create_group(Config) ->
    {ok, Resp} = nova_test:post(
        ~"/api/v1/groups",
        #{
            headers => auth_headers(Config, player1),
            json => #{~"name" => ~"Test Guild", ~"description" => ~"A test guild", ~"open" => true}
        },
        Config
    ),
    ?assertStatus(200, Resp),
    Body = nova_test:json(Resp),
    [{group_id, maps:get(~"id", Body)} | Config].

join_group(Config) ->
    GroupId = proplists:get_value(group_id, Config),
    {ok, Resp} = nova_test:post(
        iolist_to_binary([~"/api/v1/groups/", GroupId, ~"/join"]),
        #{headers => auth_headers(Config, player2)},
        Config
    ),
    ?assertStatus(200, Resp),
    Config.
