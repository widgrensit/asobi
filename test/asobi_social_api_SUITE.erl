-module(asobi_social_api_SUITE).

-include_lib("nova_test/include/nova_test.hrl").

-export([all/0, groups/0, init_per_suite/1, end_per_suite/1]).
-export([
    show_group/1,
    show_group_not_found/1,
    leave_group/1,
    leave_group_not_member/1,
    chat_history_unauthorized_arbitrary_channel/1,
    chat_history_with_messages/1,
    chat_history_non_member_forbidden/1,
    chat_history_dm_non_participant_forbidden/1,
    chat_history_dm_participant_allowed/1
]).

all() -> [{group, groups_api}, {group, chat_api}].

groups() ->
    [
        {groups_api, [sequence], [
            show_group, show_group_not_found, leave_group, leave_group_not_member
        ]},
        {chat_api, [sequence], [
            chat_history_unauthorized_arbitrary_channel,
            chat_history_with_messages,
            chat_history_non_member_forbidden,
            chat_history_dm_non_participant_forbidden,
            chat_history_dm_participant_allowed
        ]}
    ].

init_per_suite(Config) ->
    Config0 = asobi_test_helpers:start(Config),
    U1 = asobi_test_helpers:unique_username(~"sapi1_"),
    U2 = asobi_test_helpers:unique_username(~"sapi2_"),
    U3 = asobi_test_helpers:unique_username(~"sapi3_"),
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
    {ok, R3} = nova_test:post(
        "/api/v1/auth/register",
        #{json => #{~"username" => U3, ~"password" => ~"testpass123"}},
        Config0
    ),
    B3 = nova_test:json(R3),
    #{~"session_token" := P1Token, ~"player_id" := P1Id} = B1,
    #{~"session_token" := P2Token, ~"player_id" := P2Id} = B2,
    #{~"session_token" := P3Token, ~"player_id" := P3Id} = B3,
    true = is_binary(P1Id),
    true = is_binary(P2Id),
    true = is_binary(P3Id),
    true = is_binary(P1Token),
    true = is_binary(P2Token),
    true = is_binary(P3Token),
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
    %% F-10: chat history is now membership-gated. Use the actual GroupId
    %% as the channel_id so P1 (creator) is authorized via asobi_group_member;
    %% P3 will be a non-member who must be denied.
    ChannelId = GroupId,
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
        {player3_id, P3Id},
        {player3_token, P3Token},
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

%% F-10: arbitrary channel ids that don't correspond to a group the
%% requester is a member of must return 403, not leak history.
chat_history_unauthorized_arbitrary_channel(Config) ->
    {player1_token, Token} = lists:keyfind(player1_token, 1, Config),
    true = is_binary(Token),
    {ok, Resp} = nova_test:get(
        "/api/v1/chat/nonexistent_channel/history",
        #{headers => auth(Token)},
        Config
    ),
    ?assertStatus(403, Resp),
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

%% F-10: a player who is not a member of the group MUST not be able to
%% read its chat history.
chat_history_non_member_forbidden(Config) ->
    {channel_id, ChannelId} = lists:keyfind(channel_id, 1, Config),
    {player3_token, Token} = lists:keyfind(player3_token, 1, Config),
    true = is_binary(ChannelId),
    true = is_binary(Token),
    {ok, Resp} = nova_test:get(
        "/api/v1/chat/" ++ binary_to_list(ChannelId) ++ "/history",
        #{headers => auth(Token)},
        Config
    ),
    ?assertStatus(403, Resp),
    Config.

%% F-10: DM channels (`dm:A:B`) must only be readable by A or B.
chat_history_dm_non_participant_forbidden(Config) ->
    {player1_id, P1Id} = lists:keyfind(player1_id, 1, Config),
    {player2_id, P2Id} = lists:keyfind(player2_id, 1, Config),
    {player3_token, EavesdropToken} = lists:keyfind(player3_token, 1, Config),
    DmChannel = asobi_dm:channel_id(P1Id, P2Id),
    true = is_binary(DmChannel),
    {ok, Resp} = nova_test:get(
        "/api/v1/chat/" ++ binary_to_list(DmChannel) ++ "/history",
        #{headers => auth(EavesdropToken)},
        Config
    ),
    ?assertStatus(403, Resp),
    Config.

chat_history_dm_participant_allowed(Config) ->
    {player1_id, P1Id} = lists:keyfind(player1_id, 1, Config),
    {player1_token, Token} = lists:keyfind(player1_token, 1, Config),
    {player2_id, P2Id} = lists:keyfind(player2_id, 1, Config),
    DmChannel = asobi_dm:channel_id(P1Id, P2Id),
    {ok, Resp} = nova_test:get(
        "/api/v1/chat/" ++ binary_to_list(DmChannel) ++ "/history",
        #{headers => auth(Token)},
        Config
    ),
    ?assertStatus(200, Resp),
    Config.
