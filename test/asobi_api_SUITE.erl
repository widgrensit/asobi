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
    %% Pre-register a player for the players group
    PlayerUsername = asobi_test_helpers:unique_username(~"player_test"),
    {ok, Resp} = nova_test:post(
        ~"/api/v1/auth/register",
        #{json => #{~"username" => PlayerUsername, ~"password" => ~"testpass123"}},
        Config0
    ),
    Body = nova_test:json(Resp),
    [
        {test_username, Username},
        {player_username, PlayerUsername},
        {player_id, maps:get(~"player_id", Body)},
        {session_token, maps:get(~"session_token", Body)}
        | Config0
    ].

end_per_suite(Config) ->
    Config.

init_per_group(players, Config) ->
    %% Get a fresh token since the auth group may have invalidated the old one
    PlayerUsername = proplists:get_value(player_username, Config),
    {ok, Resp} = nova_test:post(
        ~"/api/v1/auth/login",
        #{json => #{~"username" => PlayerUsername, ~"password" => ~"testpass123"}},
        Config
    ),
    Body = nova_test:json(Resp),
    [
        {session_token, maps:get(~"session_token", Body)},
        {player_id, maps:get(~"player_id", Body)}
        | Config
    ];
init_per_group(_Group, Config) ->
    Config.

end_per_group(_Group, Config) ->
    Config.

%% --- Auth Tests ---

register_player(Config) ->
    Username = proplists:get_value(test_username, Config),
    {ok, Resp} = nova_test:post(
        ~"/api/v1/auth/register",
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
    Username = proplists:get_value(test_username, Config),
    {ok, Resp} = nova_test:post(
        ~"/api/v1/auth/register",
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
        ~"/api/v1/auth/register",
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
        ~"/api/v1/auth/register",
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
    Username = proplists:get_value(test_username, Config),
    {ok, Resp} = nova_test:post(
        ~"/api/v1/auth/login",
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
    Username = proplists:get_value(test_username, Config),
    {ok, Resp} = nova_test:post(
        ~"/api/v1/auth/login",
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
    Token = proplists:get_value(session_token, Config),
    {ok, Resp} = nova_test:post(
        ~"/api/v1/auth/refresh",
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
    Token = proplists:get_value(session_token, Config),
    PlayerId = proplists:get_value(player_id, Config),
    {ok, Resp} = nova_test:get(
        iolist_to_binary([~"/api/v1/players/", PlayerId]),
        #{headers => [{~"authorization", iolist_to_binary([~"Bearer ", Token])}]},
        Config
    ),
    ?assertStatus(200, Resp),
    Body = nova_test:json(Resp),
    ?assertMatch(#{~"username" := _}, Body),
    Config.

update_player(Config) ->
    Token = proplists:get_value(session_token, Config),
    PlayerId = proplists:get_value(player_id, Config),
    {ok, Resp} = nova_test:put(
        iolist_to_binary([~"/api/v1/players/", PlayerId]),
        #{
            headers => [{~"authorization", iolist_to_binary([~"Bearer ", Token])}],
            json => #{~"display_name" => ~"Updated Name"}
        },
        Config
    ),
    ?assertStatus(200, Resp),
    Body = nova_test:json(Resp),
    ?assertMatch(#{~"display_name" := ~"Updated Name"}, Body),
    Config.

update_player_unauthorized(Config) ->
    Token = proplists:get_value(session_token, Config),
    {ok, Resp} = nova_test:put(
        ~"/api/v1/players/00000000-0000-0000-0000-000000000000",
        #{
            headers => [{~"authorization", iolist_to_binary([~"Bearer ", Token])}],
            json => #{~"display_name" => ~"Hacked"}
        },
        Config
    ),
    ?assertStatus(403, Resp),
    Config.

%% --- Health Tests ---

health_check(Config) ->
    {ok, Resp} = nova_test:get(~"/health", Config),
    ?assertStatus(200, Resp),
    Body = nova_test:json(Resp),
    ?assertMatch(#{~"status" := _}, Body),
    Config.

readiness_check(Config) ->
    {ok, Resp} = nova_test:get(~"/ready", Config),
    ?assertStatus(200, Resp),
    Body = nova_test:json(Resp),
    ?assertMatch(#{~"status" := ~"ready"}, Body),
    Config.

liveness_check(Config) ->
    {ok, Resp} = nova_test:get(~"/live", Config),
    ?assertStatus(200, Resp),
    Body = nova_test:json(Resp),
    ?assertMatch(#{~"status" := ~"alive"}, Body),
    Config.
