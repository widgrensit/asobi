-module(asobi_iap).

-export([verify_apple/1, verify_google/1]).

%% Apple App Store Server API v2
%% Validates a signed transaction (JWS) from StoreKit 2.
%% The client sends the JWS transaction string obtained from StoreKit.
-spec verify_apple(binary()) -> {ok, map()} | {error, binary()}.
verify_apple(SignedTransaction) ->
    case apple_bundle_id() of
        undefined ->
            {error, ~"apple_iap_not_configured"};
        BundleId ->
            do_verify_apple(SignedTransaction, BundleId)
    end.

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

-spec do_verify_apple(binary(), binary()) -> {ok, map()} | {error, binary()}.
do_verify_apple(SignedTransaction, ExpectedBundleId) ->
    case decode_jws_payload(SignedTransaction) of
        {ok, Payload} ->
            BundleId = maps:get(~"bundleId", Payload, undefined),
            ExpiresMs = maps:get(~"expiresDate", Payload, undefined),
            case BundleId of
                ExpectedBundleId ->
                    Result = #{
                        product_id => maps:get(~"productId", Payload),
                        transaction_id => maps:get(~"transactionId", Payload),
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
            end;
        {error, Reason} ->
            {error, Reason}
    end.

%% Decode the payload section of a JWS (base64url-encoded JSON).
%% Full signature verification against Apple's root CA should be added
%% for production — this extracts the payload for validation.
-spec decode_jws_payload(binary()) -> {ok, map()} | {error, binary()}.
decode_jws_payload(JWS) ->
    case binary:split(JWS, ~".", [global]) of
        [_, PayloadB64, _] ->
            try
                Decoded = base64:decode(PayloadB64, #{mode => urlsafe, padding => false}),
                case json:decode(Decoded) of
                    M when is_map(M) -> {ok, M};
                    _ -> {error, ~"invalid_jws_payload"}
                end
            catch
                _:_ -> {error, ~"invalid_jws"}
            end;
        _ ->
            {error, ~"invalid_jws_format"}
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
