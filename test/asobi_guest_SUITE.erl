-module(asobi_guest_SUITE).

-include_lib("nova_test/include/nova_test.hrl").
-include_lib("kura/include/kura.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([
    create_then_resume_same_player/1,
    wrong_secret_rejected_no_new_player/1,
    weak_secret_rejected/1,
    upgrade_then_already_claimed/1,
    upgrade_rejected_for_non_guest/1,
    upgrade_clears_stale_auth_cache_entries/1,
    reaper_removes_unclaimed_guest_and_children/1,
    create_retries_on_username_collision/1,
    create_no_retry_on_non_unique_username_error/1
]).

all() ->
    [
        create_then_resume_same_player,
        wrong_secret_rejected_no_new_player,
        weak_secret_rejected,
        upgrade_then_already_claimed,
        upgrade_rejected_for_non_guest,
        upgrade_clears_stale_auth_cache_entries,
        reaper_removes_unclaimed_guest_and_children,
        create_retries_on_username_collision,
        create_no_retry_on_non_unique_username_error
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
    %% The pre-upgrade token was revoked (both DB row and auth-cache entry,
    %% asobi#215) as part of the upgrade, so it no longer authenticates at all.
    {ok, R3} = nova_test:post(
        "/api/v1/auth/guest/upgrade",
        #{json => #{~"username" => ~"other", ~"password" => ~"secret1234"}, headers => Auth},
        Config
    ),
    ?assertStatus(401, R3),
    %% A second upgrade attempt with the freshly issued token is refused
    %% because the account is now claimed.
    #{~"access_token" := NewToken} = nova_test:json(R2),
    NewAuth = [{~"authorization", <<"Bearer ", NewToken/binary>>}],
    {ok, R4} = nova_test:post(
        "/api/v1/auth/guest/upgrade",
        #{json => #{~"username" => ~"other", ~"password" => ~"secret1234"}, headers => NewAuth},
        Config
    ),
    ?assertStatus(409, R4),
    Config.

%% A passwordless account that is NOT a guest (e.g. OAuth-only) must not be able
%% to use the guest-upgrade path to set a password and rename itself - the gate
%% is "owns a guest identity AND has no password", not "has no password".
upgrade_rejected_for_non_guest(Config) ->
    Username = asobi_test_helpers:unique_username(~"oauthy"),
    PlayerCS = kura_changeset:validate_required(
        kura_changeset:cast(asobi_player, #{}, #{username => Username}, [username]),
        [username]
    ),
    {ok, Player} = asobi_repo:insert(PlayerCS),
    PlayerId = maps:get(id, Player),
    IdCS = asobi_player_identity:changeset(#{}, #{
        player_id => PlayerId, provider => ~"google", provider_uid => device_id()
    }),
    {ok, _} = asobi_repo:insert(IdCS),
    {json, 200, _, #{access_token := Token}} = asobi_auth_tokens:issue(Player, 200, #{}),
    Auth = [{~"authorization", <<"Bearer ", Token/binary>>}],
    {ok, R} = nova_test:post(
        "/api/v1/auth/guest/upgrade",
        #{json => #{~"username" => ~"hijacked", ~"password" => ~"secret1234"}, headers => Auth},
        Config
    ),
    ?assertStatus(409, R),
    Config.

%% asobi#215: do_upgrade/4 calls nova_auth_refresh:revoke_all/2, which deletes
%% every token DB row for the player - but a token cached as a valid positive
%% BEFORE the upgrade must not keep resolving from the ETS cache afterward.
%% Cover the actual attack this exists for: a second session on the same
%% device secret (the "stolen device secret" scenario the do_upgrade/4
%% comment describes) cached as a stale positive must also stop resolving -
%% not just the token the upgrade request itself carries. A test that only
%% seeds the caller's own token would pass equally with a single-token
%% invalidate/1 instead of the player-wide revoke_player/1 this exercises.
upgrade_clears_stale_auth_cache_entries(Config) ->
    Dev = device_id(),
    Secret = secret(),
    {ok, R1} = create(Dev, Secret, Config),
    #{~"access_token" := Token, ~"player_id" := PlayerId} = nova_test:json(R1),
    Auth = [{~"authorization", <<"Bearer ", Token/binary>>}],
    {ok, R1b} = create(Dev, Secret, Config),
    #{~"access_token" := StolenToken} = nova_test:json(R1b),
    ok = asobi_auth_cache:put_positive(Token, #{id => PlayerId, banned_at => nil}),
    ok = asobi_auth_cache:put_positive(StolenToken, #{id => PlayerId, banned_at => nil}),
    ?assertEqual({ok, #{id => PlayerId, banned_at => nil}}, asobi_auth_cache:resolve_token(Token)),
    ?assertEqual(
        {ok, #{id => PlayerId, banned_at => nil}}, asobi_auth_cache:resolve_token(StolenToken)
    ),
    Username = asobi_test_helpers:unique_username(~"cacheclr"),
    {ok, R2} = nova_test:post(
        "/api/v1/auth/guest/upgrade",
        #{json => #{~"username" => Username, ~"password" => ~"secret1234"}, headers => Auth},
        Config
    ),
    ?assertStatus(200, R2),
    ?assertEqual({error, not_found}, asobi_auth_cache:resolve_token(Token)),
    ?assertEqual({error, not_found}, asobi_auth_cache:resolve_token(StolenToken)),
    Config.

reaper_removes_unclaimed_guest_and_children(Config) ->
    ensure_reaper(),
    {ok, R1} = create(device_id(), secret(), Config),
    #{~"player_id" := Pid} = nova_test:json(R1),
    %% guest_reap_after is 1s and the cutoff is computed at whole-second
    %% granularity (erlang:universaltime/0), so a guest created late in a second
    %% needs >2s to be strictly older than (sweep_second - 1). Sleep past two
    %% second-boundaries to make the reap deterministic.
    timer:sleep(2500),
    {ok, _} = asobi_guest_reaper:sweep_now(),
    ?assertEqual({error, not_found}, asobi_repo:get(asobi_player, Pid)),
    Config.

%% A generated username colliding with an existing one (previously: any two
%% guests created in the same millisecond, since the old suffix was a UUIDv7
%% prefix with zero randomness) must retry with a fresh one instead of
%% surfacing a 500 on the first collision.
create_retries_on_username_collision(Config) ->
    CollisionSuffix = asobi_id:rand_suffix(8),
    CollisionUsername = <<"guest_", CollisionSuffix/binary>>,
    ExistingCS = kura_changeset:validate_required(
        kura_changeset:cast(asobi_player, #{}, #{username => CollisionUsername}, [username]),
        [username]
    ),
    {ok, _} = asobi_repo:insert(ExistingCS),

    %% Mock the shared helper, not crypto:strong_rand_bytes/1 directly - the
    %% latter is process-wide and shared with unrelated 8-byte callers, which
    %% would make this test flaky against future code that also asks crypto
    %% for 8 random bytes.
    Counter = counters:new(1, []),
    meck:new(asobi_id, [passthrough]),
    meck:expect(asobi_id, rand_suffix, fun
        (8) ->
            case counters:get(Counter, 1) of
                0 ->
                    counters:add(Counter, 1, 1),
                    CollisionSuffix;
                _ ->
                    meck:passthrough([8])
            end;
        (N) ->
            meck:passthrough([N])
    end),
    try
        {ok, R} = create(device_id(), secret(), Config),
        ?assertStatus(200, R),
        #{~"player_id" := Pid, ~"username" := Username} = nova_test:json(R),
        ?assert(is_binary(Pid)),
        ?assertNotEqual(CollisionUsername, Username)
    after
        meck:unload(asobi_id)
    end,
    Config.

%% A `username` error that is NOT a uniqueness conflict (e.g. a future
%% format/length validation) must 500 immediately rather than burn all 3
%% retry attempts on a failure retrying can never fix.
create_no_retry_on_non_unique_username_error(Config) ->
    meck:new(asobi_repo, [passthrough]),
    meck:expect(asobi_repo, insert, fun
        (#kura_changeset{schema = asobi_player} = CS) ->
            {error, kura_changeset:add_error(CS, username, ~"is reserved")};
        (CS) ->
            meck:passthrough([CS])
    end),
    try
        {ok, R} = create(device_id(), secret(), Config),
        ?assertStatus(500, R),
        ?assertEqual(1, meck:num_calls(asobi_repo, insert, '_'))
    after
        meck:unload(asobi_repo)
    end,
    Config.
