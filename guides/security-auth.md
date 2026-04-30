# Authentication & rate limiting

This guide documents how asobi authenticates clients, validates
purchases, and bounds the brute-force surface. For the higher-level
trust assumptions see [Threat model](security-threat-model.md).

## Session bearer tokens

Every authenticated route is gated by `asobi_auth_plugin:verify/1`,
which expects an `Authorization: Bearer <token>` header. Tokens are
issued by `nova_auth_session:generate_session_token/2` after a
successful `register/1`, `login/1`, `refresh/1`, or OAuth flow. The
plugin attaches `auth_data => #{player_id => Id, ...}` to the request
map — controllers should pattern-match on that rather than parsing the
header themselves.

Tokens are stored in `asobi_player_token` and revocable via
`nova_auth_session:delete_session_token/2`.

## Apple StoreKit 2 JWS verification

`asobi_iap:verify_apple/1` parses an Apple-signed JWS receipt and
verifies it end-to-end:

1. Header `alg` is required to be `ES256`. Other algorithms are
   rejected.
2. The `x5c` chain is decoded (DER-encoded certificates, base64'd in
   JWS order: leaf → intermediate → root).
3. The chain is validated against a configured Apple Root CA via
   `public_key:pkix_path_validation/3`. Operators ship the root in
   `priv/apple_root_ca.pem` (or override the path via
   `application:get_env(asobi, apple_root_ca_path, ...)`).
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

## Per-route rate limits

`asobi_rate_limit_plugin` is wired as a `pre_request` plugin in
`config/{dev,prod}_sys.config.src`. It selects a Seki limiter group
based on the request path:

| Path prefix | Limiter | Default limit (req/sec/IP) |
|-------------|---------|----------------------------|
| `/api/v1/auth/*` | `asobi_auth_limiter` | 5 |
| `/api/v1/iap/*` | `asobi_iap_limiter` | 10 |
| everything else | `asobi_api_limiter` | 300 |

The auth limiter is the brute-force gate: a 5/sec cap plus the bcrypt
cost on `nova_auth_accounts:authenticate/3` makes online password
guessing infeasible at internet scale. Operators can override the
limits via the `asobi, rate_limits` env in their sys config:

```erlang
{rate_limits, #{
    auth => #{limit => 10, window => 1000},
    iap  => #{limit => 20, window => 1000},
    api  => #{limit => 600, window => 1000}
}}
```

The dev / test sys config bumps all three to 1000 because CT bursts
register/login calls against `127.0.0.1` and the production-default
auth cap would fail the suites.

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
- **Matchmaker** — party entries that don't match the requester are
  silently dropped; ticket reads / cancellations require ownership.

## Test coverage

Regressions for the items above live under `test/`:

- `asobi_iap_SUITE.erl` — Apple JWS happy path + 14 negative cases
  (bad alg, missing x5c, swapped signature, expired cert, untrusted
  root, …).
- `asobi_world_lobby_SUITE.erl` — F-9 per-player + global world caps.
- `asobi_matchmaker_api_SUITE.erl` — F-7/F-8 party consent + ticket
  ownership.
- `asobi_social_api_SUITE.erl` — F-10 chat history membership (DM,
  group, non-member denial).
- `asobi_dm_tests.erl` — F-11 length cap, empty-content rejection.

Run with `rebar3 ct,eunit`.
