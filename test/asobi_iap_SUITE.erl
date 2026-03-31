-module(asobi_iap_SUITE).

-include_lib("nova_test/include/nova_test.hrl").

-export([all/0, groups/0, init_per_suite/1, end_per_suite/1]).
-export([
    apple_missing_fields/1,
    apple_not_configured/1,
    apple_invalid_jws/1,
    apple_valid_jws_wrong_bundle/1,
    google_missing_fields/1,
    google_not_configured/1
]).

all() -> [{group, apple_iap}, {group, google_iap}].

groups() ->
    [
        {apple_iap, [], [
            apple_missing_fields, apple_not_configured,
            apple_invalid_jws, apple_valid_jws_wrong_bundle
        ]},
        {google_iap, [], [
            google_missing_fields, google_not_configured
        ]}
    ].

init_per_suite(Config) ->
    Config0 = asobi_test_helpers:start(Config),
    U1 = asobi_test_helpers:unique_username(~"iap_p1"),
    {ok, R1} = nova_test:post(
        ~"/api/v1/auth/register",
        #{json => #{~"username" => U1, ~"password" => ~"testpass123"}},
        Config0
    ),
    B1 = nova_test:json(R1),
    [
        {player1_token, maps:get(~"session_token", B1)}
        | Config0
    ].

end_per_suite(Config) ->
    Config.

auth(Config) ->
    Token = proplists:get_value(player1_token, Config),
    [{~"authorization", iolist_to_binary([~"Bearer ", Token])}].

%% --- Apple IAP ---

apple_missing_fields(Config) ->
    {ok, Resp} = nova_test:post(
        ~"/api/v1/iap/apple",
        #{headers => auth(Config), json => #{}},
        Config
    ),
    ?assertStatus(400, Resp),
    Config.

apple_not_configured(Config) ->
    %% Ensure apple_bundle_id is not configured
    application:unset_env(asobi, apple_bundle_id),
    {ok, Resp} = nova_test:post(
        ~"/api/v1/iap/apple",
        #{
            headers => auth(Config),
            json => #{~"signed_transaction" => ~"fake.fake.fake"}
        },
        Config
    ),
    ?assertStatus(422, Resp),
    #{~"error" := ~"apple_iap_not_configured"} = nova_test:json(Resp),
    Config.

apple_invalid_jws(Config) ->
    %% Set a bundle ID so validation proceeds past the config check
    application:set_env(asobi, apple_bundle_id, ~"com.test.app"),
    {ok, Resp} = nova_test:post(
        ~"/api/v1/iap/apple",
        #{
            headers => auth(Config),
            json => #{~"signed_transaction" => ~"not-valid-jws"}
        },
        Config
    ),
    ?assertStatus(422, Resp),
    application:unset_env(asobi, apple_bundle_id),
    Config.

apple_valid_jws_wrong_bundle(Config) ->
    application:set_env(asobi, apple_bundle_id, ~"com.expected.app"),
    %% Create a valid JWS structure with wrong bundleId
    Payload = iolist_to_binary(json:encode(#{
        ~"bundleId" => ~"com.wrong.app",
        ~"productId" => ~"test_product",
        ~"transactionId" => ~"12345"
    })),
    PayloadB64 = base64:encode(Payload, #{mode => urlsafe, padding => false}),
    FakeJws = iolist_to_binary([~"eyJhbGciOiJSUzI1NiJ9.", PayloadB64, ~".fakesig"]),
    {ok, Resp} = nova_test:post(
        ~"/api/v1/iap/apple",
        #{
            headers => auth(Config),
            json => #{~"signed_transaction" => FakeJws}
        },
        Config
    ),
    ?assertStatus(422, Resp),
    #{~"error" := ~"bundle_id_mismatch"} = nova_test:json(Resp),
    application:unset_env(asobi, apple_bundle_id),
    Config.

%% --- Google IAP ---

google_missing_fields(Config) ->
    {ok, Resp} = nova_test:post(
        ~"/api/v1/iap/google",
        #{headers => auth(Config), json => #{}},
        Config
    ),
    ?assertStatus(422, Resp),
    Config.

google_not_configured(Config) ->
    application:unset_env(asobi, google_package_name),
    {ok, Resp} = nova_test:post(
        ~"/api/v1/iap/google",
        #{
            headers => auth(Config),
            json => #{~"product_id" => ~"test", ~"purchase_token" => ~"fake"}
        },
        Config
    ),
    ?assertStatus(422, Resp),
    #{~"error" := ~"google_iap_not_configured"} = nova_test:json(Resp),
    Config.
