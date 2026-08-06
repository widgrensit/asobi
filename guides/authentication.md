# Authentication

asobi supports username/password, OAuth/OIDC social login (Google, Apple,
Microsoft, Discord), Steam, and anonymous [guest](#guest-anonymous) accounts a
player can later upgrade to a real one. A player can link several providers to
one account.

Every auth endpoint returns the same four fields: `player_id`, `access_token`
(short-lived), `refresh_token` (used against `/auth/refresh`) and `username`.
Use `access_token` as the `Bearer` credential. There is no `session_token`
field anywhere in asobi.

Run the `curl` examples in Git Bash or WSL on Windows, or use PowerShell's
`Invoke-RestMethod` with the same URL and a JSON `-Body`. Authenticated calls
add `-Headers @{ Authorization = 'Bearer <token>' }`.

## Username and password

Register to create an account and receive a token pair:

```bash
curl -X POST http://localhost:8084/api/v1/auth/register \
  -H 'Content-Type: application/json' \
  -d '{"username": "player1", "password": "secret123"}'
```

```json
{"player_id": "...", "access_token": "...", "refresh_token": "...", "username": "player1"}
```

Log in to get a fresh pair for an existing account:

```bash
curl -X POST http://localhost:8084/api/v1/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"username": "player1", "password": "secret123"}'
```

The response is identical. A wrong username or password answers
`401 auth.invalid_credentials`; a missing field answers `400 missing_field`.

Use the access token in subsequent requests:

```
Authorization: Bearer <access_token>
```

## Refresh and rotation

Access tokens are short-lived. When one expires (a `401`), exchange the refresh
token for a fresh pair at `/api/v1/auth/refresh`. Rotation is single-use: the
server burns the presented refresh token and returns a new access token and a
new refresh token, so always store both from the response.

```bash
curl -X POST http://localhost:8084/api/v1/auth/refresh \
  -H 'Content-Type: application/json' \
  -d '{"refresh_token": "<refresh_token>"}'
# => {"access_token": "...", "refresh_token": "..."}
```

The official SDKs persist the refresh token, attach the access token to every
call, and refresh-and-retry on a 401 automatically.

## Logout

```bash
curl -X POST http://localhost:8084/api/v1/auth/logout \
  -H 'Content-Type: application/json' \
  -d '{"refresh_token": "<refresh_token>"}'
```

```json
{"success": true}
```

Passing the refresh token revokes the whole **refresh family** - the chain of
tokens that rotation minted from the original login, not just the one presented
- so a stolen older token in that chain is dead too. The access token on the
request is revoked as well.

Calling it with no body still revokes the access token on the request and
answers `200`. Logging out twice is not an error.

## OAuth and social login

The game client authenticates with the platform SDK (Google Sign-In, Apple
Sign-In and so on) to obtain an ID token, then sends it to asobi for
server-side validation.

```
POST /api/v1/auth/oauth
```

### Flow

1. Player taps "Sign in with Google" in your game
2. Platform SDK returns an ID token (JWT)
3. The game client sends the token to asobi
4. asobi validates the JWT against the provider's JWKS
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
  "access_token": "...",
  "refresh_token": "...",
  "username": "google_abc12345_4821",
  "created": true
}
```

Returning player response:

```json
{
  "player_id": "...",
  "access_token": "...",
  "refresh_token": "...",
  "username": "player1"
}
```

### Error responses

| Status | `error.code` | Cause |
|---|---|---|
| `400` | `missing_field` | `provider` or `token` absent, or not a string |
| `401` | `auth.provider_rejected` | The provider rejected the token. The specific reason is in `details.reason` |
| `401` | `auth.unsupported_provider` | `provider` is not one of the values below, or the deployment configured no provider under that name |
| `403` | `auth.registration_closed` | New-account registration is closed for this deployment |
| `409` | `auth.already_registering` | Two first-sign-ins for the same provider identity raced; retry, and the retry logs in to the account the other request created |
| `409` | `auth.provider_already_linked` | On `/auth/link`: that provider account already belongs to another player |
| `500` | `auth.registration_failed` | Account creation failed for a reason other than the race above (logged server-side) |

Every provider-side rejection collapses to `auth.provider_rejected`, whatever
went wrong. A bad signature, an expired token, a wrong audience, an unreachable
JWKS and a Steam ticket the Steam Web API refused all produce that one code,
with the distinguishing reason in `details.reason`:

```json
{"error": {"code": "auth.provider_rejected", "message": "...", "details": {"reason": "invalid_token"}}}
```

Branch on the code, log the reason. The reason is a server-side label - for
Steam it is lifted from Steam's own error response - so it is not part of
asobi's contract and can be reworded.

### Supported providers

The issuer column is the value **you configure**, not a default: asobi ships no
OIDC provider configuration at all, so social login is entirely off until you
add `oidc_providers`. These are the well-known issuers for each provider.

| Provider | `provider` value | Issuer to configure |
|---|---|---|
| Google | `"google"` | `https://accounts.google.com` |
| Apple | `"apple"` | `https://appleid.apple.com` |
| Microsoft | `"microsoft"` | `https://login.microsoftonline.com/common/v2.0` |
| Discord | `"discord"` | `https://discord.com` |
| Steam | `"steam"` | not OIDC, see [Steam](#steam) below |

A provider entry with no `issuer`, or with an issuer that is not `https://`,
is **disabled at boot**. The node logs `oidc provider is missing issuer` or
`oidc provider has a non-https issuer` naming the provider, then starts
normally with that one provider dropped. You do not get an error at request
time; you get `401 auth.unsupported_provider` for a provider you believe you
configured, and the reason is in the boot log. The https rule is not optional:
asobi pins the TLS trust anchor for the discovery and JWKS fetch, and a
plaintext issuer bypasses that pin entirely.

### Configuration

Add provider credentials to your `sys.config`:

```erlang
{asobi, [
    {oidc_providers, #{
        google => #{
            issuer => ~"https://accounts.google.com",
            client_id => ~"YOUR_CLIENT_ID",
            client_secret => ~"YOUR_CLIENT_SECRET"
        },
        apple => #{
            issuer => ~"https://appleid.apple.com",
            client_id => ~"YOUR_CLIENT_ID",
            client_secret => ~"YOUR_CLIENT_SECRET"
        }
    }}
]}
```

The map key is an atom and the value a map; anything else is logged and
dropped. Each provider needs a client id and secret from its developer console:

- Google: [Google Cloud Console](https://console.cloud.google.com/), APIs and Services, Credentials
- Apple: [Apple Developer](https://developer.apple.com/), Certificates Identifiers and Profiles, Service IDs
- Microsoft: [Azure Portal](https://portal.azure.com/), App registrations
- Discord: [Discord Developer Portal](https://discord.com/developers/applications), OAuth2

## Steam

Steam uses session tickets instead of OIDC. The game client obtains a ticket
via `ISteamUser::GetAuthSessionTicket` and sends the hex-encoded ticket.

```bash
curl -X POST http://localhost:8084/api/v1/auth/oauth \
  -H 'Content-Type: application/json' \
  -d '{"provider": "steam", "token": "14000000..."}'
```

asobi validates the ticket via the Steam Web API and fetches the player's
display name from their Steam profile.

### Configuration

```erlang
{asobi, [
    {steam_api_key, ~"YOUR_STEAM_WEB_API_KEY"},
    {steam_app_id, ~"YOUR_STEAM_APP_ID"}
]}
```

Get your API key from the [Steam Partner site](https://partner.steamgames.com/).

## Guest (Anonymous)

Guest auth lets a player start playing immediately - no email, no password, no
social sign-in - and claim a real account later without losing progress. It is
the "device-based auth" option: the client generates a secret once, stores it on
the device, and presents it to resume the same account on every launch.

Guest auth is **opt-in** and disabled by default. It turns on only when two
independent parties agree (see [Configuration](#configuration-2)): the **game**
declares `guest_auth = true` in its Lua config, and the **operator** supplies a
verifier pepper. Either one alone leaves the endpoints returning
`403 guest.disabled`.

### How it works

1. On first launch the client generates a random `device_secret` (>= 32 bytes
   from a CSPRNG) and a stable `device_id`, and stores both on the device
   (Keychain on iOS, Keystore on Android, etc.).
2. The client posts them to `POST /api/v1/auth/guest`. asobi creates a player
   and stores only a **salted, peppered HMAC** of the secret - never the secret
   itself - then returns a token pair.
3. On later launches the client posts the same `device_id` + `device_secret`.
   asobi verifies the HMAC and resumes the **same** player (create-or-resume).
4. When the player is ready, they call `POST /api/v1/auth/guest/upgrade` with a
   username and password. The account becomes a normal password account and the
   device secret is revoked.

The client must treat `device_secret` like a password: generate it with a
cryptographic RNG, store it in secure device storage, and never log or transmit
it anywhere but this endpoint. A guest account is only as safe as that secret,
so it is low-assurance until upgraded.

### Managing the device credential

You do not have to generate or store the `{device_id, device_secret}` pair by
hand. Every SDK ships a device-credential helper that handles steps 1 and 3 for
you: it generates the pair with a CSPRNG on first run, persists it in the
platform's secure/save storage, and re-presents the same pair on later
launches. Prefer the helper over rolling your own storage.

```lua
-- Create-or-resume with a managed credential: generates and persists on the
-- first run, reuses it afterwards. No device_id/device_secret handling in your
-- own code.
local data, err = asobi.auth.guest_device(client)
```

The lower-level pieces are exposed too: `generate` (a fresh in-memory pair),
`load_or_create` (load the persisted pair, or make and store one on first run),
and `clear` (forget the stored pair). Sign-out keeps the pair on purpose, so the
same guest resumes on the next launch; after an upgrade the server-side verifier
is already revoked, so call `clear` to drop the now-dead local pair.

Names vary by SDK: `guest_device` (the snake-case SDKs), `guestDevice` (Dart and
JS), `GuestDevice`/`GuestDeviceAsync` (Unreal and Unity). See the SDK's README
for the exact name and the storage location on each platform.

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
  "username": "guest_9c41e0b7a2d5f318",
  "created": true,
  "guest": true
}
```

Later calls with the same credentials resume the same player and omit `created`.
A wrong secret for a known `device_id` returns `401 guest.invalid_device_secret`
and never creates a second account.

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

| Status | `error.code` | Meaning |
|--------|--------------|---------|
| `400`  | `missing_field`                    | `device_id` / `device_secret` (or `username` / `password` on upgrade) absent |
| `400`  | `guest.weak_device_secret`         | Secret decodes to fewer than 32 bytes (or exceeds the size cap) |
| `400`  | `guest.invalid_device_id`          | `device_id` empty or over 255 bytes |
| `401`  | `guest.invalid_device_secret`      | Wrong secret for a known device |
| `401`  | `guest.revoked`                    | The device verifier was revoked |
| `401`  | `guest.already_upgraded`           | The account was already claimed; log in with its real credentials |
| `403`  | `guest.disabled`                   | Guest auth is off - the game did not declare `guest_auth`, or no pepper is present |
| `403`  | `auth.registration_closed`         | The deployment's registration posture refuses new accounts |
| `403`  | `auth.password_registration_disabled` | From the shared registration guard. A closed deployment answers `auth.registration_closed` on the guest paths, so you should not see this one here |
| `404`  | `player.not_found`                 | The upgrade token resolves to no player |
| `409`  | `guest.device_already_registered`  | Two creates for the same device raced; retry - the retry resumes the existing guest |
| `409`  | `guest.not_unclaimed`              | Upgrade target is not an unclaimed guest |
| `409`  | `auth.username_taken`              | Upgrade username is already in use |
| `422`  | `validation_failed`                | On upgrade: the new username or password failed validation. `details.fields` is per-field, for a form UI |
| `500`  | `guest.create_failed`              | The player row could not be created |
| `500`  | `internal`                         | The device resolves to an identity whose player no longer exists, or another server-side failure |
| `503`  | `guest.capacity_reached`           | Global create limit or the unlinked-guest cap was hit |

### Configuration

Guest auth is on only if both halves below are satisfied; either alone fails
closed with `403 guest.disabled`. The toggle belongs to the game, the pepper to
the operator (ADR 0004).

**1. The game declares the toggle.** `guest_auth` is a boolean game global,
declared like `match_size` - in `match.lua` for a single-mode game, or
`config.lua` for a multi-mode game:

```lua
guest_auth = true
```

**2. The operator supplies the pepper** and any abuse controls:

```erlang
{asobi, [
    %% Required. A key-id -> pepper map, each pepper >= 32 bytes. Keep old key
    %% ids for the guest retention window so existing guests still resume
    %% after a rotation.
    {guest_verifier_pepper, #{~"v1" => ~"a-32-byte-or-longer-secret......"}},
    {guest_verifier_key_id, ~"v1"},

    %% Optional abuse controls.
    {guest_unlinked_cap, 100000},        %% max unclaimed guests, or `infinity`

    %% Optional retention. Unset = permanent guests (never reaped). A number of
    %% seconds deletes unclaimed guests older than that.
    {guest_reap_after, 2592000}          %% e.g. 30 days
]}
```

A bare binary is accepted too, as shorthand for a single key: with
`{guest_verifier_pepper, ~"a-32-byte-or-longer-secret......"}` every verifier
uses it whatever key id is recorded. Prefer the map, because the bare form has
no way to rotate.

`guest_verifier_key_id` defaults to `~"v1"`, so a map keyed `~"v1"` needs no
second setting. A pepper under 32 bytes is treated as absent and guest auth
stays off.

**`guest_verifier_pepper` in `sys.config` is the only mechanism that works.**
The image declares an `ASOBI_GUEST_VERIFIER_PEPPER` environment variable, but
nothing substitutes it into the rendered configuration and nothing reads it: a
deployment that sets only that variable gets `403 guest.disabled` on every
guest call, forever. Set the `sys.config` key.

The pepper is a server-side secret that makes a stolen table of verifiers
useless without it, so keep it out of source and out of your game bundle. Guest
creation is additionally bounded by a global rate limiter and the per-IP auth
limiter.

## Linking providers

A player can link additional providers to an existing account and then sign in
from any of them.

### Link a provider

Requires an authenticated session.

```bash
curl -X POST http://localhost:8084/api/v1/auth/link \
  -H 'Authorization: Bearer <access_token>' \
  -H 'Content-Type: application/json' \
  -d '{"provider": "discord", "token": "eyJhbGciOi..."}'
```

```json
{"provider": "discord", "provider_uid": "123456789", "linked": true}
```

A provider account already linked to someone else answers
`409 auth.provider_already_linked`.

### Unlink a provider

**The provider goes in the query string, not the body.** A `DELETE` carrying a
JSON body is not read at all and answers `400 missing_field`.

```bash
curl -X DELETE 'http://localhost:8084/api/v1/auth/unlink?provider=discord' \
  -H 'Authorization: Bearer <access_token>'
```

```json
{"success": true}
```

asobi refuses to unlink the last auth method, so a player cannot lock
themselves out: if the account has no password and no other linked provider,
the call answers `422 auth.last_auth_method`. An unlinked provider answers
`404 auth.identity_not_found`.

## WebSocket authentication

After obtaining an access token from any auth method, connect to the WebSocket
and authenticate:

```json
{
  "type": "session.connect",
  "payload": {"token": "<access_token>"}
}
```

The token works the same regardless of which provider issued it.

## SDK integration

Every SDK wraps these routes, stores the token pair and refreshes it on a 401.
The platform SDK returns an ID token; hand it to `auth.oauth` with the provider
name. See your SDK's README for the exact method names and the device-credential
helper covered under [Guest](#guest-anonymous).

## Inspecting players

The console has a Players screen, searchable by username and display name. It
shows the ops projection only: `id`, `username`, `display_name`, `avatar_url`,
`metadata`, `inserted_at` and `updated_at`. It does not show linked providers,
guest status, device verifiers or tokens, and it cannot ban, reset a password,
revoke a session or unlink anything - the ops plane is reads. See
[Operator console](console.md).

## Next steps

- [In-app purchases](iap.md) - receipt validation for Apple and Google
- [REST API](rest-api.md) - full API reference
- [WebSocket protocol](websocket-protocol.md) - real-time message types
