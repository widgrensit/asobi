-module(asobi_guest_SUITE).

-include_lib("nova_test/include/nova_test.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([
    create_then_resume_same_player/1,
    wrong_secret_rejected_no_new_player/1,
    weak_secret_rejected/1,
    upgrade_then_already_claimed/1,
    reaper_removes_unclaimed_guest_and_children/1
]).

all() ->
    [
        create_then_resume_same_player,
        wrong_secret_rejected_no_new_player,
        weak_secret_rejected,
        upgrade_then_already_claimed,
        reaper_removes_unclaimed_guest_and_children
    ].

init_per_suite(Config) ->
    %% Set before the app starts so the sup starts the reaper and guest is on.
    application:set_env(asobi, guest_auth, true),
    application:set_env(asobi, guest_verifier_pepper, crypto:strong_rand_bytes(32)),
    application:set_env(asobi, guest_reap_after, 1),
    asobi_test_helpers:start(Config).

end_per_suite(Config) ->
    Config.

%% --- Helpers ---

secret() ->
    base64:encode(crypto:strong_rand_bytes(32)).

device_id() ->
    base64:encode(crypto:strong_rand_bytes(16)).

%% The reaper only starts at boot when guest_auth is set then; the suite enables
%% guest_auth for its run, so start it on demand for the reaping test.
ensure_reaper() ->
    case whereis(asobi_guest_reaper) of
        undefined -> {ok, _} = asobi_guest_reaper:start_link();
        _ -> ok
    end.

create(DeviceId, Secret, Config) ->
    nova_test:post(
        "/api/v1/auth/guest",
        #{json => #{~"device_id" => DeviceId, ~"device_secret" => Secret}},
        Config
    ).

%% --- Tests ---

create_then_resume_same_player(Config) ->
    Dev = device_id(),
    Secret = secret(),
    {ok, R1} = create(Dev, Secret, Config),
    ?assertStatus(200, R1),
    #{~"player_id" := Pid1} = nova_test:json(R1),
    {ok, R2} = create(Dev, Secret, Config),
    ?assertStatus(200, R2),
    #{~"player_id" := Pid2} = nova_test:json(R2),
    ?assertEqual(Pid1, Pid2),
    Config.

wrong_secret_rejected_no_new_player(Config) ->
    Dev = device_id(),
    {ok, R1} = create(Dev, secret(), Config),
    #{~"player_id" := Pid} = nova_test:json(R1),
    {ok, R2} = create(Dev, secret(), Config),
    ?assertStatus(401, R2),
    %% The original secret still resumes the same, single player.
    {ok, R3} = create(Dev, secret(), Config),
    ?assertStatus(401, R3),
    ?assert(is_binary(Pid)),
    Config.

weak_secret_rejected(Config) ->
    {ok, R} = create(device_id(), base64:encode(crypto:strong_rand_bytes(16)), Config),
    ?assertStatus(400, R),
    Config.

upgrade_then_already_claimed(Config) ->
    {ok, R1} = create(device_id(), secret(), Config),
    #{~"access_token" := Token} = nova_test:json(R1),
    Auth = [{~"authorization", <<"Bearer ", Token/binary>>}],
    Username = asobi_test_helpers:unique_username(~"claimed"),
    {ok, R2} = nova_test:post(
        "/api/v1/auth/guest/upgrade",
        #{json => #{~"username" => Username, ~"password" => ~"secret1234"}, headers => Auth},
        Config
    ),
    ?assertStatus(200, R2),
    %% A second upgrade on the now-claimed account is refused.
    {ok, R3} = nova_test:post(
        "/api/v1/auth/guest/upgrade",
        #{json => #{~"username" => ~"other", ~"password" => ~"secret1234"}, headers => Auth},
        Config
    ),
    ?assertStatus(409, R3),
    Config.

reaper_removes_unclaimed_guest_and_children(Config) ->
    ensure_reaper(),
    {ok, R1} = create(device_id(), secret(), Config),
    #{~"player_id" := Pid} = nova_test:json(R1),
    timer:sleep(1100),
    {ok, _} = asobi_guest_reaper:sweep_now(),
    ?assertEqual({error, not_found}, asobi_repo:get(asobi_player, Pid)),
    Config.
