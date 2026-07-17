# Authentication

Asobi supports multiple authentication methods: username/password, OAuth/OIDC
social login (Google, Apple, Microsoft, Discord), Steam, and anonymous
[guest](#guest-anonymous) accounts that a player can later upgrade to a real one.

Players can link multiple providers to a single account.

> Auth endpoints return an `access_token` (short-lived) and a `refresh_token`
> (used against `/auth/refresh`). The `session_token` shown in the shorthand
> examples below is the access token; use it as the `Bearer` credential.

## Username & Password

The simplest method. Register and login to receive a session token:

```bash
curl -X POST http://localhost:8084/api/v1/auth/register \
  -H 'Content-Type: application/json' \
  -d '{"username": "player1", "password": "secret123"}'
```

```json
{"player_id": "...", "session_token": "...", "username": "player1"}
```

Use the session token in subsequent requests:

```
Authorization: Bearer <session_token>
```

## OAuth / Social Login

For game clients, Asobi uses server-side token validation. The game client
authenticates with the platform SDK (Google Sign-In, Apple Sign-In, etc.)
to obtain an ID token, then sends it to Asobi for validation.

```
POST /api/v1/auth/oauth
```

### Flow

1. Player taps "Sign in with Google" in your game
2. Platform SDK returns an ID token (JWT)
3. Game client sends the token to Asobi
4. Asobi validates the JWT against the provider's JWKS
5. If the identity exists, the player is logged in
6. If not, a new player account is created and linked

### Example

```bash
curl -X POST http://localhost:8084/api/v1/auth/oauth \
  -H 'Content-Type: application/json' \
  -d '{"provider": "google", "token": "eyJhbGciOiJSUzI1NiIs..."}'
```

First-time response (new account created):

```json
{
  "player_id": "...",
  "session_token": "...",
  "username": "google_abc12345_4821",
  "created": true
}
```

Returning player response:

```json
{
  "player_id": "...",
  "session_token": "...",
  "username": "player1"
}
```

### Supported Providers

| Provider  | `provider` value | Issuer |
|-----------|-----------------|--------|
| Google    | `"google"`      | `https://accounts.google.com` |
| Apple     | `"apple"`       | `https://appleid.apple.com` |
| Microsoft | `"microsoft"`   | `https://login.microsoftonline.com/common/v2.0` |
| Discord   | `"discord"`     | `https://discord.com` |
| Steam     | `"steam"`       | N/A (custom, see below) |

### Configuration

Add provider credentials to your `sys.config`:

```erlang
{asobi, [
    {oidc_providers, #{
        google => #{
            issuer => <<"https://accounts.google.com">>,
            client_id => <<"YOUR_CLIENT_ID">>,
            client_secret => <<"YOUR_CLIENT_SECRET">>
        },
        apple => #{
            issuer => <<"https://appleid.apple.com">>,
            client_id => <<"YOUR_CLIENT_ID">>,
            client_secret => <<"YOUR_CLIENT_SECRET">>
        }
    }}
]}
```

Each provider needs a client ID and secret from the respective developer console:

- **Google**: [Google Cloud Console](https://console.cloud.google.com/) → APIs & Services → Credentials
- **Apple**: [Apple Developer](https://developer.apple.com/) → Certificates, Identifiers & Profiles → Service IDs
- **Microsoft**: [Azure Portal](https://portal.azure.com/) → App registrations
- **Discord**: [Discord Developer Portal](https://discord.com/developers/applications) → OAuth2

## Steam

Steam uses session tickets instead of OIDC. The game client obtains a ticket
via `ISteamUser::GetAuthSessionTicket` and sends the hex-encoded ticket.

```bash
curl -X POST http://localhost:8084/api/v1/auth/oauth \
  -H 'Content-Type: application/json' \
  -d '{"provider": "steam", "token": "14000000..."}'
```

Asobi validates the ticket via the Steam Web API and fetches the player's
display name from their Steam profile.

### Configuration

```erlang
{asobi, [
    {steam_api_key, <<"YOUR_STEAM_WEB_API_KEY">>},
    {steam_app_id, <<"YOUR_STEAM_APP_ID">>}
]}
```

Get your API key from the [Steam Partner site](https://partner.steamgames.com/).

## Guest (Anonymous)

Guest auth lets a player start playing immediately - no email, no password, no
social sign-in - and claim a real account later without losing progress. It is
the "device-based auth" option: the client generates a secret once, stores it on
the device, and presents it to resume the same account on every launch.

Guest auth is **opt-in** and disabled by default. Enable it in `sys.config`
(see [Configuration](#configuration-2)) before the endpoints respond.

### How it works

1. On first launch the client generates a random `device_secret` (>= 32 bytes
   from a CSPRNG) and a stable `device_id`, and stores both on the device
   (Keychain on iOS, Keystore on Android, etc.).
2. The client posts them to `POST /api/v1/auth/guest`. Asobi creates a player
   and stores only a **salted, peppered HMAC** of the secret - never the secret
   itself - then returns a token pair.
3. On later launches the client posts the same `device_id` + `device_secret`.
   Asobi verifies the HMAC and resumes the **same** player (create-or-resume).
4. When the player is ready, they call `POST /api/v1/auth/guest/upgrade` with a
   username and password. The account becomes a normal password account and the
   device secret is revoked.

The client must treat `device_secret` like a password: generate it with a
cryptographic RNG, store it in secure device storage, and never log or transmit
it anywhere but this endpoint. A guest account is only as safe as that secret,
so it is low-assurance until upgraded.

### Create or resume

```bash
curl -X POST http://localhost:8084/api/v1/auth/guest \
  -H 'Content-Type: application/json' \
  -d '{"device_id": "b64-device-id", "device_secret": "b64-32-random-bytes"}'
```

First call (new account):

```json
{
  "player_id": "...",
  "access_token": "...",
  "refresh_token": "...",
  "username": "guest_019f615cbc4a",
  "created": true,
  "guest": true
}
```

Later calls with the same credentials resume the same player and omit `created`.
A wrong secret for a known `device_id` returns `401 invalid_device_secret` and
never creates a second account.

### Upgrade to a real account

Requires the guest's own session (the token from the create-or-resume call).
Only an unclaimed guest may upgrade - a password account, or an account with a
non-guest provider, is refused.

```bash
curl -X POST http://localhost:8084/api/v1/auth/guest/upgrade \
  -H 'Authorization: Bearer <access_token>' \
  -H 'Content-Type: application/json' \
  -d '{"username": "player1", "password": "secret123"}'
```

```json
{
  "player_id": "...",
  "access_token": "...",
  "refresh_token": "...",
  "username": "player1",
  "upgraded": true
}
```

Upgrade revokes every token the guest held (a fresh pair is returned) and
deletes the device verifier, so the old device secret can no longer sign in.
Player id, progress, wallets, and inventory are preserved.

### Errors

| Status | `error` | Meaning |
|--------|---------|---------|
| `404`  | `guest_auth_disabled`     | Guest auth is not enabled in config |
| `400`  | `missing_required_fields` | `device_id` / `device_secret` (or `username` / `password` on upgrade) absent |
| `400`  | `weak_device_secret`      | Secret decodes to fewer than 32 bytes (or exceeds the size cap) |
| `400`  | `invalid_device_id`       | `device_id` empty or over 255 bytes |
| `401`  | `invalid_device_secret`   | Wrong secret for a known device |
| `401`  | `guest_revoked`           | The device verifier was revoked |
| `401`  | `guest_upgraded`          | The account was already claimed; log in with its real credentials |
| `409`  | `not_an_unclaimed_guest`  | Upgrade target is not an unclaimed guest |
| `409`  | `username_taken`          | Upgrade username is already in use |
| `422`  | `validation_failed`       | Upgrade fields invalid (see `fields`) |
| `503`  | `guest_capacity_reached`  | Global create limit or the unlinked-guest cap was hit |

### Configuration

```erlang
{asobi, [
    {guest_auth, true},
    %% Required. A key-id -> pepper map (>= 32 bytes each). Keep old keys for the
    %% guest retention window so existing guests can still resume after rotation.
    {guest_verifier_pepper, #{<<"v1">> => <<"a-32-byte-or-longer-secret......">>}},
    {guest_verifier_key_id, <<"v1">>},

    %% Optional abuse controls.
    {guest_unlinked_cap, 100000},        %% max unclaimed guests, or `infinity`

    %% Optional retention. Unset = permanent guests (never reaped). Set to a
    %% number of seconds to delete unclaimed guests older than that.
    {guest_reap_after, 2592000}          %% e.g. 30 days
]}
```

The pepper is a server-side secret that makes a stolen database of verifiers
useless without it - store it like any other secret (env/secret manager), not in
source. Guest creation is additionally bounded by a global rate limiter and the
per-IP auth limiter.

## Linking Providers

Players can link additional providers to their existing account. This allows
them to sign in from different platforms (e.g., link both Google and Steam to
the same player).

### Link a Provider

Requires an authenticated session.

```bash
curl -X POST http://localhost:8084/api/v1/auth/link \
  -H 'Authorization: Bearer <session_token>' \
  -H 'Content-Type: application/json' \
  -d '{"provider": "discord", "token": "eyJhbGciOi..."}'
```

```json
{"provider": "discord", "provider_uid": "123456789", "linked": true}
```

### Unlink a Provider

Asobi prevents unlinking the last auth method to avoid locking the player out.

```bash
curl -X DELETE http://localhost:8084/api/v1/auth/unlink \
  -H 'Authorization: Bearer <session_token>' \
  -H 'Content-Type: application/json' \
  -d '{"provider": "discord"}'
```

```json
{"success": true}
```

## WebSocket Authentication

After obtaining a session token (from any auth method), connect to the
WebSocket and authenticate:

```json
{
  "type": "session.connect",
  "payload": {"token": "<session_token>"}
}
```

The token works the same regardless of which provider was used to obtain it.

## SDK Integration

### Unity (C#)

```csharp
// Google Sign-In → Asobi
string idToken = googleSignIn.IdToken;
var response = await asobi.Auth.OAuth("google", idToken);
// response.SessionToken is now set automatically
```

### Godot (GDScript)

```gdscript
# Google Sign-In → Asobi
var id_token = google_sign_in.get_id_token()
var result = await asobi.auth.oauth("google", id_token)
# Session token is stored internally
```

### Dart / Flutter / Flame

```dart
// Google Sign-In → Asobi
final idToken = googleSignIn.currentUser!.authentication.idToken!;
final result = await asobi.auth.oauth('google', idToken);
// Session token is stored internally
```

### Defold (Lua)

```lua
-- Google Sign-In → Asobi
local id_token = google_sign_in.get_id_token()
asobi.auth.oauth("google", id_token, function(result)
    -- Session token is stored internally
end)
```

## Next Steps

- [In-App Purchases](iap.md) -- receipt validation for Apple and Google
- [REST API](rest-api.md) -- full API reference
- [WebSocket Protocol](websocket-protocol.md) -- real-time message types
