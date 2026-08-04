-module(asobi_oauth_SUITE).

-include_lib("nova_test/include/nova_test.hrl").
-include_lib("kura/include/kura.hrl").

-export([all/0, groups/0, init_per_suite/1, end_per_suite/1, init_per_group/2, end_per_group/2]).
-export([
    oauth_missing_fields/1,
    oauth_unsupported_provider/1,
    link_missing_fields/1,
    link_unsupported_provider/1,
    unlink_missing_fields/1,
    unlink_not_found/1,
    unlink_last_auth_method/1,
    unlink_success/1,
    identity_db_roundtrip/1,
    login_existing_identity/1,
    create_player_retries_on_username_collision/1,
    create_player_no_retry_on_non_unique_username_error/1,
    create_player_deletes_orphan_on_identity_race_loss/1,
    create_player_identity_insert_real_failure_returns_500/1
]).

all() ->
    [{group, oauth_errors}, {group, link_unlink}, {group, identity_db}, {group, create_player}].

groups() ->
    [
        {oauth_errors, [], [
            oauth_missing_fields, oauth_unsupported_provider
        ]},
        {link_unlink, [sequence], [
            link_missing_fields,
            link_unsupported_provider,
            unlink_missing_fields,
            unlink_not_found,
            unlink_last_auth_method,
            unlink_success
        ]},
        {identity_db, [sequence], [
            identity_db_roundtrip, login_existing_identity
        ]},
        {create_player, [], [
            create_player_retries_on_username_collision,
            create_player_no_retry_on_non_unique_username_error,
            create_player_deletes_orphan_on_identity_race_loss,
            create_player_identity_insert_real_failure_returns_500
        ]}
    ].

init_per_suite(Config) ->
    Config0 = asobi_test_helpers:start(Config),
    U1 = asobi_test_helpers:unique_username(~"oauth_p1"),
    {ok, R1} = nova_test:post(
        "/api/v1/auth/register",
        #{json => #{~"username" => U1, ~"password" => ~"testpass123"}},
        Config0
    ),
    #{~"player_id" := P1Id, ~"access_token" := P1Token} = nova_test:json(R1),
    [
        {player1_id, P1Id},
        {player1_token, P1Token}
        | Config0
    ].

end_per_suite(Config) ->
    Config.

init_per_group(identity_db, Config) ->
    %% Clean up any leftover apple identities from previous runs
    {player1_id, PlayerId} = lists:keyfind(player1_id, 1, Config),
    true = is_binary(PlayerId),
    Query = kura_query:where(
        kura_query:where(kura_query:from(asobi_player_identity), {player_id, PlayerId}),
        {provider, ~"apple"}
    ),
    case asobi_repo:all(Query) of
        {ok, Existing} ->
            lists:foreach(
                fun(Ident) when is_map(Ident) -> asobi_repo:delete(asobi_player_identity, Ident)
                end,
                Existing
            );
        _ ->
            ok
    end,
    Config;
init_per_group(_Group, Config) ->
    Config.

end_per_group(_Group, Config) ->
    Config.

auth(Config) ->
    {player1_token, Token} = lists:keyfind(player1_token, 1, Config),
    true = is_binary(Token),
    [{~"authorization", <<"Bearer ", Token/binary>>}].

%% --- OAuth Error Paths ---

oauth_missing_fields(Config) ->
    {ok, Resp} = nova_test:post(
        "/api/v1/auth/oauth",
        #{json => #{}},
        Config
    ),
    ?assertStatus(400, Resp),
    Config.

oauth_unsupported_provider(Config) ->
    {ok, Resp} = nova_test:post(
        "/api/v1/auth/oauth",
        #{json => #{~"provider" => ~"fakeprovider", ~"token" => ~"faketoken"}},
        Config
    ),
    ?assertStatus(401, Resp),
    Config.

%% --- Link/Unlink Error Paths ---

link_missing_fields(Config) ->
    {ok, Resp} = nova_test:post(
        "/api/v1/auth/link",
        #{headers => auth(Config), json => #{}},
        Config
    ),
    ?assertStatus(400, Resp),
    Config.

link_unsupported_provider(Config) ->
    {ok, Resp} = nova_test:post(
        "/api/v1/auth/link",
        #{
            headers => auth(Config),
            json => #{~"provider" => ~"fakeprovider", ~"token" => ~"faketoken"}
        },
        Config
    ),
    ?assertStatus(401, Resp),
    Config.

unlink_missing_fields(Config) ->
    {ok, Resp} = nova_test:delete(
        "/api/v1/auth/unlink",
        #{headers => auth(Config), json => #{}},
        Config
    ),
    ?assertStatus(400, Resp),
    Config.

unlink_not_found(Config) ->
    {ok, Resp} = nova_test:delete(
        "/api/v1/auth/unlink?provider=discord",
        #{headers => auth(Config)},
        Config
    ),
    ?assertStatus(404, Resp),
    Config.

unlink_last_auth_method(Config) ->
    U = asobi_test_helpers:unique_username(~"oauth_nopw"),
    PlayerCS = kura_changeset:cast(
        asobi_player,
        #{},
        #{username => U, display_name => U},
        [username, display_name]
    ),
    {ok, Player} = asobi_repo:insert(PlayerCS),
    NoPasswordId = maps:get(id, Player),
    StatsCS = kura_changeset:cast(asobi_player_stats, #{}, #{player_id => NoPasswordId}, [player_id]),
    _ = asobi_repo:insert(StatsCS),
    IdentityCS = asobi_player_identity:changeset(#{}, #{
        player_id => NoPasswordId,
        provider => ~"google",
        provider_uid => iolist_to_binary([
            ~"google_", integer_to_binary(erlang:unique_integer([positive]))
        ]),
        provider_email => ~"test@example.com"
    }),
    {ok, _} = asobi_repo:insert(IdentityCS),
    Q = kura_query:where(kura_query:from(asobi_player_identity), {player_id, NoPasswordId}),
    {ok, [_]} = asobi_repo:all(Q),
    Config.

unlink_success(Config) ->
    {player1_id, PlayerId} = lists:keyfind(player1_id, 1, Config),
    true = is_binary(PlayerId),
    ProviderUid = iolist_to_binary([
        ~"discord_", integer_to_binary(erlang:unique_integer([positive]))
    ]),
    IdentityCS = asobi_player_identity:changeset(#{}, #{
        player_id => PlayerId,
        provider => ~"discord",
        provider_uid => ProviderUid,
        provider_email => ~"discord@example.com"
    }),
    {ok, Identity} = asobi_repo:insert(IdentityCS),
    {ok, _} = asobi_repo:delete(asobi_player_identity, Identity),
    Q = kura_query:where(
        kura_query:where(kura_query:from(asobi_player_identity), {player_id, PlayerId}),
        {provider, ~"discord"}
    ),
    {ok, []} = asobi_repo:all(Q),
    Config.

%% --- Identity DB Roundtrip ---

identity_db_roundtrip(Config) ->
    {player1_id, PlayerId} = lists:keyfind(player1_id, 1, Config),
    true = is_binary(PlayerId),
    ProviderUid = iolist_to_binary([
        ~"test_uid_", integer_to_binary(erlang:unique_integer([positive]))
    ]),
    CS = asobi_player_identity:changeset(#{}, #{
        player_id => PlayerId,
        provider => ~"apple",
        provider_uid => ProviderUid,
        provider_email => ~"apple@example.com",
        provider_display_name => ~"Apple User"
    }),
    {ok, Identity} = asobi_repo:insert(CS),
    ?assertEqual(PlayerId, maps:get(player_id, Identity)),
    ?assertEqual(~"apple", maps:get(provider, Identity)),
    ?assertEqual(ProviderUid, maps:get(provider_uid, Identity)),
    Q = kura_query:where(
        kura_query:where(kura_query:from(asobi_player_identity), {provider, ~"apple"}),
        {provider_uid, ProviderUid}
    ),
    {ok, [Found]} = asobi_repo:all(Q),
    ?assertEqual(maps:get(id, Identity), maps:get(id, Found)),
    Config.

login_existing_identity(Config) ->
    {player1_id, PlayerId} = lists:keyfind(player1_id, 1, Config),
    true = is_binary(PlayerId),
    Q = kura_query:where(
        kura_query:where(kura_query:from(asobi_player_identity), {player_id, PlayerId}),
        {provider, ~"apple"}
    ),
    {ok, [Identity]} = asobi_repo:all(Q),
    ?assertEqual(PlayerId, maps:get(player_id, Identity)),
    Config.

%% --- Username Collision Retry ---

%% A generated username colliding with an existing one (previously:
%% rand:uniform(9999) gave only ~13 bits of entropy, so two concurrent
%% first-sign-ins for the same provider_uid collided often) must retry with
%% a fresh one instead of surfacing a 500 on the first collision.
create_player_retries_on_username_collision(Config) ->
    ProviderUid = iolist_to_binary([
        ~"collide_uid_", integer_to_binary(erlang:unique_integer([positive]))
    ]),
    Short = binary:part(ProviderUid, 0, min(8, byte_size(ProviderUid))),
    CollisionRand = asobi_id:rand_suffix(4),
    CollisionUsername = <<"discord_", Short/binary, "_", CollisionRand/binary>>,
    ExistingCS = kura_changeset:validate_required(
        kura_changeset:cast(asobi_player, #{}, #{username => CollisionUsername}, [username]),
        [username]
    ),
    {ok, _} = asobi_repo:insert(ExistingCS),

    Counter = counters:new(1, []),
    meck:new(asobi_id, [passthrough]),
    meck:expect(asobi_id, rand_suffix, fun
        (4) ->
            case counters:get(Counter, 1) of
                0 ->
                    counters:add(Counter, 1, 1),
                    CollisionRand;
                _ ->
                    meck:passthrough([4])
            end;
        (N) ->
            meck:passthrough([N])
    end),
    try
        Claims = #{provider_uid => ProviderUid, provider_display_name => undefined},
        {json, 200, _, #{username := Username, created := true}} =
            asobi_oauth_controller:create_player_with_identity(~"discord", Claims),
        ?assertNotEqual(CollisionUsername, Username)
    after
        meck:unload(asobi_id)
    end,
    Config.

%% A `username` error that is NOT a uniqueness conflict (e.g. a future
%% format/length validation) must 500 immediately rather than burn all 3
%% retry attempts on a failure retrying can never fix.
create_player_no_retry_on_non_unique_username_error(Config) ->
    meck:new(asobi_repo, [passthrough]),
    meck:expect(asobi_repo, insert, fun
        (#kura_changeset{schema = asobi_player} = CS) ->
            {error, kura_changeset:add_error(CS, username, ~"is reserved")};
        (CS) ->
            meck:passthrough([CS])
    end),
    try
        Claims = #{provider_uid => ~"reserved_uid", provider_display_name => undefined},
        {asobi_error, ~"auth.registration_failed"} =
            asobi_oauth_controller:create_player_with_identity(~"discord", Claims),
        ?assertEqual(1, meck:num_calls(asobi_repo, insert, '_'))
    after
        meck:unload(asobi_repo)
    end,
    Config.

%% asobi#241: two concurrent first-sign-ins for the same provider_uid can
%% both insert a `players` row, but only one wins the identity insert
%% (unique {provider, provider_uid} index). The loser must NOT be issued
%% tokens for a player with no identity row - that player becomes an orphan
%% no later login can ever match against. Simulate the loss by forcing the
%% identity insert to fail inside the transaction; assert 409 and that the
%% DB rolled the just-created player back rather than leaving it behind.
%% The created id is captured independently of anything the code under test
%% returns, so this can't pass by tautology (asobi#241 security review, M3).
create_player_deletes_orphan_on_identity_race_loss(Config) ->
    Self = self(),
    meck:new(asobi_repo, [passthrough]),
    meck:expect(asobi_repo, insert, fun
        (#kura_changeset{schema = asobi_player_identity} = CS) ->
            {error, kura_changeset:add_error(CS, provider_uid, ~"has already been taken")};
        (#kura_changeset{schema = asobi_player} = CS) ->
            {ok, Player} = meck:passthrough([CS]),
            true = is_map(Player),
            Self ! {created, maps:get(id, Player)},
            {ok, Player};
        (CS) ->
            meck:passthrough([CS])
    end),
    try
        ProviderUid = iolist_to_binary([
            ~"race_uid_", integer_to_binary(erlang:unique_integer([positive]))
        ]),
        Claims = #{provider_uid => ProviderUid, provider_display_name => undefined},
        ?assertEqual(
            {asobi_error, ~"auth.already_registering"},
            asobi_oauth_controller:create_player_with_identity(~"discord", Claims)
        ),
        PlayerId =
            receive
                {created, Id} -> Id
            after 1000 -> erlang:error(player_not_created)
            end,
        ?assertEqual({error, not_found}, asobi_repo:get(asobi_player, PlayerId))
    after
        meck:unload(asobi_repo)
    end,
    Config.

%% asobi#241: an identity-insert failure that is NOT the provider_uid unique
%% race (e.g. a validation error on another field) must not be misreported as
%% already_registering - it logs and returns 500.
create_player_identity_insert_real_failure_returns_500(Config) ->
    meck:new(asobi_repo, [passthrough]),
    meck:expect(asobi_repo, insert, fun
        (#kura_changeset{schema = asobi_player_identity} = CS) ->
            {error, kura_changeset:add_error(CS, provider_email, ~"is invalid")};
        (CS) ->
            meck:passthrough([CS])
    end),
    try
        ProviderUid = iolist_to_binary([
            ~"real_failure_uid_", integer_to_binary(erlang:unique_integer([positive]))
        ]),
        Claims = #{
            provider_uid => ProviderUid,
            provider_display_name => undefined,
            provider_email => ~"not-an-email"
        },
        ?assertEqual(
            {asobi_error, ~"auth.registration_failed"},
            asobi_oauth_controller:create_player_with_identity(~"discord", Claims)
        )
    after
        meck:unload(asobi_repo)
    end,
    Config.
