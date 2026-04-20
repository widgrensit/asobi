# Authentication

Asobi supports multiple authentication methods: username/password, OAuth/OIDC
social login (Google, Apple, Microsoft, Discord), Steam, and device-based auth.

Players can link multiple providers to a single account.

## Username & Password

The simplest method. Register and login to receive a session token:

```bash
curl -X POST http://localhost:8080/api/v1/auth/register \
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
curl -X POST http://localhost:8080/api/v1/auth/oauth \
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
curl -X POST http://localhost:8080/api/v1/auth/oauth \
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

## Linking Providers

Players can link additional providers to their existing account. This allows
them to sign in from different platforms (e.g., link both Google and Steam to
the same player).

### Link a Provider

Requires an authenticated session.

```bash
curl -X POST http://localhost:8080/api/v1/auth/link \
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
curl -X DELETE http://localhost:8080/api/v1/auth/unlink \
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
