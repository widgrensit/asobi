-module(asobi_iap).

-include_lib("public_key/include/public_key.hrl").

-export([verify_apple/1, verify_google/1]).

%% StoreKit 2 always signs JWS with ES256 (ECDSA over P-256, SHA-256).
%% We refuse any other algorithm — `none`/HS256/RS256 etc. are out.
-define(APPLE_REQUIRED_ALG, ~"ES256").

%% Apple App Store Server API v2
%% Validates a signed transaction (JWS) from StoreKit 2: verifies the JWS
%% signature against the leaf certificate from the `x5c` header, validates
%% the certificate chain against the configured Apple root, then checks
%% the bundle id and expiry. Refuses to run when not configured —
%% callers see `{error, apple_iap_not_configured | apple_root_cert_*}`.
-spec verify_apple(binary()) -> {ok, map()} | {error, binary()}.
verify_apple(SignedTransaction) when is_binary(SignedTransaction) ->
    case apple_bundle_id() of
        undefined ->
            {error, ~"apple_iap_not_configured"};
        BundleId ->
            case apple_root_certs() of
                {ok, RootCerts} ->
                    do_verify_apple(SignedTransaction, BundleId, RootCerts);
                {error, _} = Err ->
                    Err
            end
    end;
verify_apple(_) ->
    {error, ~"invalid_jws"}.

%% Google Play Developer API
%% Validates a purchase using the purchase token from Google Play Billing.
%% Body: {"product_id": "...", "purchase_token": "..."}
-spec verify_google(map()) -> {ok, map()} | {error, binary()}.
verify_google(#{~"product_id" := ProductId, ~"purchase_token" := PurchaseToken}) ->
    case google_package_name() of
        undefined ->
            {error, ~"google_iap_not_configured"};
        PackageName ->
            do_verify_google(PackageName, ProductId, PurchaseToken)
    end;
verify_google(_) ->
    {error, ~"missing_required_fields"}.

%% --- Apple Internal ---

-spec do_verify_apple(binary(), binary(), [dynamic()]) -> {ok, map()} | {error, binary()}.
do_verify_apple(JWS, ExpectedBundleId, RootCerts) ->
    case parse_and_verify_jws(JWS, RootCerts) of
        {ok, Payload} ->
            check_apple_payload(Payload, ExpectedBundleId);
        {error, _} = Err ->
            Err
    end.

-spec check_apple_payload(map(), binary()) -> {ok, map()} | {error, binary()}.
check_apple_payload(Payload, ExpectedBundleId) ->
    BundleId = maps:get(~"bundleId", Payload, undefined),
    ExpiresMs = maps:get(~"expiresDate", Payload, undefined),
    case BundleId of
        ExpectedBundleId ->
            Result = #{
                product_id => maps:get(~"productId", Payload, undefined),
                transaction_id => maps:get(~"transactionId", Payload, undefined),
                original_transaction_id =>
                    maps:get(~"originalTransactionId", Payload, undefined),
                purchase_date => maps:get(~"purchaseDate", Payload, undefined),
                expires_date => ExpiresMs,
                quantity => maps:get(~"quantity", Payload, 1),
                type => maps:get(~"type", Payload, ~"unknown"),
                valid => not is_expired(ExpiresMs)
            },
            {ok, Result};
        _ ->
            {error, ~"bundle_id_mismatch"}
    end.

%% Parse + verify the JWS in one shot; never returns the payload until
%% header alg, certificate chain, and signature have all been validated.
-spec parse_and_verify_jws(binary(), [dynamic()]) -> {ok, map()} | {error, binary()}.
parse_and_verify_jws(JWS, RootCerts) ->
    case binary:split(JWS, ~".", [global]) of
        [HeaderB64, PayloadB64, SigB64] ->
            try
                Header = decode_b64_json(HeaderB64),
                ok = require_alg(Header),
                {LeafCert, ValidationChain} = require_x5c(Header),
                ok = verify_chain(ValidationChain, RootCerts),
                ok = verify_signature(HeaderB64, PayloadB64, SigB64, LeafCert),
                Payload = decode_b64_json(PayloadB64),
                {ok, Payload}
            catch
                throw:Reason when is_binary(Reason) ->
                    {error, Reason};
                _:_ ->
                    {error, ~"invalid_jws"}
            end;
        _ ->
            {error, ~"invalid_jws_format"}
    end.

-spec decode_b64_json(binary()) -> map().
decode_b64_json(B64) ->
    Decoded = base64:decode(B64, #{mode => urlsafe, padding => false}),
    case json:decode(Decoded) of
        M when is_map(M) -> M;
        _ -> throw(~"invalid_jws")
    end.

-spec require_alg(map()) -> ok.
require_alg(#{~"alg" := ?APPLE_REQUIRED_ALG}) -> ok;
require_alg(_) -> throw(~"unsupported_alg").

%% Apple JWS x5c is always [leaf, intermediate, root] in DER-base64. We
%% decode the leaf and intermediate, drop the embedded root (we trust our
%% own configured root), and return the leaf + the validation-order chain
%% (`[Intermediate, Leaf]`).
-spec require_x5c(map()) -> {dynamic(), [dynamic()]}.
require_x5c(#{~"x5c" := [LeafB64, IntB64, RootB64]}) when
    is_binary(LeafB64), is_binary(IntB64), is_binary(RootB64)
->
    Leaf = decode_x5c_cert(LeafB64),
    Intermediate = decode_x5c_cert(IntB64),
    %% RootB64 is intentionally not used: we never trust the chain's
    %% own embedded root, only the operator-configured one.
    _ = decode_x5c_cert(RootB64),
    {Leaf, [Intermediate, Leaf]};
require_x5c(_) ->
    throw(~"invalid_x5c").

-spec decode_x5c_cert(binary()) -> dynamic().
decode_x5c_cert(B64) ->
    Der = base64:decode(B64, #{mode => standard, padding => true}),
    public_key:pkix_decode_cert(Der, otp).

-spec verify_chain([dynamic()], [dynamic()]) -> ok.
verify_chain(Chain, RootCerts) ->
    case try_roots(RootCerts, Chain) of
        ok -> ok;
        error -> throw(~"chain_validation_failed")
    end.

-spec try_roots([dynamic()], [dynamic()]) -> ok | error.
try_roots([], _Chain) ->
    error;
try_roots([Root | Rest], Chain) ->
    case public_key:pkix_path_validation(Root, Chain, []) of
        {ok, _} -> ok;
        {error, _} -> try_roots(Rest, Chain)
    end.

-spec verify_signature(binary(), binary(), binary(), dynamic()) -> ok.
verify_signature(HeaderB64, PayloadB64, SigB64, LeafCert) ->
    SignInput = <<HeaderB64/binary, ".", PayloadB64/binary>>,
    RawSig = base64:decode(SigB64, #{mode => urlsafe, padding => false}),
    DerSig = ecdsa_raw_to_der(RawSig),
    PubKeyInfo = pubkey_from_cert(LeafCert),
    case public_key:verify(SignInput, sha256, DerSig, PubKeyInfo) of
        true -> ok;
        false -> throw(~"signature_invalid")
    end.

%% JWS ES256 signatures are 64-byte raw `r || s`. `public_key:verify/4`
%% wants DER-encoded `Ecdsa-Sig-Value SEQUENCE { r INTEGER, s INTEGER }`.
-spec ecdsa_raw_to_der(binary()) -> binary().
ecdsa_raw_to_der(<<R:32/binary, S:32/binary>>) ->
    Rint = binary:decode_unsigned(R),
    Sint = binary:decode_unsigned(S),
    public_key:der_encode('ECDSA-Sig-Value', {'ECDSA-Sig-Value', Rint, Sint});
ecdsa_raw_to_der(_) ->
    throw(~"signature_invalid").

-spec pubkey_from_cert(dynamic()) -> dynamic().
pubkey_from_cert(#'OTPCertificate'{tbsCertificate = TBS}) ->
    SPKI = TBS#'OTPTBSCertificate'.subjectPublicKeyInfo,
    Algorithm = SPKI#'OTPSubjectPublicKeyInfo'.algorithm,
    PubKey = SPKI#'OTPSubjectPublicKeyInfo'.subjectPublicKey,
    Params = Algorithm#'PublicKeyAlgorithm'.parameters,
    {PubKey, Params}.

-spec apple_root_certs() -> {ok, [dynamic()]} | {error, binary()}.
apple_root_certs() ->
    case application:get_env(asobi, apple_root_certs) of
        {ok, Certs} when is_list(Certs), Certs =/= [] ->
            normalise_root_certs(Certs);
        _ ->
            case application:get_env(asobi, apple_root_cert_path) of
                {ok, Path} when is_binary(Path) ->
                    load_root_cert_file(Path);
                {ok, Path} when is_list(Path) ->
                    load_root_cert_file(coerce_path(Path));
                _ ->
                    {error, ~"apple_root_cert_not_configured"}
            end
    end.

-spec normalise_root_certs([term()]) -> {ok, [dynamic()]} | {error, binary()}.
normalise_root_certs(Certs) ->
    try
        {ok, [normalise_root_cert(C) || C <- Certs]}
    catch
        _:_ -> {error, ~"apple_root_cert_invalid"}
    end.

-spec normalise_root_cert(term()) -> dynamic().
normalise_root_cert(#'OTPCertificate'{} = C) ->
    C;
normalise_root_cert(Bin) when is_binary(Bin) ->
    case decode_root_pem_or_der(Bin) of
        {ok, Cert} -> Cert;
        error -> erlang:error(apple_root_cert_invalid)
    end.

-spec coerce_path(dynamic()) -> binary().
coerce_path(L) ->
    iolist_to_binary(L).

-spec load_root_cert_file(binary()) -> {ok, [dynamic()]} | {error, binary()}.
load_root_cert_file(Path) ->
    case file:read_file(Path) of
        {ok, Bin} ->
            case decode_root_pem_or_der(Bin) of
                {ok, Cert} -> {ok, [Cert]};
                error -> {error, ~"apple_root_cert_invalid"}
            end;
        {error, _} ->
            {error, ~"apple_root_cert_not_found"}
    end.

-spec decode_root_pem_or_der(binary()) -> {ok, dynamic()} | error.
decode_root_pem_or_der(Bin) ->
    case public_key:pem_decode(Bin) of
        [{'Certificate', Der, _} | _] ->
            try
                {ok, public_key:pkix_decode_cert(Der, otp)}
            catch
                _:_ -> error
            end;
        _ ->
            try
                {ok, public_key:pkix_decode_cert(Bin, otp)}
            catch
                _:_ -> error
            end
    end.

%% --- Google Internal ---

-spec do_verify_google(binary(), binary(), binary()) -> {ok, map()} | {error, binary()}.
do_verify_google(PackageName, ProductId, PurchaseToken) ->
    case google_access_token() of
        {ok, AccessToken} ->
            Url = iolist_to_binary([
                ~"https://androidpublisher.googleapis.com/androidpublisher/v3/applications/",
                PackageName,
                ~"/purchases/products/",
                ProductId,
                ~"/tokens/",
                PurchaseToken
            ]),
            Headers = [{"Authorization", binary_to_list(<<"Bearer ", AccessToken/binary>>)}],
            case
                httpc:request(
                    get,
                    {binary_to_list(Url), Headers},
                    [{timeout, 10000}],
                    [{body_format, binary}]
                )
            of
                {ok, {{_, 200, _}, _, Body}} when is_binary(Body) ->
                    parse_google_purchase(Body);
                {ok, {{_, 404, _}, _, _}} ->
                    {error, ~"purchase_not_found"};
                {ok, {{_, Status, _}, _, _}} ->
                    logger:warning(#{msg => ~"google_iap_api_error", status => Status}),
                    {error, ~"google_api_error"};
                {error, Reason} ->
                    logger:warning(#{msg => ~"google_iap_request_failed", reason => Reason}),
                    {error, ~"google_api_unavailable"}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

-spec parse_google_purchase(binary()) -> {ok, map()} | {error, binary()}.
parse_google_purchase(Body) ->
    case json:decode(Body) of
        #{~"purchaseState" := 0} = Purchase ->
            {ok, #{
                product_id => maps:get(~"productId", Purchase, undefined),
                order_id => maps:get(~"orderId", Purchase, undefined),
                purchase_time => maps:get(~"purchaseTimeMillis", Purchase, undefined),
                consumption_state => maps:get(~"consumptionState", Purchase, undefined),
                acknowledged => maps:get(~"acknowledgementState", Purchase, 0) =:= 1,
                valid => true
            }};
        #{~"purchaseState" := State} ->
            StateDesc =
                case State of
                    1 -> ~"cancelled";
                    2 -> ~"pending";
                    _ -> ~"unknown"
                end,
            {error, <<"purchase_", StateDesc/binary>>};
        _ ->
            {error, ~"invalid_google_response"}
    end.

%% --- Google OAuth2 ---

%% Get a Google access token via service account credentials (JWT grant).
%% Expects a service account JSON key file path in config.
-spec google_access_token() -> {ok, binary()} | {error, binary()}.
google_access_token() ->
    case application:get_env(asobi, google_service_account_key) of
        {ok, KeyPath} when is_binary(KeyPath) ->
            fetch_google_token(KeyPath);
        undefined ->
            {error, ~"google_iap_not_configured"}
    end.

-spec fetch_google_token(binary()) -> {ok, binary()} | {error, binary()}.
fetch_google_token(KeyPath) ->
    case file:read_file(KeyPath) of
        {ok, KeyJson} ->
            KeyData =
                case json:decode(KeyJson) of
                    M when is_map(M) -> M;
                    _ -> #{}
                end,
            ClientEmail = maps:get(~"client_email", KeyData),
            PrivateKey =
                case maps:get(~"private_key", KeyData) of
                    PK when is_binary(PK) -> PK;
                    _ -> <<>>
                end,
            Now = erlang:system_time(second),
            Claims = #{
                ~"iss" => ClientEmail,
                ~"scope" => ~"https://www.googleapis.com/auth/androidpublisher",
                ~"aud" => ~"https://oauth2.googleapis.com/token",
                ~"iat" => Now,
                ~"exp" => Now + 3600
            },
            Jwt = sign_jwt(Claims, PrivateKey),
            exchange_jwt_for_token(Jwt);
        {error, _} ->
            {error, ~"service_account_key_not_found"}
    end.

-spec sign_jwt(map(), binary()) -> binary().
sign_jwt(Claims, PrivateKeyPem) ->
    Header = #{~"alg" => ~"RS256", ~"typ" => ~"JWT"},
    HeaderB64 = base64:encode(iolist_to_binary(json:encode(Header)), #{
        mode => urlsafe, padding => false
    }),
    ClaimsB64 = base64:encode(iolist_to_binary(json:encode(Claims)), #{
        mode => urlsafe, padding => false
    }),
    SignInput = <<HeaderB64/binary, ".", ClaimsB64/binary>>,
    [Entry] = public_key:pem_decode(PrivateKeyPem),
    Key = public_key:pem_entry_decode(Entry),
    Signature = sign_rsa(SignInput, Key),
    SigB64 = base64:encode(Signature, #{mode => urlsafe, padding => false}),
    <<SignInput/binary, ".", SigB64/binary>>.

-spec exchange_jwt_for_token(binary()) -> {ok, binary()} | {error, binary()}.
exchange_jwt_for_token(Jwt) ->
    Url = "https://oauth2.googleapis.com/token",
    Body = iolist_to_binary([
        ~"grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer",
        ~"&assertion=",
        Jwt
    ]),
    ContentType = "application/x-www-form-urlencoded",
    case
        httpc:request(
            post,
            {Url, [], ContentType, Body},
            [{timeout, 10000}],
            [{body_format, binary}]
        )
    of
        {ok, {{_, 200, _}, _, RespBody}} when is_binary(RespBody) ->
            case json:decode(RespBody) of
                #{~"access_token" := Token} when is_binary(Token) -> {ok, Token};
                _ -> {error, ~"google_token_exchange_failed"}
            end;
        _ ->
            {error, ~"google_token_exchange_failed"}
    end.

%% --- Config helpers ---

-spec apple_bundle_id() -> binary() | undefined.
apple_bundle_id() ->
    case application:get_env(asobi, apple_bundle_id, undefined) of
        V when is_binary(V) -> V;
        _ -> undefined
    end.

-spec google_package_name() -> binary() | undefined.
google_package_name() ->
    case application:get_env(asobi, google_package_name, undefined) of
        V when is_binary(V) -> V;
        _ -> undefined
    end.

-spec sign_rsa(binary(), term()) -> binary().
sign_rsa(Data, Key) when is_tuple(Key) ->
    public_key:sign(Data, sha256, Key).

-spec is_expired(integer() | undefined) -> boolean().
is_expired(undefined) -> false;
is_expired(ExpiresMs) -> erlang:system_time(millisecond) > ExpiresMs.
