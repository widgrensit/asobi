# In-App Purchases

Asobi provides server-side receipt validation for Apple App Store and
Google Play purchases. All IAP endpoints require an authenticated session.

## Why Server-Side Validation?

Client-side receipt validation can be spoofed. Always validate purchases on the
server before granting items, currency, or premium features to a player.

## Apple App Store

Validates signed transactions from StoreKit 2. The game client sends the
JWS (JSON Web Signature) string obtained after a purchase.

```
POST /api/v1/iap/apple
```

### Example

```bash
curl -X POST http://localhost:8082/api/v1/iap/apple \
  -H 'Authorization: Bearer <session_token>' \
  -H 'Content-Type: application/json' \
  -d '{"signed_transaction": "eyJhbGciOi..."}'
```

### Response

```json
{
  "product_id": "com.example.game.gems_100",
  "transaction_id": "2000000123456789",
  "original_transaction_id": "2000000123456789",
  "purchase_date": 1711700000000,
  "expires_date": null,
  "quantity": 1,
  "type": "Consumable",
  "valid": true
}
```

### Configuration

```erlang
{asobi, [
    {apple_bundle_id, <<"com.example.game">>}
]}
```

The `apple_bundle_id` must match your app's bundle identifier. Transactions
with a mismatched bundle ID are rejected.

### Handling the Result

After a successful validation, grant the purchase to the player using the
economy system:

```erlang
case asobi_iap:verify_apple(SignedTransaction) of
    {ok, #{product_id := ProductId, valid := true}} ->
        %% Map product ID to in-game currency/items
        grant_purchase(PlayerId, ProductId);
    {ok, #{valid := false}} ->
        %% Subscription expired or purchase invalid
        {error, expired};
    {error, Reason} ->
        {error, Reason}
end.
```

## Google Play

Validates purchases using the Google Play Developer API. The game client sends
the product ID and purchase token obtained from Google Play Billing.

```
POST /api/v1/iap/google
```

### Example

```bash
curl -X POST http://localhost:8082/api/v1/iap/google \
  -H 'Authorization: Bearer <session_token>' \
  -H 'Content-Type: application/json' \
  -d '{
    "product_id": "gems_100",
    "purchase_token": "opaque-token-from-google-play..."
  }'
```

### Response

```json
{
  "product_id": "gems_100",
  "order_id": "GPA.1234-5678-9012-34567",
  "purchase_time": 1711700000000,
  "consumption_state": 0,
  "acknowledged": false,
  "valid": true
}
```

### Configuration

Google Play validation requires a service account with the
`androidpublisher` scope.

1. Create a service account in [Google Cloud Console](https://console.cloud.google.com/)
2. Grant it access in Google Play Console → API access
3. Download the JSON key file

```erlang
{asobi, [
    {google_package_name, <<"com.example.game">>},
    {google_service_account_key, <<"/path/to/service-account.json">>}
]}
```

### Purchase States

| `consumptionState` | Meaning |
|---|---|
| `0` | Not consumed |
| `1` | Consumed |

| `acknowledged` | Meaning |
|---|---|
| `false` | Not yet acknowledged |
| `true` | Acknowledged |

## SDK Integration

### Unity (C#)

```csharp
// After a StoreKit 2 purchase (Apple)
string signedTransaction = storeKit.Transaction.JwsRepresentation;
var result = await asobi.IAP.VerifyApple(signedTransaction);
if (result.Valid) {
    // Purchase verified, items granted server-side
}

// After a Google Play purchase
string purchaseToken = purchase.PurchaseToken;
var result = await asobi.IAP.VerifyGoogle("gems_100", purchaseToken);
if (result.Valid) {
    // Purchase verified
}
```

### Godot (GDScript)

```gdscript
# Apple
var result = await asobi.iap.verify_apple(signed_transaction)
if result.valid:
    print("Purchase verified: ", result.product_id)

# Google
var result = await asobi.iap.verify_google("gems_100", purchase_token)
if result.valid:
    print("Purchase verified: ", result.order_id)
```

### Dart / Flutter / Flame

```dart
// Apple
final result = await asobi.iap.verifyApple(signedTransaction);
if (result.valid) {
  // Grant items
}

// Google
final result = await asobi.iap.verifyGoogle('gems_100', purchaseToken);
if (result.valid) {
  // Grant items
}
```

## Security Notes

- Always validate receipts server-side, never trust the client alone
- Check the `product_id` matches what you expect before granting items
- For Apple subscriptions, check `expires_date` and `valid` together
- For Google, acknowledge purchases after granting to prevent refund abuse
- Log all IAP validations for audit and dispute resolution

## Next Steps

- [Authentication](authentication.md) -- auth methods and provider linking
- [Economy](economy.md) -- wallets, currencies, and store
- [REST API](rest-api.md) -- full API reference
