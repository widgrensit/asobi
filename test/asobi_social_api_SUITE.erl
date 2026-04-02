-module(asobi_social_api_SUITE).

-include_lib("nova_test/include/nova_test.hrl").

-export([all/0, groups/0, init_per_suite/1, end_per_suite/1]).
-export([
    show_group/1,
    show_group_not_found/1,
    leave_group/1,
    leave_group_not_member/1,
    chat_history_empty/1,
    chat_history_with_messages/1
]).

all() -> [{group, groups_api}, {group, chat_api}].

groups() ->
    [
        {groups_api, [sequence], [
            show_group, show_group_not_found, leave_group, leave_group_not_member
        ]},
        {chat_api, [sequence], [
            chat_history_empty, chat_history_with_messages
        ]}
    ].

init_per_suite(Config) ->
    Config0 = asobi_test_helpers:start(Config),
    U1 = asobi_test_helpers:unique_username(~"sapi1_"),
    U2 = asobi_test_helpers:unique_username(~"sapi2_"),
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
    #{~"session_token" := P1Token, ~"player_id" := P1Id} = B1,
    #{~"session_token" := P2Token, ~"player_id" := P2Id} = B2,
    true = is_binary(P1Id),
    true = is_binary(P2Id),
    true = is_binary(P1Token),
    true = is_binary(P2Token),
    {ok, GR} = nova_test:post(
        "/api/v1/groups",
        #{
            headers => auth(P1Token),
            json => #{
                ~"name" => ~"API Test Guild", ~"description" => ~"For API tests", ~"open" => true
            }
        },
        Config0
    ),
    #{~"id" := GroupId} = nova_test:json(GR),
    true = is_binary(GroupId),
    {ok, _} = nova_test:post(
        "/api/v1/groups/" ++ binary_to_list(GroupId) ++ "/join",
        #{headers => auth(P2Token), json => #{}},
        Config0
    ),
    ChannelId = iolist_to_binary([
        ~"test_chat_api_", integer_to_binary(erlang:unique_integer([positive]))
    ]),
    asobi_chat_channel:join(ChannelId, self()),
    asobi_chat_channel:send_message(ChannelId, P1Id, ~"Hello from p1"),
    asobi_chat_channel:send_message(ChannelId, P2Id, ~"Hello from p2"),
    asobi_chat_channel:send_message(ChannelId, P1Id, ~"Another message"),
    timer:sleep(50),
    [
        {player1_id, P1Id},
        {player1_token, P1Token},
        {player2_id, P2Id},
        {player2_token, P2Token},
        {group_id, GroupId},
        {channel_id, ChannelId}
        | Config0
    ].

end_per_suite(Config) ->
    Config.

auth(Token) when is_binary(Token) ->
    [{~"authorization", <<"Bearer ", Token/binary>>}].

%% --- Group API ---

show_group(Config) ->
    {group_id, GroupId} = lists:keyfind(group_id, 1, Config),
    {player1_token, Token} = lists:keyfind(player1_token, 1, Config),
    true = is_binary(GroupId),
    true = is_binary(Token),
    {ok, Resp} = nova_test:get(
        "/api/v1/groups/" ++ binary_to_list(GroupId),
        #{headers => auth(Token)},
        Config
    ),
    ?assertStatus(200, Resp),
    Body = nova_test:json(Resp),
    ?assertMatch(#{~"id" := GroupId, ~"name" := ~"API Test Guild"}, Body),
    Config.

show_group_not_found(Config) ->
    {player1_token, Token} = lists:keyfind(player1_token, 1, Config),
    true = is_binary(Token),
    {ok, Resp} = nova_test:get(
        "/api/v1/groups/00000000-0000-0000-0000-000000000000",
        #{headers => auth(Token)},
        Config
    ),
    ?assertStatus(404, Resp),
    Config.

leave_group(Config) ->
    {group_id, GroupId} = lists:keyfind(group_id, 1, Config),
    {player2_token, Token} = lists:keyfind(player2_token, 1, Config),
    true = is_binary(GroupId),
    true = is_binary(Token),
    {ok, Resp} = nova_test:post(
        "/api/v1/groups/" ++ binary_to_list(GroupId) ++ "/leave",
        #{headers => auth(Token), json => #{}},
        Config
    ),
    ?assertStatus(200, Resp),
    #{~"success" := true} = nova_test:json(Resp),
    Config.

leave_group_not_member(Config) ->
    {group_id, GroupId} = lists:keyfind(group_id, 1, Config),
    {player2_token, Token} = lists:keyfind(player2_token, 1, Config),
    true = is_binary(GroupId),
    true = is_binary(Token),
    {ok, Resp} = nova_test:post(
        "/api/v1/groups/" ++ binary_to_list(GroupId) ++ "/leave",
        #{headers => auth(Token), json => #{}},
        Config
    ),
    ?assertStatus(200, Resp),
    Config.

%% --- Chat API ---

chat_history_empty(Config) ->
    {player1_token, Token} = lists:keyfind(player1_token, 1, Config),
    true = is_binary(Token),
    {ok, Resp} = nova_test:get(
        "/api/v1/chat/nonexistent_channel/history",
        #{headers => auth(Token)},
        Config
    ),
    ?assertStatus(200, Resp),
    ?assertJson(#{~"messages" := []}, Resp),
    Config.

chat_history_with_messages(Config) ->
    {channel_id, ChannelId} = lists:keyfind(channel_id, 1, Config),
    {player1_token, Token} = lists:keyfind(player1_token, 1, Config),
    true = is_binary(ChannelId),
    true = is_binary(Token),
    {ok, Resp} = nova_test:get(
        "/api/v1/chat/" ++ binary_to_list(ChannelId) ++ "/history",
        #{headers => auth(Token)},
        Config
    ),
    ?assertStatus(200, Resp),
    #{~"messages" := Messages} = nova_test:json(Resp),
    true = is_list(Messages),
    ?assert(length(Messages) >= 3),
    Config.
