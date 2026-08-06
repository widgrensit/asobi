# Authentication and rate limiting

How asobi authenticates clients, validates purchases, and bounds what a single
hostile request or a single hostile caller can cost. For the trust assumptions
underneath, see [Threat model](security-threat-model.md).

## Session bearer tokens

Every authenticated route is gated by `asobi_auth_plugin:verify/1`, which
expects an `Authorization: Bearer <token>` header. Tokens are issued by
`nova_auth_refresh:generate_pair/2` through `asobi_auth_tokens:issue/2,3` after
a successful register, login, refresh or provider flow. The caller receives
`player_id`, `access_token`, `refresh_token` and `username`; the refresh token
is single-use and rotates. The plugin attaches `auth_data => #{player_id => Id,
...}` to the request map, so controllers pattern-match on that rather than
parsing the header again.

On logout the presented access token is revoked through
`asobi_auth_tokens:revoke_access/1`, so it cannot outlive the cache TTL.

## Apple StoreKit 2 JWS verification

`asobi_iap:verify_apple/1` parses an Apple-signed JWS receipt and verifies it
end to end:

1. The header `alg` must be `ES256`. Every other algorithm is rejected.
2. The `x5c` chain is decoded (DER certificates, base64 in JWS order: leaf,
   intermediate, root).
3. The chain is validated against a configured Apple root CA with
   `public_key:pkix_path_validation/3`. The root is not bundled: set
   `apple_root_cert_path` or `apple_root_certs`, or verification returns
   `apple_root_cert_not_configured`.
4. The signature over `<header>.<payload>` is verified with the leaf
   certificate's public key. Only then is the payload returned, and a bundle id
   that is not the configured one fails with `bundle_id_mismatch`. Expiry is
   reported as a `valid` flag on the result rather than rejected.

Failures return `{error, Reason}` with a sanitised reason binary.
`asobi_iap_controller` returns them as
`{"error": {"code": "iap.verification_failed", "message": ..., "details":
{"reason": ...}}}` without leaking JWS internals.

There is no Lua path to IAP verification. It is an Erlang-side call on the
purchase route.

## Steam ticket validation

`asobi_steam:validate_ticket/1` validates a hex-encoded session ticket against
the Steam Web API:

1. The ticket must be `[0-9a-fA-F]+` and at most 4096 bytes. Anything else is
   rejected before any HTTP call.
2. Every dynamic URL component (key, app id, ticket, steam id) goes through
   `uri_string:quote/1`, so an `&` or `=` in client input cannot inject a query
   parameter into the Steam call.

It is invoked from `asobi_oauth_controller` for `provider = "steam"`.

## Guest device verifiers

Guest auth (`asobi_guest_controller`) lets a device create a player from a
`{device_id, device_secret}` pair with no credentials. It is built to leak
nothing useful even if the identity table is dumped.

- Fails closed. Guest routes serve only when `guest_auth` is true and a
  `guest_verifier_pepper` is configured. Otherwise every guest endpoint returns
  `guest.disabled` (403) and the misconfiguration is logged as
  `guest_auth_misconfigured`.
- The device secret is never stored. The row holds a verifier: a 16-byte random
  salt plus `crypto:mac(hmac, sha256, Pepper, <<Salt/binary, Secret/binary>>)`,
  kept in the identity's `provider_metadata` as `salt`, `key_id`, `verifier`
  and `revoked`, with the salt and the verifier base64-encoded.
- Resume compares with `crypto:hash_equals/2`, so a wrong secret is not
  recoverable by timing.
- The pepper lives outside the database, selected by key id. A dumped verifier
  table is useless without it, and it rotates: add a key id, point
  `guest_verifier_key_id` at it, keep the old ids for the retention window.
  A pepper under 32 bytes is treated as absent, so a truncated value fails
  closed rather than weakening the MAC.
- Bounded input. The secret must base64-decode to between 32 and 128 bytes and
  `device_id` is capped at 255 bytes, so an unauthenticated caller cannot force
  multi-megabyte HMAC work.
- Upgrade is compromise recovery. Claiming a guest calls
  `nova_auth_refresh:revoke_all/2` to kill the token family a stolen device
  secret may have minted, then deletes the guest identity so that secret can no
  longer resume the claimed account.
- Reaping is safe. The optional `asobi_guest_reaper` (off unless
  `guest_reap_after` is set) re-checks that a guest is still unclaimed inside
  its delete transaction, so a concurrent upgrade wins the race.

Treat guest accounts as low assurance until they are upgraded. Anything
valuable - purchases, competitive ranking, cross-device identity - should
require a claimed account.

## Registration mode

Registration is open by default and that is deliberate (ADR 0002): one asobi
deployment serves one game, the endpoint URL is the game identity, and a
downloadable client cannot prove it is your client. `registration` bounds
anonymous signup as a deployment decision:

```erlang
{registration, open}         %% default
%% {registration, oauth_only}
%% {registration, closed}
```

| Mode | Password register | Provider first-time | Guest first-time | Existing players |
|---|---|---|---|---|
| `open` (default) | allowed | allowed | allowed if `guest_auth` | allowed |
| `oauth_only` | denied, `auth.password_registration_disabled` | allowed | governed by `guest_auth` | allowed |
| `closed` | denied, `auth.registration_closed` | denied, `auth.registration_closed` | denied, `auth.registration_closed` | login, refresh and resume all still work |

A game bundle can also declare `script_registration`; the operator's
`registration` key wins wherever it is set, so a bundle can choose a posture
for a deployment that states none but can never widen one that does
(`asobi_registration`). An unrecognised value falls back to `open`, and
`log_mode/0` reports `invalid_registration_mode` at error level at boot.

The shipped `examples/` quickstarts and `asobi_register_bench` register
headless with a username and password, so leave `open` alone in dev and CI.
Choosing a stricter posture is a production decision. asobi logs the active
mode at boot as `event => registration_mode`.

## Rate limits

`asobi_rate_limit_plugin` runs as a `pre_request` plugin in
`config/{dev,prod}_sys.config.src` and picks a Seki limiter group from the
request path. Other limiters are checked at their own call sites. Every group
is registered by `register_limiters` in `asobi_sup`, and every bucket is
**per node**: in a cluster of N nodes an attacker gets N times the budget.

| Group | Limiter | Keyed on | Default | Where |
|---|---|---|---|---|
| `register` | `asobi_register_limiter` | IP, or player id if the request carries a Bearer token | 3 / sec | `/api/v1/auth/register` |
| `auth` | `asobi_auth_limiter` | same | 5 / sec | the rest of `/api/v1/auth/*`, and `POST /console/session` |
| `iap` | `asobi_iap_limiter` | same | 10 / sec | `/api/v1/iap/*` |
| `api` | `asobi_api_limiter` | same | 300 / sec | every other HTTP route |
| `ws_connect` | `asobi_ws_connect_limiter` | IP | 60 / sec | the WebSocket upgrade, spent before the Origin check |
| `join` | `asobi_join_limiter` | player id | 10 / 60 sec | the `match.join` and `world.join` WebSocket frames |
| `guest_global` | `asobi_guest_global_limiter` | one constant key | 100 / sec | guest creation, node-wide |
| `rehome` | `asobi_rehome_limiter` | player id | 5 / sec | world zone crossings |
| `rehome_global` | `asobi_rehome_global_limiter` | one constant key | 200 / sec | world zone crossings, node-wide |
| `script_log` | `asobi_script_log_limiter` | the call site's own key | 3 / 10 sec | repeated warning lines from a failing script or dropped input |

`rate_limit_key/1` buckets an authenticated caller on `player_id` and everyone
else on the peer IP, so one abusive player throttles themselves rather than
everyone behind their NAT. Anything that is not a `Bearer` scheme, or that
reaches the plugin without `auth_data`, falls back to the IP bucket.

The two global buckets exist because a per-IP or per-player limit does not
bound the aggregate: guest rows are minted unauthenticated, and every zone
crossing calls into the one `asobi_terrain_store` the whole world shares, so N
attackers each within their own budget still scale the load linearly.

`/api/v1/auth/register` gets the tighter bucket because it runs the password
KDF (pbkdf2_sha256, see `pbkdf2_iterations`) as its only cost gate. Sharing
login's bucket let a signup flood both starve honest logins and amplify CPU.
The auth bucket plus that same KDF on
`nova_auth_accounts:authenticate/3` is the brute-force gate for login, and it
is why `POST /console/session` shares it: same threat, same shape, one fewer
knob to leave unset. Neither route carries a session, so in practice both are
bucketed on the caller's IP, and distributed abuse is the client gate's
problem rather than the limiter's.

Override any group in your sys config:

```erlang
{rate_limits, #{
    auth     => #{limit => 10, window => 1000},
    register => #{limit => 5,  window => 1000},
    iap      => #{limit => 20, window => 1000},
    api      => #{limit => 600, window => 1000}
}}
```

The dev and test config raises `auth`, `register`, `iap` and `api` to 1000
because CT fires bursts at `127.0.0.1` and the production auth cap would fail
the suites.

The Lua runtime registers two more groups of its own, `log` and `log_global`,
which bound `game.log` volume rather than abuse. They read the same
`rate_limits` key and their names are disjoint from the ones above, so one
merged map carries both.

## Client gate (pre-auth)

`asobi_client_gate` is a pluggable "is this traffic allowed in" seam on the
three anonymous auth-create routes: `/api/v1/auth/register`,
`/api/v1/auth/oauth` and `/api/v1/auth/guest`. It is distinct from
`asobi_auth_plugin`, which answers "who is the player": a gate carries no
player identity, and its return type is deliberately narrow so an
implementation cannot leak or forge one.

```erlang
-callback verify(asobi_client_gate:context()) -> skip | {deny, Reason :: binary()}.
```

The input is a minimised context, not the raw request: `#{ip, headers, path,
token}`. The request map still holds the registration plaintext password at
that point, and a traffic gate has no use for it, so a verbose or buggy
third-party gate cannot log or forward credentials.

Wire an implementation with `{client_gate, my_gate_module}` in app env. Unset
is a no-op, so bots, dedicated servers, CI and headless clients keep working by
default. `asobi_client_gate_plugin` runs immediately after the rate limiter and
before the password KDF, so a denial (`client_gate_denied`, 403) never pays the
pbkdf2 cost and a register flood is shed by the cheap in-memory limiter before
it can trigger an outbound siteverify.

A configured gate that crashes, hangs or returns garbage fails closed with
`client_gate_denied` and a `client_gate_unavailable` reason: a control that
silently fails open is bypassable by knocking over the vendor. The call is
bounded by `{client_gate_timeout, Ms}` (default 5000) so a stalled siteverify
cannot pin the request process. Trade strictness for availability with
`{client_gate_on_error, skip}`.

CAPTCHA, Turnstile and hCaptcha are consumers of this seam and ship outside
core: a vendor round-trip must not couple asobi's request path to a SaaS.

## Per-request bounds

Deliberate upper bounds that exist to cap what one hostile request costs:

- Request body - capped at 1 MiB by `asobi_body_cap_plugin`, before any bytes
  are buffered onto the BEAM heap. A body with no `Content-Length` is rejected
  with 411 `length_required`; over the cap is 413 `payload_too_large`.
- WebSocket pre-auth - a socket that has not authenticated within 10 seconds is
  closed with 1008 `idle_auth_timeout`. Override with
  `asobi.ws_idle_auth_timeout_ms`.
- Cloud saves (`/saves/:slot`) - 256 KB per save, 10 slots per player.
- Storage (`/storage/:collection/:key`) - `read_perm` and `write_perm` limited
  to `public` and `owner`; anything else is `storage.invalid_perm` (400). A
  single object is capped at the same 256 KB as a save
  (`storage.value_too_large`).
- Inventory consume - quantity in `[1, 1000000]`.
- Leaderboard `top` and `around` - `?limit` clamped to 100, `?range` to 50,
  which bounds an O(N) scan.
- Chat history - `?limit` clamped to `[1, 200]`, and channel membership is
  enforced (DM participants, world joiners, group members).
- Chat buffers - each channel keeps the last 100 messages in memory, and the
  channel listing enumerates at most 1000 channels so the sort behind it stays
  bounded.
- DM send - content capped at 2000 bytes; empty or non-binary content rejected.
- Chat channels - an id must be 1 to 256 bytes and carry one of six prefixes
  (`global:`, `dm:`, `world:`, `zone:`, `prox:`, `room:`), a connection may
  hold 32 joined channels at once, and an idle channel stops after 60 seconds
  with no live members.
- World creation - 5 worlds per player and 1000 overall by default, counted
  through a `pg` group so the count follows world process lifetime. Tunable
  with `world_max_per_player` and `world_max`. Over either, the caller gets
  `world.player_limit_reached` or `world.capacity_reached`.
- Matchmaker - reading or cancelling a ticket requires ownership, and a ticket
  carries only the player who submitted it, so nobody can be pulled into a
  match without consenting.

## Test coverage

Regressions for the above live under `test/`:

- `asobi_iap_SUITE.erl` - 12 cases: 10 Apple (missing fields, not configured,
  root not configured, invalid JWS, unsupported alg, missing `x5c`, invalid
  signature, chain validation failure, wrong bundle id, valid receipt) and 2
  Google (missing fields, not configured).
- `asobi_guest_SUITE.erl` - create or resume, wrong-secret rejection, upgrade
  and token revocation.
- `asobi_world_lobby_SUITE.erl` - per-player and global world caps.
- `asobi_matchmaker_api_SUITE.erl` - ticket ownership.
- `asobi_social_api_SUITE.erl` - chat history membership (DM, group,
  non-member).
- `asobi_dm_tests.erl` - DM length cap and empty-content rejection.
- `asobi_ops_auth_tests.erl` and `asobi_ops_token_tests.erl` - ops actor
  resolution and minted-token verification.
- `asobi_console_SUITE.erl`, `asobi_console_session_tests.erl` and
  `asobi_console_routes_tests.erl` - console login, session and CSRF, and the
  routes staying 404 while the console is off.

Run with `rebar3 ct,eunit`.

## Related

- [Threat model](security-threat-model.md) - the trust boundaries these controls sit on.
- [Known limitations](security-known-limitations.md) - what the runtime does not bound.
- [Operator console](console.md) - the console and ops credentials, and how to turn them on.
- [Sandbox model](security-sandbox.md) - the Lua side of the same story.
