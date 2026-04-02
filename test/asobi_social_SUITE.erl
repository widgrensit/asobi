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
    Config0 = asobi_test_helpers:start(Config),
    U1 = asobi_test_helpers:unique_username(~"social_p1"),
    U2 = asobi_test_helpers:unique_username(~"social_p2"),
    {ok, R1} = nova_test:post(
        "/api/v1/auth/register",
        #{json => #{~"username" => U1, ~"password" => ~"testpass123"}},
        Config0
    ),
    B1 = nova_test:json(R1),
    {ok, R2} = nova_test:post(
        "/api/v1/auth/register",
        #{json => #{~"username" => U2, ~"password" => ~"testpass123"}},
        Config0
    ),
    B2 = nova_test:json(R2),
    #{~"player_id" := P1Id, ~"session_token" := P1Token} = B1,
    #{~"player_id" := P2Id, ~"session_token" := P2Token} = B2,
    true = is_binary(P1Token),
    {ok, GR} = nova_test:post(
        "/api/v1/groups",
        #{
            headers => [{~"authorization", <<"Bearer ", P1Token/binary>>}],
            json => #{
                ~"name" => ~"Join Test Guild", ~"description" => ~"For join test", ~"open" => true
            }
        },
        Config0
    ),
    #{~"id" := GroupId} = nova_test:json(GR),
    [
        {player1_id, P1Id},
        {player1_token, P1Token},
        {player2_id, P2Id},
        {player2_token, P2Token},
        {group_id, GroupId}
        | Config0
    ].

end_per_suite(Config) ->
    Config.

auth_headers(Config, Player) ->
    Key = list_to_atom(atom_to_list(Player) ++ "_token"),
    {Key, Token} = lists:keyfind(Key, 1, Config),
    true = is_binary(Token),
    [{~"authorization", <<"Bearer ", Token/binary>>}].

send_friend_request(Config) ->
    {player2_id, P2} = lists:keyfind(player2_id, 1, Config),
    true = is_binary(P2),
    {ok, Resp} = nova_test:post(
        "/api/v1/friends",
        #{
            headers => auth_headers(Config, player1),
            json => #{~"friend_id" => P2}
        },
        Config
    ),
    ?assertStatus(200, Resp),
    Config.

accept_friend_request(Config) ->
    {player1_id, P1} = lists:keyfind(player1_id, 1, Config),
    true = is_binary(P1),
    {ok, Resp} = nova_test:put(
        "/api/v1/friends/" ++ binary_to_list(P1),
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
        "/api/v1/friends",
        #{headers => auth_headers(Config, player1)},
        Config
    ),
    ?assertStatus(200, Resp),
    #{~"friends" := Friends} = nova_test:json(Resp),
    true = is_list(Friends),
    ?assert(length(Friends) >= 1),
    Config.

remove_friend(Config) ->
    {player2_id, P2} = lists:keyfind(player2_id, 1, Config),
    true = is_binary(P2),
    {ok, Resp} = nova_test:delete(
        "/api/v1/friends/" ++ binary_to_list(P2),
        #{headers => auth_headers(Config, player1)},
        Config
    ),
    ?assertStatus(200, Resp),
    Config.

create_group(Config) ->
    {ok, Resp} = nova_test:post(
        "/api/v1/groups",
        #{
            headers => auth_headers(Config, player1),
            json => #{~"name" => ~"Test Guild", ~"description" => ~"A test guild", ~"open" => true}
        },
        Config
    ),
    ?assertStatus(200, Resp),
    #{~"id" := GroupId} = nova_test:json(Resp),
    [{group_id, GroupId} | Config].

join_group(Config) ->
    {group_id, GroupId} = lists:keyfind(group_id, 1, Config),
    true = is_binary(GroupId),
    {ok, Resp} = nova_test:post(
        "/api/v1/groups/" ++ binary_to_list(GroupId) ++ "/join",
        #{headers => auth_headers(Config, player2), json => #{}},
        Config
    ),
    ?assertStatus(200, Resp),
    Config.
