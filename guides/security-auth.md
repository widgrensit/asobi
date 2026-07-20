# Authentication & rate limiting

This guide documents how asobi authenticates clients, validates
purchases, and bounds the brute-force surface. For the higher-level
trust assumptions see [Threat model](security-threat-model.md).

## Session bearer tokens

Every authenticated route is gated by `asobi_auth_plugin:verify/1`,
which expects an `Authorization: Bearer <token>` header. Tokens are
issued by `nova_auth_refresh:generate_pair/2` (via
`asobi_auth_tokens:issue/2,3`) after a successful `register/1`,
`login/1`, `refresh/1`, or OAuth flow. The caller receives an access
token plus a single-use rotating refresh token. The plugin attaches
`auth_data => #{player_id => Id, ...}` to the request map — controllers
should pattern-match on that rather than parsing the header themselves.

On logout the presented access token is revoked via
`nova_auth_refresh:delete_access_token/2` (wrapped by
`asobi_auth_tokens:revoke_access/1`) so it cannot outlive the cache TTL.

## Apple StoreKit 2 JWS verification

`asobi_iap:verify_apple/1` parses an Apple-signed JWS receipt and
verifies it end-to-end:

1. Header `alg` is required to be `ES256`. Other algorithms are
   rejected.
2. The `x5c` chain is decoded (DER-encoded certificates, base64'd in
   JWS order: leaf → intermediate → root).
3. The chain is validated against a configured Apple Root CA via
   `public_key:pkix_path_validation/3`. The root is not bundled: operators
   point `apple_root_cert_path` (or `apple_root_certs`) at it, and
   verification returns `apple_root_cert_not_configured` if neither is set.
4. The signature on `<header>.<payload>` is verified with the leaf
   cert's public key. A bit-flipped signature, swapped signature, or
   any chain mismatch fails the verification.

Failures return `{error, Reason}` with a sanitised reason atom. The
controller (`asobi_iap_controller`) maps them to 400/401 responses
without leaking JWS internals to the client.

## Steam ticket validation

`asobi_steam:validate_ticket/1` validates a hex-encoded Steam session
ticket against the Steam Web API:

1. The ticket character class is enforced (`[0-9a-fA-F]+`, max 4096
   bytes). Anything else is rejected before any HTTP call.
2. All dynamic URL components (key, app id, ticket, steam id) are
   passed through `uri_string:quote/1` so an `&` or `=` in user input
   cannot inject query parameters into the Steam call.

The ticket validator is invoked from `asobi_oauth_controller` for
`provider = "steam"` flows.

## Guest device verifiers

Anonymous/guest auth (`asobi_guest_controller`) lets a device create a
player from a `{device_id, device_secret}` pair without credentials. It
is secured to leak nothing useful even if the identity table is dumped:

- **Fails closed.** The controller serves guest routes only when
  `guest_auth` is `true` **and** a `guest_verifier_pepper` is
  configured; otherwise every guest endpoint returns `403
  guest_auth_disabled`.
- **The device secret is never stored.** The database holds a
  *verifier*, not the secret. On creation the server draws a 16-byte
  salt from `crypto:strong_rand_bytes/1` and combines it with a
  server-side pepper (selected by key id) as
  `crypto:mac(hmac, sha256, Pepper, <<Salt/binary, Secret/binary>>)`.
  The result is stored in the identity's `provider_metadata`
  (`salt` / `key_id` / `verifier` / `revoked`, all base64).
- **Timing-safe comparison.** Resume verifies with
  `crypto:hash_equals/2` so a wrong secret can't be recovered by
  timing.
- **The pepper lives outside the database.** It is a keyed secret
  (env/secret manager), so a dumped verifier table is useless without
  it, and it is rotatable: add a new key id, point
  `guest_verifier_key_id` at it, and keep old key ids for the retention
  window so existing guests still resume.
- **Bounded input.** The secret must base64-decode to at least 32 bytes
  (under a fixed upper cap) and the `device_id` must be non-empty and
  at most 255 bytes, so an unauthenticated caller can't force
  multi-megabyte HMAC work.
- **Upgrade is compromise-recovery.** Claiming a guest
  (`/auth/guest/upgrade`) calls `nova_auth_refresh:revoke_all/2` to kill
  the entire token family a stolen device secret may have minted, then
  deletes the guest identity so the secret can no longer resume the
  now-claimed account.
- **Safe reaping.** The optional `asobi_guest_reaper` (off unless
  `guest_reap_after` is set) re-checks that a guest is still unclaimed
  *inside* its delete transaction, so a concurrent upgrade wins the
  race. The unlinked-guest cap reads a short-TTL cached count and fails
  closed if the count can't be read.

> #### Assurance level {: .warning}
>
> Treat guest accounts as low-assurance until they are upgraded. Anything
> valuable - purchases, competitive ranking, cross-device identity -
> should require a claimed account, not a guest session.

## Per-route rate limits

`asobi_rate_limit_plugin` is wired as a `pre_request` plugin in
`config/{dev,prod}_sys.config.src`. It selects a Seki limiter group
based on the request path:

| Path | Limiter | Default limit (req/sec/IP) |
|------|---------|----------------------------|
| `/api/v1/auth/register` | `asobi_register_limiter` | 3 |
| `/api/v1/auth/*` (login, refresh, ...) | `asobi_auth_limiter` | 5 |
| `/api/v1/iap/*` | `asobi_iap_limiter` | 10 |
| everything else | `asobi_api_limiter` | 300 |

`/api/v1/auth/register` gets its own tighter bucket (asobi#157): it runs
the password KDF (pbkdf2_sha256, see `pbkdf2_iterations`) as its only
cost gate, so sharing the login bucket let a signup flood both starve
honest logins and amplify server CPU. The dedicated 3/sec cap isolates
register and bounds the per-IP KDF cost. This is per-IP only; distributed
abuse is deferred to the pre-auth gate in asobi#158.

The auth limiter is the brute-force gate for login: a 5/sec cap plus the
pbkdf2_sha256 cost on `nova_auth_accounts:authenticate/3` makes online
password guessing infeasible at internet scale. Operators can override
the limits via the `asobi, rate_limits` env in their sys config:

```erlang
{rate_limits, #{
    auth     => #{limit => 10, window => 1000},
    register => #{limit => 5,  window => 1000},
    iap      => #{limit => 20, window => 1000},
    api      => #{limit => 600, window => 1000}
}}
```

The dev / test sys config bumps all three to 1000 because CT bursts
register/login calls against `127.0.0.1` and the production-default
auth cap would fail the suites.

## Client gate (pre-auth)

`asobi_client_gate` is a pluggable "is this traffic allowed in" seam on the
anonymous auth-create routes (`/auth/register`, `/auth/oauth`,
`/auth/guest`). It is distinct from `asobi_auth_plugin` ("who is the
player"): a gate carries **no** player identity - its return type is
deliberately narrow so an implementation cannot leak or forge identity.

```erlang
-callback verify(cowboy_req:req()) -> skip | {deny, Reason :: binary()}.
```

Wire an implementation with `{client_gate, my_gate_module}` in app env;
**unset is a no-op**, so bots, dedicated servers, CI, headless clients and
`asobi_register_bench` all keep working by default. `asobi_client_gate_plugin`
runs immediately after the rate limiter and before the password KDF, so a
denial (`403 registration_gate_denied`) never pays the pbkdf2 cost
(asobi#157), and a register flood is shed by the cheap in-memory limiter
before it can trigger an outbound siteverify.

A configured gate that **crashes or returns garbage fails closed** by
default (`403 client_gate_unavailable`) - a security control that silently
fails open is bypassable by knocking over the vendor. Trade strictness for
availability with `{client_gate_on_error, skip}`.

CAPTCHA / Turnstile / hCaptcha is the first *consumer* of this seam and
ships **outside** core (asobi_engine or a contrib plugin): a vendor-specific
external round-trip must not couple asobi's public request path to a SaaS.

## DDoS / DoS surface notes

These are the deliberate per-call upper bounds in the runtime that
exist purely to bound the cost of a single hostile request:

- **Cloud saves** (`/saves/:slot`) — body capped at 256 KB; per-player
  slot count capped at 10.
- **Storage** (`/storage/:collection/:key`) — `read_perm` /
  `write_perm` whitelisted to `["public", "owner"]`; arbitrary strings
  rejected with 400.
- **Inventory consume** — quantity range `[1, 1_000_000]`.
- **Leaderboard** `top` / `around` — `?limit` clamped to 100, `?range`
  to 50 (mitigates an O(N) ETS scan attack).
- **Chat history** — `?limit` clamped to `[1, 200]`; channel
  membership is enforced (DM participants, world joiners, group
  members).
- **DM send** — content capped at 2000 bytes; non-binary or empty
  content rejected.
- **Group chat / WS `chat.join`** — channel id namespaced
  (`dm:`, `world:`, `zone:`, `prox:`, `room:`); per-connection cap of
  32 simultaneously joined channels; idle channels stop after 60s
  with no live members.
- **Per-player world creation** — capped via pg group; default 5
  worlds per player, 1000 globally. Tunable via `world_max_per_player`
  / `world_max` env.
- **Matchmaker** — ticket reads and cancellations require ownership, so
  one player cannot read or cancel another's ticket. A ticket carries only
  the submitting player, so it cannot pull a non-consenting player into a
  match.

## Test coverage

Regressions for the items above live under `test/`:

- `asobi_iap_SUITE.erl` — Apple JWS happy path + 14 negative cases
  (bad alg, missing x5c, swapped signature, expired cert, untrusted
  root, …).
- `asobi_world_lobby_SUITE.erl` — F-9 per-player + global world caps.
- `asobi_matchmaker_api_SUITE.erl` — ticket ownership + party-not-accepted
  ownership.
- `asobi_social_api_SUITE.erl` — F-10 chat history membership (DM,
  group, non-member denial).
- `asobi_dm_tests.erl` — F-11 length cap, empty-content rejection.
- `asobi_guest_SUITE.erl` — guest create-or-resume, wrong-secret
  rejection, upgrade + token revocation.

Run with `rebar3 ct,eunit`.
