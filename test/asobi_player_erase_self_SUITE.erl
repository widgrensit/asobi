-module(asobi_player_erase_self_SUITE).

%% POST /api/v1/players/me/erase - a player erases their own account (asobi#419).
%%
%% The route exists because Apple review guideline 5.1.1(v) and GDPR Art. 17
%% between them make in-app account deletion a shipping requirement, and until
%% now the only erasure paths were an operator retention key and an operator
%% secret. What is worth testing is not that a delete deletes: it is that the
%% route erases the caller and nobody else, that it cannot be driven by a
%% session alone once a password exists, and that it does leave a record.

-include_lib("nova_test/include/nova_test.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1, init_per_testcase/2]).
-export([
    a_guest_erases_itself/1,
    a_password_account_must_echo_its_password/1,
    a_wrong_password_erases_nothing/1,
    a_password_account_erases_itself_with_the_password/1,
    a_provider_only_account_erases_itself_on_its_session/1,
    erasing_writes_a_subject_audit_row/1,
    erase_needs_a_session/1,
    erase_takes_the_children_and_frees_the_device/1
]).

all() ->
    [
        a_guest_erases_itself,
        a_password_account_must_echo_its_password,
        a_wrong_password_erases_nothing,
        a_password_account_erases_itself_with_the_password,
        a_provider_only_account_erases_itself_on_its_session,
        erasing_writes_a_subject_audit_row,
        erase_needs_a_session,
        erase_takes_the_children_and_frees_the_device
    ].

%% Operator-layer guest auth, set before the start the way a sys.config would
%% have it (ADR 0014).
init_per_suite(Config0) ->
    application:set_env(asobi, guest_auth, true),
    application:set_env(asobi, guest_verifier_pepper, crypto:strong_rand_bytes(32)),
    asobi_test_helpers:start(Config0).

%% Nothing resets the operator layer any more, so the suite that set it clears
%% it - see `asobi_guest_SUITE:end_per_suite/1`.
end_per_suite(Config) ->
    application:unset_env(asobi, guest_auth),
    application:unset_env(asobi, guest_verifier_pepper),
    Config.

%% Erasure has its own tight bucket (3 per minute per IP, because the
%% wrong-password path runs the KDF), and every case here comes from the same
%% IP, so without this the suite throttles itself and the failure looks like a
%% product bug. Clearing the key rather than raising the limit keeps the limiter
%% under test as configured.
init_per_testcase(_Case, Config) ->
    %% Both loopback spellings: the bucket is keyed on the client IP, and which
    %% one the test client presents depends on how it resolved localhost.
    [ok = seki:reset(asobi_erase_limiter, Ip) || Ip <- [~"127.0.0.1", ~"::1"]],
    Config.

%% --- Helpers ---

secret() ->
    base64:encode(crypto:strong_rand_bytes(32)).

device_id() ->
    base64:encode(crypto:strong_rand_bytes(16)).

auth(Token) ->
    [{~"authorization", <<"Bearer ", Token/binary>>}].

guest(Config) ->
    {ok, R} = nova_test:post(
        "/api/v1/auth/guest",
        #{json => #{~"device_id" => device_id(), ~"device_secret" => secret()}},
        Config
    ),
    ?assertStatus(200, R),
    nova_test:json(R).

password_account(Config) ->
    Username = asobi_test_helpers:unique_username(~"erasable"),
    {ok, R} = nova_test:post(
        "/api/v1/auth/register",
        #{json => #{~"username" => Username, ~"password" => ~"secret1234"}},
        Config
    ),
    ?assertStatus(200, R),
    nova_test:json(R).

erase(Token, Body, Config) ->
    nova_test:post("/api/v1/players/me/erase", #{json => Body, headers => auth(Token)}, Config).

audit_rows(PlayerId) ->
    Q = kura_query:where(
        kura_query:where(kura_query:from(asobi_ops_audit_entry), {target_id, PlayerId}),
        {action, ~"players.erase"}
    ),
    asobi_repo:all(Q).

%% --- Tests ---

%% A guest has no credential the client can re-present - the device secret is
%% not something the SDK sends here - so the session is the whole confirmation.
a_guest_erases_itself(Config) ->
    #{~"player_id" := PlayerId, ~"access_token" := Token} = guest(Config),
    {ok, R} = erase(Token, #{}, Config),
    ?assertStatus(200, R),
    ?assertEqual(#{~"deleted" => true}, nova_test:json(R)),
    ?assertEqual({error, not_found}, asobi_repo:get(asobi_player, PlayerId)),
    Config.

%% Once a password exists, a session token alone is not enough: a stolen access
%% token must not be able to destroy the account it borrowed.
a_password_account_must_echo_its_password(Config) ->
    #{~"player_id" := PlayerId, ~"access_token" := Token} = password_account(Config),
    {ok, R} = erase(Token, #{}, Config),
    ?assertStatus(400, R),
    ?assertMatch(#{~"error" := #{~"code" := ~"missing_field"}}, nova_test:json(R)),
    ?assertMatch({ok, _}, asobi_repo:get(asobi_player, PlayerId)),
    Config.

%% 403, not 401. The caller is authenticated - they failed a step-up
%% confirmation - and every SDK reads a 401 as "refresh the pair and replay", so
%% a 401 here would burn a token rotation on each wrong password and replay a
%% destructive call. Pinned because the status is the part clients act on.
a_wrong_password_erases_nothing(Config) ->
    #{~"player_id" := PlayerId, ~"access_token" := Token} = password_account(Config),
    {ok, R} = erase(Token, #{~"password" => ~"not-the-password"}, Config),
    ?assertStatus(403, R),
    ?assertMatch(#{~"error" := #{~"code" := ~"player.confirmation_failed"}}, nova_test:json(R)),
    ?assertMatch({ok, _}, asobi_repo:get(asobi_player, PlayerId)),
    %% And the session is untouched: a refused confirmation must not cost the
    %% player the account they still have.
    {ok, R2} = erase(Token, #{~"password" => ~"secret1234"}, Config),
    ?assertStatus(200, R2),
    Config.

a_password_account_erases_itself_with_the_password(Config) ->
    #{~"player_id" := PlayerId, ~"access_token" := Token} = password_account(Config),
    {ok, R} = erase(Token, #{~"password" => ~"secret1234"}, Config),
    ?assertStatus(200, R),
    ?assertEqual({error, not_found}, asobi_repo:get(asobi_player, PlayerId)),
    %% The session died with the rows it authenticated against, so a retried
    %% call is a 401 rather than a second erasure. SDK authors need to read
    %% that as "it worked", not as "your session expired".
    {ok, R2} = erase(Token, #{~"password" => ~"secret1234"}, Config),
    ?assertStatus(401, R2),
    Config.

%% Passwordless but not a guest. There is no credential to echo here either -
%% the account signs in with a provider id token - so the session stands, the
%% same way it does for a guest. The point is that the branch is "has a
%% password", not "is a guest": an OAuth-only player must not be stranded.
a_provider_only_account_erases_itself_on_its_session(Config) ->
    Username = asobi_test_helpers:unique_username(~"oauthonly"),
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
    {ok, R} = erase(Token, #{}, Config),
    ?assertStatus(200, R),
    ?assertEqual({error, not_found}, asobi_repo:get(asobi_player, PlayerId)),
    ?assertEqual({ok, 0}, count(asobi_player_identity, player_id, PlayerId)),
    Config.

%% ADR 0007: the data is gone by definition, so the audit row is the only
%% surviving evidence the request was honoured. `subject` distinguishes it from
%% an operator erasing somebody else, and actor_id = target_id is the query for
%% "erasures nobody but the subject asked for".
erasing_writes_a_subject_audit_row(Config) ->
    #{~"player_id" := PlayerId, ~"access_token" := Token} = guest(Config),
    {ok, R} = erase(Token, #{}, Config),
    ?assertStatus(200, R),
    {ok, [Row]} = audit_rows(PlayerId),
    ?assertEqual(~"subject", maps:get(actor_source, Row)),
    ?assertEqual(PlayerId, maps:get(actor_id, Row)),
    ?assertEqual(PlayerId, maps:get(target_id, Row)),
    ?assertEqual(~"player", maps:get(target_type, Row)),
    Config.

erase_needs_a_session(Config) ->
    {ok, R} = nova_test:post("/api/v1/players/me/erase", #{json => #{}}, Config),
    ?assertStatus(401, R),
    Config.

%% The whole point of routing through asobi_player_erase rather than deleting
%% the player row: the children go too, and the device identity with them, so
%% the pair that created the account becomes a stranger rather than resuming
%% a player whose rows are half gone.
erase_takes_the_children_and_frees_the_device(Config) ->
    Dev = device_id(),
    Secret = secret(),
    {ok, R1} = nova_test:post(
        "/api/v1/auth/guest",
        #{json => #{~"device_id" => Dev, ~"device_secret" => Secret}},
        Config
    ),
    #{~"player_id" := PlayerId, ~"access_token" := Token} = nova_test:json(R1),
    {ok, _} = asobi_repo:insert(
        kura_changeset:cast(
            asobi_storage,
            #{},
            #{player_id => PlayerId, collection => ~"save", key => ~"slot1", value => #{}},
            [player_id, collection, key, value]
        )
    ),
    ?assertEqual({ok, 1}, count(asobi_storage, player_id, PlayerId)),

    {ok, R2} = erase(Token, #{}, Config),
    ?assertStatus(200, R2),
    ?assertEqual({ok, 0}, count(asobi_storage, player_id, PlayerId)),
    ?assertEqual({ok, 0}, count(asobi_player_identity, player_id, PlayerId)),
    ?assertEqual({ok, 0}, count(asobi_player_stats, player_id, PlayerId)),

    {ok, R3} = nova_test:post(
        "/api/v1/auth/guest",
        #{json => #{~"device_id" => Dev, ~"device_secret" => Secret}},
        Config
    ),
    ?assertStatus(200, R3),
    #{~"player_id" := NewPlayerId} = nova_test:json(R3),
    ?assertNotEqual(PlayerId, NewPlayerId),
    Config.

count(Schema, Field, Value) ->
    asobi_repo:aggregate(kura_query:where(kura_query:from(Schema), {Field, Value}), count).
