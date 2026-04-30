-module(asobi_iap_SUITE).

-include_lib("nova_test/include/nova_test.hrl").
-include_lib("public_key/include/public_key.hrl").
-include_lib("common_test/include/ct.hrl").

-export([all/0, groups/0, init_per_suite/1, end_per_suite/1]).
-export([
    apple_missing_fields/1,
    apple_not_configured/1,
    apple_root_not_configured/1,
    apple_invalid_jws/1,
    apple_unsupported_alg/1,
    apple_missing_x5c/1,
    apple_signature_invalid/1,
    apple_chain_validation_failed/1,
    apple_valid_jws_wrong_bundle/1,
    apple_valid_jws_correct_bundle/1,
    google_missing_fields/1,
    google_not_configured/1
]).

all() -> [{group, apple_iap}, {group, google_iap}].

groups() ->
    [
        {apple_iap, [], [
            apple_missing_fields,
            apple_not_configured,
            apple_root_not_configured,
            apple_invalid_jws,
            apple_unsupported_alg,
            apple_missing_x5c,
            apple_signature_invalid,
            apple_chain_validation_failed,
            apple_valid_jws_wrong_bundle,
            apple_valid_jws_correct_bundle
        ]},
        {google_iap, [], [
            google_missing_fields, google_not_configured
        ]}
    ].

init_per_suite(Config) ->
    Config0 = asobi_test_helpers:start(Config),
    U1 = asobi_test_helpers:unique_username(~"iap_p1"),
    {ok, R1} = nova_test:post(
        "/api/v1/auth/register",
        #{json => #{~"username" => U1, ~"password" => ~"testpass123"}},
        Config0
    ),
    #{~"session_token" := P1Token} = nova_test:json(R1),
    Chain = build_test_chain(),
    [
        {player1_token, P1Token},
        {test_chain, Chain}
        | Config0
    ].

end_per_suite(Config) ->
    Config.

%% --- Apple IAP ---

apple_missing_fields(Config) ->
    {ok, Resp} = nova_test:post(
        "/api/v1/iap/apple",
        #{headers => auth(Config), json => #{}},
        Config
    ),
    ?assertStatus(400, Resp),
    Config.

apple_not_configured(Config) ->
    application:unset_env(asobi, apple_bundle_id),
    {ok, Resp} = nova_test:post(
        "/api/v1/iap/apple",
        #{
            headers => auth(Config),
            json => #{~"signed_transaction" => ~"fake.fake.fake"}
        },
        Config
    ),
    ?assertStatus(422, Resp),
    Config.

apple_root_not_configured(Config) ->
    application:set_env(asobi, apple_bundle_id, ~"com.test.app"),
    application:unset_env(asobi, apple_root_certs),
    application:unset_env(asobi, apple_root_cert_path),
    {ok, Resp} = nova_test:post(
        "/api/v1/iap/apple",
        #{
            headers => auth(Config),
            json => #{~"signed_transaction" => ~"fake.fake.fake"}
        },
        Config
    ),
    ?assertStatus(422, Resp),
    #{~"error" := ~"apple_root_cert_not_configured"} = nova_test:json(Resp),
    cleanup_apple_env(),
    Config.

apple_invalid_jws(Config) ->
    configure_apple(Config, ~"com.test.app"),
    {ok, Resp} = nova_test:post(
        "/api/v1/iap/apple",
        #{
            headers => auth(Config),
            json => #{~"signed_transaction" => ~"not-valid-jws"}
        },
        Config
    ),
    ?assertStatus(422, Resp),
    cleanup_apple_env(),
    Config.

apple_unsupported_alg(Config) ->
    configure_apple(Config, ~"com.test.app"),
    Chain = ?config(test_chain, Config),
    %% Build a JWS with alg=HS256 — must be rejected even if everything
    %% else looks plausible.
    Jws = build_jws(Chain, #{~"alg" => ~"HS256"}, #{~"bundleId" => ~"com.test.app"}),
    {ok, Resp} = nova_test:post(
        "/api/v1/iap/apple",
        #{
            headers => auth(Config),
            json => #{~"signed_transaction" => Jws}
        },
        Config
    ),
    ?assertStatus(422, Resp),
    #{~"error" := ~"unsupported_alg"} = nova_test:json(Resp),
    cleanup_apple_env(),
    Config.

apple_missing_x5c(Config) ->
    configure_apple(Config, ~"com.test.app"),
    Chain = ?config(test_chain, Config),
    %% alg=ES256 but no x5c header.
    Jws = build_jws(Chain, #{~"alg" => ~"ES256"}, #{~"bundleId" => ~"com.test.app"}),
    {ok, Resp} = nova_test:post(
        "/api/v1/iap/apple",
        #{
            headers => auth(Config),
            json => #{~"signed_transaction" => Jws}
        },
        Config
    ),
    ?assertStatus(422, Resp),
    #{~"error" := ~"invalid_x5c"} = nova_test:json(Resp),
    cleanup_apple_env(),
    Config.

apple_signature_invalid(Config) ->
    configure_apple(Config, ~"com.test.app"),
    Chain = ?config(test_chain, Config),
    %% Build the payload and sign it, then swap the signature for one
    %% over a *different* payload — verification should fail because the
    %% signature no longer matches header.payload.
    Good = build_signed_jws(Chain, #{~"bundleId" => ~"com.test.app"}),
    Other = build_signed_jws(Chain, #{~"bundleId" => ~"com.test.app", ~"nonce" => ~"x"}),
    Bad = swap_signature(Good, Other),
    {ok, Resp} = nova_test:post(
        "/api/v1/iap/apple",
        #{
            headers => auth(Config),
            json => #{~"signed_transaction" => Bad}
        },
        Config
    ),
    ?assertStatus(422, Resp),
    #{~"error" := ~"signature_invalid"} = nova_test:json(Resp),
    cleanup_apple_env(),
    Config.

apple_chain_validation_failed(Config) ->
    application:set_env(asobi, apple_bundle_id, ~"com.test.app"),
    %% Configure a *different* root cert as the trust anchor — chain
    %% should fail to validate even though the JWS is internally consistent.
    Other = build_test_chain(),
    application:set_env(asobi, apple_root_certs, [maps:get(root_der, Other)]),
    Chain = ?config(test_chain, Config),
    Jws = build_signed_jws(Chain, #{~"bundleId" => ~"com.test.app"}),
    {ok, Resp} = nova_test:post(
        "/api/v1/iap/apple",
        #{
            headers => auth(Config),
            json => #{~"signed_transaction" => Jws}
        },
        Config
    ),
    ?assertStatus(422, Resp),
    #{~"error" := ~"chain_validation_failed"} = nova_test:json(Resp),
    cleanup_apple_env(),
    Config.

apple_valid_jws_wrong_bundle(Config) ->
    configure_apple(Config, ~"com.expected.app"),
    Chain = ?config(test_chain, Config),
    %% Signs successfully but bundleId mismatches the configured one.
    Jws = build_signed_jws(Chain, #{~"bundleId" => ~"com.wrong.app"}),
    {ok, Resp} = nova_test:post(
        "/api/v1/iap/apple",
        #{
            headers => auth(Config),
            json => #{~"signed_transaction" => Jws}
        },
        Config
    ),
    ?assertStatus(422, Resp),
    #{~"error" := ~"bundle_id_mismatch"} = nova_test:json(Resp),
    cleanup_apple_env(),
    Config.

apple_valid_jws_correct_bundle(Config) ->
    configure_apple(Config, ~"com.test.app"),
    Chain = ?config(test_chain, Config),
    Jws = build_signed_jws(Chain, #{
        ~"bundleId" => ~"com.test.app",
        ~"productId" => ~"premium_pack",
        ~"transactionId" => ~"txn-1",
        ~"quantity" => 1,
        ~"type" => ~"Consumable"
    }),
    {ok, Resp} = nova_test:post(
        "/api/v1/iap/apple",
        #{
            headers => auth(Config),
            json => #{~"signed_transaction" => Jws}
        },
        Config
    ),
    ?assertStatus(200, Resp),
    Body = nova_test:json(Resp),
    ?assertMatch(#{~"product_id" := ~"premium_pack", ~"valid" := true}, Body),
    cleanup_apple_env(),
    Config.

%% --- Google IAP ---

google_missing_fields(Config) ->
    {ok, Resp} = nova_test:post(
        "/api/v1/iap/google",
        #{headers => auth(Config), json => #{}},
        Config
    ),
    ?assertStatus(422, Resp),
    Config.

google_not_configured(Config) ->
    application:unset_env(asobi, google_package_name),
    {ok, Resp} = nova_test:post(
        "/api/v1/iap/google",
        #{
            headers => auth(Config),
            json => #{~"product_id" => ~"test", ~"purchase_token" => ~"fake"}
        },
        Config
    ),
    ?assertStatus(422, Resp),
    #{~"error" := ~"google_iap_not_configured"} = nova_test:json(Resp),
    Config.

%% --- Helpers ---

auth(Config) ->
    {player1_token, Token} = lists:keyfind(player1_token, 1, Config),
    true = is_binary(Token),
    [{~"authorization", <<"Bearer ", Token/binary>>}].

configure_apple(Config, Bundle) ->
    application:set_env(asobi, apple_bundle_id, Bundle),
    Chain = ?config(test_chain, Config),
    application:set_env(asobi, apple_root_certs, [maps:get(root_der, Chain)]).

cleanup_apple_env() ->
    application:unset_env(asobi, apple_bundle_id),
    application:unset_env(asobi, apple_root_certs),
    application:unset_env(asobi, apple_root_cert_path).

-spec build_test_chain() -> map().
build_test_chain() ->
    Opts = #{
        root => [{key, {namedCurve, secp256r1}}],
        intermediates => [[{key, {namedCurve, secp256r1}}]],
        peer => [{key, {namedCurve, secp256r1}}]
    },
    TD = pkix_test_data(Opts),
    KeyDer = key_der(proplists:get_value(key, TD)),
    LeafKey = public_key:der_decode('ECPrivateKey', KeyDer),
    LeafDer = as_binary(proplists:get_value(cert, TD)),
    [RootDer, IntermediateDer | _] = as_list(proplists:get_value(cacerts, TD)),
    #{
        leaf_der => LeafDer,
        leaf_key => LeafKey,
        intermediate_der => IntermediateDer,
        root_der => RootDer
    }.

%% pkix_test_data's spec is too narrow for our (valid) input; cast through
%% dynamic() so eqwalizer accepts the runtime-correct proplist shape.
-spec pkix_test_data(dynamic()) -> dynamic().
pkix_test_data(Opts) ->
    public_key:pkix_test_data(Opts).

-spec key_der(dynamic()) -> binary().
key_der({'ECPrivateKey', Der}) when is_binary(Der) -> Der.

-spec as_binary(dynamic()) -> binary().
as_binary(B) when is_binary(B) -> B.

-spec as_list(dynamic()) -> [binary()].
as_list(L) when is_list(L) -> L.

%% Build a JWS with explicit header (e.g. wrong alg / no x5c) and
%% signed payload. Signature is computed over header.payload using the
%% test chain's leaf private key — so the JWS is byte-perfect except
%% for whatever header field the caller wants to break.
build_jws(Chain, Header, Payload) ->
    HeaderB64 = b64url(json:encode(Header)),
    PayloadB64 = b64url(json:encode(Payload)),
    SignInput = <<HeaderB64/binary, ".", PayloadB64/binary>>,
    LeafKey = maps:get(leaf_key, Chain),
    DerSig = public_key:sign(SignInput, sha256, LeafKey),
    RawSig = der_to_raw_ecdsa(DerSig),
    SigB64 = b64url(RawSig),
    <<HeaderB64/binary, ".", PayloadB64/binary, ".", SigB64/binary>>.

%% Standard happy-path JWS (alg=ES256, x5c=[leaf, int, root]).
build_signed_jws(Chain, Payload) ->
    LeafB64 = base64:encode(maps:get(leaf_der, Chain), #{padding => true}),
    IntB64 = base64:encode(maps:get(intermediate_der, Chain), #{padding => true}),
    RootB64 = base64:encode(maps:get(root_der, Chain), #{padding => true}),
    Header = #{
        ~"alg" => ~"ES256",
        ~"x5c" => [LeafB64, IntB64, RootB64]
    },
    build_jws(Chain, Header, Payload).

%% Replace a JWS's signature with one signed over a *different*
%% header.payload. Both inputs were produced by `build_signed_jws/2`,
%% so the result is well-formed but its signature won't verify against
%% the new payload.
swap_signature(Target, Donor) ->
    [TargetHeader, TargetPayload, _TargetSig] = binary:split(Target, ~".", [global]),
    [_DonorHeader, _DonorPayload, DonorSig] = binary:split(Donor, ~".", [global]),
    <<TargetHeader/binary, ".", TargetPayload/binary, ".", DonorSig/binary>>.

b64url(IoData) when is_list(IoData); is_binary(IoData) ->
    base64:encode(iolist_to_binary(IoData), #{mode => urlsafe, padding => false}).

-spec der_to_raw_ecdsa(binary()) -> binary().
der_to_raw_ecdsa(Der) ->
    {'ECDSA-Sig-Value', R, S} = public_key:der_decode('ECDSA-Sig-Value', Der),
    Rb = pad_left(binary:encode_unsigned(as_int(R)), 32),
    Sb = pad_left(binary:encode_unsigned(as_int(S)), 32),
    <<Rb/binary, Sb/binary>>.

-spec as_int(dynamic()) -> non_neg_integer().
as_int(I) when is_integer(I), I >= 0 -> I.

pad_left(Bin, Size) when byte_size(Bin) =:= Size -> Bin;
pad_left(Bin, Size) when byte_size(Bin) < Size ->
    Pad = binary:copy(<<0>>, Size - byte_size(Bin)),
    <<Pad/binary, Bin/binary>>;
pad_left(Bin, Size) when byte_size(Bin) > Size ->
    %% Trim leading zeros (decode_unsigned strips them, encode_unsigned
    %% can sometimes produce one extra byte for top-bit-set values).
    Excess = byte_size(Bin) - Size,
    binary:part(Bin, Excess, Size).
