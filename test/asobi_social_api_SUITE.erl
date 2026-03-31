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
    P1Token = maps:get(~"session_token", B1),
    P2Token = maps:get(~"session_token", B2),
    %% Create a group and have P2 join it
    {ok, GR} = nova_test:post(
        ~"/api/v1/groups",
        #{
            headers => auth(P1Token),
            json => #{~"name" => ~"API Test Guild", ~"description" => ~"For API tests", ~"open" => true}
        },
        Config0
    ),
    GB = nova_test:json(GR),
    GroupId = maps:get(~"id", GB),
    {ok, _} = nova_test:post(
        iolist_to_binary([~"/api/v1/groups/", GroupId, ~"/join"]),
        #{headers => auth(P2Token), json => #{}},
        Config0
    ),
    %% Create a chat channel and send some messages
    ChannelId = iolist_to_binary([~"test_chat_api_", integer_to_binary(erlang:unique_integer([positive]))]),
    asobi_chat_channel:join(ChannelId, self()),
    asobi_chat_channel:send_message(ChannelId, maps:get(~"player_id", B1), ~"Hello from p1"),
    asobi_chat_channel:send_message(ChannelId, maps:get(~"player_id", B2), ~"Hello from p2"),
    asobi_chat_channel:send_message(ChannelId, maps:get(~"player_id", B1), ~"Another message"),
    timer:sleep(50),
    [
        {player1_id, maps:get(~"player_id", B1)},
        {player1_token, P1Token},
        {player2_id, maps:get(~"player_id", B2)},
        {player2_token, P2Token},
        {group_id, GroupId},
        {channel_id, ChannelId}
        | Config0
    ].

end_per_suite(Config) ->
    Config.

auth(Token) ->
    [{~"authorization", iolist_to_binary([~"Bearer ", Token])}].

%% --- Group API ---

show_group(Config) ->
    GroupId = proplists:get_value(group_id, Config),
    Token = proplists:get_value(player1_token, Config),
    {ok, Resp} = nova_test:get(
        iolist_to_binary([~"/api/v1/groups/", GroupId]),
        #{headers => auth(Token)},
        Config
    ),
    ?assertStatus(200, Resp),
    Body = nova_test:json(Resp),
    ?assertMatch(#{~"id" := GroupId, ~"name" := ~"API Test Guild"}, Body),
    Config.

show_group_not_found(Config) ->
    Token = proplists:get_value(player1_token, Config),
    {ok, Resp} = nova_test:get(
        ~"/api/v1/groups/00000000-0000-0000-0000-000000000000",
        #{headers => auth(Token)},
        Config
    ),
    ?assertStatus(404, Resp),
    Config.

leave_group(Config) ->
    GroupId = proplists:get_value(group_id, Config),
    Token = proplists:get_value(player2_token, Config),
    {ok, Resp} = nova_test:post(
        iolist_to_binary([~"/api/v1/groups/", GroupId, ~"/leave"]),
        #{headers => auth(Token), json => #{}},
        Config
    ),
    ?assertStatus(200, Resp),
    #{~"success" := true} = nova_test:json(Resp),
    Config.

leave_group_not_member(Config) ->
    GroupId = proplists:get_value(group_id, Config),
    Token = proplists:get_value(player2_token, Config),
    %% P2 already left, leaving again should still succeed (idempotent)
    {ok, Resp} = nova_test:post(
        iolist_to_binary([~"/api/v1/groups/", GroupId, ~"/leave"]),
        #{headers => auth(Token), json => #{}},
        Config
    ),
    ?assertStatus(200, Resp),
    Config.

%% --- Chat API ---

chat_history_empty(Config) ->
    Token = proplists:get_value(player1_token, Config),
    {ok, Resp} = nova_test:get(
        ~"/api/v1/chat/nonexistent_channel/history",
        #{headers => auth(Token)},
        Config
    ),
    ?assertStatus(200, Resp),
    ?assertJson(#{~"messages" := []}, Resp),
    Config.

chat_history_with_messages(Config) ->
    ChannelId = proplists:get_value(channel_id, Config),
    Token = proplists:get_value(player1_token, Config),
    {ok, Resp} = nova_test:get(
        iolist_to_binary([~"/api/v1/chat/", ChannelId, ~"/history"]),
        #{headers => auth(Token)},
        Config
    ),
    ?assertStatus(200, Resp),
    #{~"messages" := Messages} = nova_test:json(Resp),
    ?assert(length(Messages) >= 3),
    Config.
