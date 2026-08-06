# In-app purchases

Server-side receipt validation for the Apple App Store and Google Play. Both
endpoints require an authenticated session.

There is no Lua path for IAP. Verification is an HTTP route the client calls
directly; a game script cannot reach it.

## Why server-side validation

Client-side receipt checks can be spoofed. Validate on the server before
granting items, currency or premium features.

asobi verifies the receipt and records it. It does **not** credit a wallet or
grant an item - map the returned `product_id` to whatever your game owes and
call the [economy](economy.md) yourself.

## Apple App Store

Validates signed transactions from StoreKit 2. The client sends the JWS string
it got after the purchase.

```
POST /api/v1/iap/apple
```

```bash
curl -X POST http://localhost:8084/api/v1/iap/apple \
  -H 'Authorization: Bearer <access_token>' \
  -H 'Content-Type: application/json' \
  -d '{"signed_transaction": "eyJhbGciOi..."}'
```

```json
{
  "product_id": "com.example.game.gems_100",
  "transaction_id": "2000000123456789",
  "original_transaction_id": "2000000123456789",
  "purchase_date": 1711700000000,
  "expires_date": "undefined",
  "quantity": 1,
  "type": "Consumable",
  "valid": true,
  "duplicate": false
}
```

`valid` is `false` only when `expires_date` is in the past, which happens for
an expired subscription and nothing else. A consumable has no `expires_date`
and is always `valid: true` when it verifies at all - every other failure is an
error response, not `valid: false`.

A field the store's payload does not carry comes back as the **string**
`"undefined"`, not JSON `null` - here `expires_date`,
`original_transaction_id` and `product_id`, and on the Google side
`purchase_time` and `consumption_state`. Treat `"undefined"` as absent.

### Configuration

Apple validation needs the bundle id **and** a trust anchor for the certificate
chain. Both are required; configure only the first and every call fails.

```erlang
{asobi, [
    {apple_bundle_id, ~"com.example.game"},

    %% One of these two. `apple_root_certs` takes a list of DER or PEM
    %% binaries; `apple_root_cert_path` a file to read them from.
    {apple_root_cert_path, ~"/etc/asobi/AppleRootCA-G3.cer"}
]}
```

Missing bundle id answers `iap.verification_failed` with
`details.reason: "apple_iap_not_configured"`. Missing certificates answer the
same code with `details.reason: "apple_root_cert_not_configured"`, and
certificates that will not decode with `"apple_root_cert_invalid"`. A
transaction whose `bundleId` does not match yours is rejected with
`"bundle_id_mismatch"`.

Get the Apple Root CA - G3 certificate from
[Apple's PKI page](https://www.apple.com/certificateauthority/).

## Google Play

Validates purchases through the Google Play Developer API. The client sends the
product id and the purchase token from Google Play Billing.

```
POST /api/v1/iap/google
```

```bash
curl -X POST http://localhost:8084/api/v1/iap/google \
  -H 'Authorization: Bearer <access_token>' \
  -H 'Content-Type: application/json' \
  -d '{
    "product_id": "gems_100",
    "purchase_token": "opaque-token-from-google-play..."
  }'
```

```json
{
  "product_id": "gems_100",
  "order_id": "GPA.1234-5678-9012-34567",
  "purchase_time": "1711700000000",
  "consumption_state": 0,
  "acknowledged": false,
  "valid": true,
  "duplicate": false
}
```

`product_id`, `order_id`, `purchase_time` and `consumption_state` are Google's
own values passed through unchanged. `purchase_time` is Google's
`purchaseTimeMillis`, which the Play Developer API serialises as a **string**
because it is an int64 - parse it, do not assume a number.

The Google path returns `valid: true` or an error. It never returns
`valid: false`: a purchase Google reports as cancelled or pending is an error
response, not a successful one with a flag.

### Configuration

Google Play validation needs a service account with the `androidpublisher`
scope.

1. Create a service account in [Google Cloud Console](https://console.cloud.google.com/).
2. Grant it access under Google Play Console, API access.
3. Download the JSON key file and point asobi at it.

```erlang
{asobi, [
    {google_package_name, ~"com.example.game"},
    {google_service_account_key, ~"/path/to/service-account.json"}
]}
```

### Purchase states

| `consumption_state` | Meaning |
|---|---|
| `0` | Not consumed |
| `1` | Consumed |

`acknowledged` is `true` once Google's `acknowledgementState` is 1. Acknowledge
purchases after granting, or Google refunds them automatically.

## Replay protection

asobi persists every verified transaction to the `iap_transactions` table,
keyed uniquely on `(provider, transaction_id)` - the Apple `transaction_id` or
the Google `order_id`. Two consequences:

- The **same player** re-submitting a receipt gets `200` with
  `"duplicate": true` and no second row. Re-submission is safe, so a client
  that retries after a network failure cannot double-grant, provided your grant
  path checks `duplicate`.
- A **different player** submitting a receipt someone else already claimed gets
  `409 iap.transaction_already_claimed`. A receipt belongs to one account.

A verified receipt carrying no transaction id at all is refused with
`iap.missing_transaction_id` rather than stored unkeyed.

## Error codes

| Status | Code | `details.reason` examples |
|---|---|---|
| `400` | `missing_field` | The Apple body is missing `signed_transaction` |
| `422` | `iap.verification_failed` | `apple_iap_not_configured`, `apple_root_cert_not_configured`, `apple_root_cert_invalid`, `bundle_id_mismatch`, `invalid_jws`, `invalid_jws_format`, `google_iap_not_configured`, `missing_required_fields` (the Google body is missing `product_id` or `purchase_token`), `purchase_not_found`, `purchase_cancelled`, `purchase_pending`, `google_api_error`, `google_api_unavailable` |
| `422` | `iap.missing_transaction_id` | The verified receipt carries no transaction id |
| `409` | `iap.transaction_already_claimed` | Another player already claimed this transaction |
| `500` | `iap.record_failed` | The verified transaction could not be written |

The reasons under `iap.verification_failed` name an internal verification step.
They are diagnostics, not a contract: branch on the code, log the reason.

```json
{"error": {"code": "iap.verification_failed", "message": "...", "details": {"reason": "bundle_id_mismatch"}}}
```

## Handling the result

### In Erlang

```erlang
case asobi_iap:verify_apple(SignedTransaction) of
    {ok, #{product_id := ProductId, valid := true}} ->
        grant_purchase(PlayerId, ProductId);
    {ok, #{valid := false}} ->
        {error, subscription_expired};
    {error, Reason} ->
        {error, Reason}
end.
```

`verify_google/1` takes **one map** with binary keys, not two arguments:

```erlang
{ok, Result} = asobi_iap:verify_google(#{
    ~"product_id" => ~"gems_100",
    ~"purchase_token" => PurchaseToken
}).
```

Neither function records the transaction or binds it to a player - that is the
controller's job. Calling `asobi_iap` directly skips replay protection.

### From a client

Every SDK wraps these two routes and returns the response above unchanged,
including `valid` and `duplicate`. See your SDK's README for the exact method
names.

## Inspecting purchases

The console has no IAP screen. Verified transactions land in the
`iap_transactions` table - `player_id`, `provider`, `transaction_id`,
`original_transaction_id`, `product_id`, `inserted_at` - so query the database
for dispute resolution. See [Operator console](console.md).

## Next steps

- [Authentication](authentication.md) - auth methods and provider linking.
- [Economy](economy.md) - the wallets and items you grant after a receipt verifies.
- [REST API](rest-api.md) - full API reference.
