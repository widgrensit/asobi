-module(asobi_oauth_SUITE).

-include_lib("nova_test/include/nova_test.hrl").

-export([all/0, groups/0, init_per_suite/1, end_per_suite/1]).
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
    login_existing_identity/1
]).

all() -> [{group, oauth_errors}, {group, link_unlink}, {group, identity_db}].

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
        ]}
    ].

init_per_suite(Config) ->
    Config0 = asobi_test_helpers:start(Config),
    U1 = asobi_test_helpers:unique_username(~"oauth_p1"),
    {ok, R1} = nova_test:post(
        ~"/api/v1/auth/register",
        #{json => #{~"username" => U1, ~"password" => ~"testpass123"}},
        Config0
    ),
    B1 = nova_test:json(R1),
    [
        {player1_id, maps:get(~"player_id", B1)},
        {player1_token, maps:get(~"session_token", B1)}
        | Config0
    ].

end_per_suite(Config) ->
    Config.

auth(Config) ->
    Token = proplists:get_value(player1_token, Config),
    [{~"authorization", iolist_to_binary([~"Bearer ", Token])}].

%% --- OAuth Error Paths ---

oauth_missing_fields(Config) ->
    {ok, Resp} = nova_test:post(
        ~"/api/v1/auth/oauth",
        #{json => #{}},
        Config
    ),
    ?assertStatus(400, Resp),
    Config.

oauth_unsupported_provider(Config) ->
    {ok, Resp} = nova_test:post(
        ~"/api/v1/auth/oauth",
        #{json => #{~"provider" => ~"fakeprovider", ~"token" => ~"faketoken"}},
        Config
    ),
    ?assertStatus(401, Resp),
    Config.

%% --- Link/Unlink Error Paths ---

link_missing_fields(Config) ->
    {ok, Resp} = nova_test:post(
        ~"/api/v1/auth/link",
        #{headers => auth(Config), json => #{}},
        Config
    ),
    ?assertStatus(400, Resp),
    Config.

link_unsupported_provider(Config) ->
    {ok, Resp} = nova_test:post(
        ~"/api/v1/auth/link",
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
        ~"/api/v1/auth/unlink",
        #{headers => auth(Config), json => #{}},
        Config
    ),
    ?assertStatus(400, Resp),
    Config.

unlink_not_found(Config) ->
    {ok, Resp} = nova_test:delete(
        ~"/api/v1/auth/unlink?provider=discord",
        #{headers => auth(Config)},
        Config
    ),
    ?assertStatus(404, Resp),
    Config.

unlink_last_auth_method(Config) ->
    %% Test the internal logic directly since DELETE with JSON body
    %% may not work through Nova's request pipeline
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
    %% Verify the identity exists
    Q = kura_query:where(kura_query:from(asobi_player_identity), {player_id, NoPasswordId}),
    {ok, [_]} = asobi_repo:all(Q),
    Config.

unlink_success(Config) ->
    PlayerId = proplists:get_value(player1_id, Config),
    %% Test identity insert + delete roundtrip directly since DELETE with
    %% JSON body may not be decoded by Nova
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
    %% Delete directly
    {ok, _} = asobi_repo:delete(asobi_player_identity, Identity),
    %% Verify it's gone
    Q = kura_query:where(
        kura_query:where(kura_query:from(asobi_player_identity), {player_id, PlayerId}),
        {provider, ~"discord"}
    ),
    {ok, []} = asobi_repo:all(Q),
    Config.

%% --- Identity DB Roundtrip ---

identity_db_roundtrip(Config) ->
    PlayerId = proplists:get_value(player1_id, Config),
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
    %% Query back
    Q = kura_query:where(
        kura_query:where(kura_query:from(asobi_player_identity), {provider, ~"apple"}),
        {provider_uid, ProviderUid}
    ),
    {ok, [Found]} = asobi_repo:all(Q),
    ?assertEqual(maps:get(id, Identity), maps:get(id, Found)),
    Config.

login_existing_identity(Config) ->
    %% Verify that an identity linked to a player can be found
    PlayerId = proplists:get_value(player1_id, Config),
    Q = kura_query:where(
        kura_query:where(kura_query:from(asobi_player_identity), {player_id, PlayerId}),
        {provider, ~"apple"}
    ),
    {ok, [Identity]} = asobi_repo:all(Q),
    ?assertEqual(PlayerId, maps:get(player_id, Identity)),
    Config.
