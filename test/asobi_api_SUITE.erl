-module(asobi_api_SUITE).

-include_lib("nova_test/include/nova_test.hrl").

-export([
    all/0,
    groups/0,
    init_per_suite/1,
    end_per_suite/1,
    init_per_group/2,
    end_per_group/2
]).
-export([
    register_player/1,
    register_duplicate_username/1,
    register_short_username/1,
    register_short_password/1,
    login_success/1,
    login_invalid_credentials/1,
    refresh_token/1,
    get_player/1,
    update_player/1,
    update_player_unauthorized/1,
    health_check/1,
    readiness_check/1,
    liveness_check/1
]).

all() ->
    [{group, auth}, {group, players}, {group, health}].

groups() ->
    [
        {auth, [sequence], [
            register_player,
            register_duplicate_username,
            register_short_username,
            register_short_password,
            login_success,
            login_invalid_credentials,
            refresh_token
        ]},
        {players, [sequence], [
            get_player,
            update_player,
            update_player_unauthorized
        ]},
        {health, [], [
            health_check,
            readiness_check,
            liveness_check
        ]}
    ].

init_per_suite(Config) ->
    Config0 = asobi_test_helpers:start(Config),
    Username = asobi_test_helpers:unique_username(~"testplayer"),
    PlayerUsername = asobi_test_helpers:unique_username(~"player_test"),
    {ok, Resp} = nova_test:post(
        "/api/v1/auth/register",
        #{json => #{~"username" => PlayerUsername, ~"password" => ~"testpass123"}},
        Config0
    ),
    #{~"player_id" := PlayerId, ~"session_token" := SessionToken} = nova_test:json(Resp),
    [
        {test_username, Username},
        {player_username, PlayerUsername},
        {player_id, PlayerId},
        {session_token, SessionToken}
        | Config0
    ].

end_per_suite(Config) ->
    Config.

init_per_group(players, Config) ->
    {player_username, PlayerUsername} = lists:keyfind(player_username, 1, Config),
    {ok, Resp} = nova_test:post(
        "/api/v1/auth/login",
        #{json => #{~"username" => PlayerUsername, ~"password" => ~"testpass123"}},
        Config
    ),
    #{~"session_token" := SessionToken, ~"player_id" := PlayerId} = nova_test:json(Resp),
    [
        {session_token, SessionToken},
        {player_id, PlayerId}
        | Config
    ];
init_per_group(_Group, Config) ->
    Config.

end_per_group(_Group, Config) ->
    Config.

%% --- Auth Tests ---

register_player(Config) ->
    {test_username, Username} = lists:keyfind(test_username, 1, Config),
    {ok, Resp} = nova_test:post(
        "/api/v1/auth/register",
        #{
            json => #{
                ~"username" => Username,
                ~"password" => ~"testpass123",
                ~"display_name" => ~"Test Player"
            }
        },
        Config
    ),
    ?assertStatus(200, Resp),
    Body = nova_test:json(Resp),
    ?assertMatch(#{~"player_id" := _, ~"session_token" := _}, Body),
    Config.

register_duplicate_username(Config) ->
    {test_username, Username} = lists:keyfind(test_username, 1, Config),
    {ok, Resp} = nova_test:post(
        "/api/v1/auth/register",
        #{
            json => #{
                ~"username" => Username,
                ~"password" => ~"testpass123"
            }
        },
        Config
    ),
    ?assertStatus(422, Resp),
    Config.

register_short_username(Config) ->
    {ok, Resp} = nova_test:post(
        "/api/v1/auth/register",
        #{
            json => #{
                ~"username" => ~"ab",
                ~"password" => ~"testpass123"
            }
        },
        Config
    ),
    ?assertStatus(422, Resp),
    Config.

register_short_password(Config) ->
    {ok, Resp} = nova_test:post(
        "/api/v1/auth/register",
        #{
            json => #{
                ~"username" => ~"shortpwuser",
                ~"password" => ~"short"
            }
        },
        Config
    ),
    ?assertStatus(422, Resp),
    Config.

login_success(Config) ->
    {test_username, Username} = lists:keyfind(test_username, 1, Config),
    {ok, Resp} = nova_test:post(
        "/api/v1/auth/login",
        #{
            json => #{
                ~"username" => Username,
                ~"password" => ~"testpass123"
            }
        },
        Config
    ),
    ?assertStatus(200, Resp),
    Body = nova_test:json(Resp),
    ?assertMatch(#{~"player_id" := _, ~"session_token" := _}, Body),
    Config.

login_invalid_credentials(Config) ->
    {test_username, Username} = lists:keyfind(test_username, 1, Config),
    {ok, Resp} = nova_test:post(
        "/api/v1/auth/login",
        #{
            json => #{
                ~"username" => Username,
                ~"password" => ~"wrongpassword"
            }
        },
        Config
    ),
    ?assertStatus(401, Resp),
    Config.

refresh_token(Config) ->
    {session_token, Token} = lists:keyfind(session_token, 1, Config),
    {ok, Resp} = nova_test:post(
        "/api/v1/auth/refresh",
        #{
            json => #{~"session_token" => Token}
        },
        Config
    ),
    ?assertStatus(200, Resp),
    Body = nova_test:json(Resp),
    ?assertMatch(#{~"player_id" := _, ~"session_token" := _}, Body),
    Config.

%% --- Player Tests ---

get_player(Config) ->
    {session_token, Token} = lists:keyfind(session_token, 1, Config),
    {player_id, PlayerId} = lists:keyfind(player_id, 1, Config),
    true = is_binary(Token),
    true = is_binary(PlayerId),
    {ok, Resp} = nova_test:get(
        "/api/v1/players/" ++ binary_to_list(PlayerId),
        #{headers => [{~"authorization", <<"Bearer ", Token/binary>>}]},
        Config
    ),
    ?assertStatus(200, Resp),
    Body = nova_test:json(Resp),
    ?assertMatch(#{~"username" := _}, Body),
    %% Regression: hashed_password and password must never leak.
    ?assertEqual(error, maps:find(~"hashed_password", Body)),
    ?assertEqual(error, maps:find(~"password", Body)),
    Config.

update_player(Config) ->
    {session_token, Token} = lists:keyfind(session_token, 1, Config),
    {player_id, PlayerId} = lists:keyfind(player_id, 1, Config),
    true = is_binary(Token),
    true = is_binary(PlayerId),
    {ok, Resp} = nova_test:put(
        "/api/v1/players/" ++ binary_to_list(PlayerId),
        #{
            headers => [{~"authorization", <<"Bearer ", Token/binary>>}],
            json => #{~"display_name" => ~"Updated Name"}
        },
        Config
    ),
    ?assertStatus(200, Resp),
    Body = nova_test:json(Resp),
    ?assertMatch(#{~"display_name" := ~"Updated Name"}, Body),
    ?assertEqual(error, maps:find(~"hashed_password", Body)),
    Config.

update_player_unauthorized(Config) ->
    {session_token, Token} = lists:keyfind(session_token, 1, Config),
    true = is_binary(Token),
    {ok, Resp} = nova_test:put(
        "/api/v1/players/00000000-0000-0000-0000-000000000000",
        #{
            headers => [{~"authorization", <<"Bearer ", Token/binary>>}],
            json => #{~"display_name" => ~"Hacked"}
        },
        Config
    ),
    ?assertStatus(403, Resp),
    Config.

%% --- Health Tests ---

health_check(Config) ->
    {ok, Resp} = nova_test:get("/health", Config),
    ?assertStatus(200, Resp),
    Body = nova_test:json(Resp),
    ?assertMatch(#{~"status" := _}, Body),
    Config.

readiness_check(Config) ->
    {ok, Resp} = nova_test:get("/ready", Config),
    ?assertStatus(200, Resp),
    Body = nova_test:json(Resp),
    ?assertMatch(#{~"status" := ~"ready"}, Body),
    Config.

liveness_check(Config) ->
    {ok, Resp} = nova_test:get("/live", Config),
    ?assertStatus(200, Resp),
    Body = nova_test:json(Resp),
    ?assertMatch(#{~"status" := ~"alive"}, Body),
    Config.
