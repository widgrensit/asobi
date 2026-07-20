# ADR 0002: Open player registration; asobi does not authenticate clients

Date: 2026-07-07

## Status

Accepted. Mitigations tracked in asobi#157 and asobi#158.

## Context

asobi's client-connect endpoint is public by design.
`/api/v1/auth/register`, `/login`, and `/oauth` carry `security => false`
(`asobi_router.erl`) — the only unauthenticated entry. A game client
knows only the backend URL; it embeds no app key, app id, or shared
secret.

Integrators recurrently ask: "how do we ensure only *our* game's SDK can
create a user?" That question has no referent in asobi's model. asobi is
single-tenant *by URL* — the endpoint URL **is** the game identity, one
deployment serves one game, and one game's registration flood cannot
reach another game's database. The tenant boundary is the deployment, not
a credential, so there is no "our game" to check a key against. "Prove
the client is ours" is a per-title concern, not a library one.

A web-verified competitive brief (Nakama, PlayFab, Photon, EOS, Firebase,
Supabase, Steam) is unanimous on two points:

- A secret shipped inside a downloadable client is not a secret and
  cannot prove client authenticity — it is extractable from the binary or
  the client's own traffic regardless of TLS or obfuscation.
- The only mechanism approximating "only my binary made this call" is
  OS-vendor attestation (Play Integrity, App Attest/DeviceCheck, Firebase
  App Check). It is native-iOS/Android-only, absent on web and desktop,
  and impractical for a self-hostable backend that ships no
  vendor-controlled client.

Every platform instead runs *layered* defence: delegated/platform
identity as the cost-at-the-door moat, attestation where the OS offers
it, proof-of-human friction, and rate limits + ban. Photon ships open by
default with an `AllowAnonymous` toggle operators flip before release;
Supabase pairs per-IP token-bucket quotas with optional
Turnstile/hCaptcha; EOS offers a device pseudo-account *or* JWKS-verified
identity, gated by config.

## Decision

Record that **open registration is a deliberate, correct default** for a
general-purpose, single-tenant, self-hostable, multi-engine backend, and
that **asobi will not attempt to authenticate the client application.**

Reframe the problem from "prove client authenticity" (unachievable, and a
per-title concern) to "bound the cost and blast radius of anonymous
registration" (generic, achievable, useful to every game). Under that
framing asobi provides operator-tunable primitives, all defaulting to
today's open behaviour:

1. **`registration => open | oauth_only | closed`** core config, default
   `open` (asobi#158). One enum, not two overlapping booleans. This is
   Photon's `AllowAnonymous`, correctly modelled. Precise per-path
   semantics, enforced at the three create branches via
   `asobi_registration:check/1`:
   - `open` — every create path mints players (password, oauth-first-time,
     guest-first-time). Current behaviour.
   - `oauth_only` — password registration is refused (`403`
     `password_registration_disabled`); delegated OAuth may still create
     players. **Guest signup is left to its own `guest_auth` toggle**
     (ADR 0004), not governed by this mode — guest is a separate delegated
     path with its own opt-in and caps.
   - `closed` — no new player rows via *any* public path (`403`
     `registration_closed`); existing players still authenticate (login,
     refresh, oauth-login of a known identity, guest-resume are untouched).
   An unrecognised value falls back to `open` and warns: locking real
   players out on a config typo is worse than the abuse a mode prevents.
2. **Cost-aware register rate limiting** — a refinement of the existing
   seki per-path limiter (`asobi_sup.erl`, `asobi_rate_limit_plugin.erl`),
   giving `register` its own bucket and gating the 100 000-iteration
   pbkdf2 behind a cheaper pre-check (asobi#157). Not a new subsystem.
3. **A pluggable pre-auth `asobi_client_gate` seam** on the auth routes,
   default `skip`. CAPTCHA/Turnstile/hCaptcha siteverify ships as its
   first *consumer*, **outside core** (asobi_engine or a contrib plugin),
   never coupling the public request path to an external SaaS (asobi#158).
4. **Delegated identity** (Steam ticket + OIDC/JWKS, already in core via
   `asobi_steam` + `nova_auth_oidc` + `asobi_oidc_config`) is the promoted
   strong moat. The only new work is accepting arbitrary custom JWKS
   issuers in `oidc_providers`, mirroring EOS's OpenID provider
   (asobi#158) — documentation and config, not architecture.

Attestation (Play Integrity / App Attest) is explicitly out of scope for
core. A deployer that needs it adds it at the app layer (asobi_engine),
where a vendor-controlled client exists.

## Consequences

- **asobi can never answer "did my official client make this call."** A
  permanent, deliberate ceiling — not a TODO. Deployers needing it add OS
  attestation at the app layer; it is unachievable for web/desktop.
  Anyone re-opening this must re-read the competitive brief first.
- **The default is OPEN.** Every deployment ships a publicly-writable
  register endpoint. Choosing the `registration` mode, rate limits, and an
  optional gate before production is a *deployment decision*, not a
  library guarantee — exactly why Photon documents flipping
  `AllowAnonymous` "before release". The guides must own this footgun.
- **Cost-based defence is probabilistic, not authenticating.** Rate
  limits, CAPTCHA, and pbkdf2-gating raise the cost of abuse; none prove
  authenticity, and all are defeatable (botnets and carrier-NAT beat
  per-IP; CAPTCHA farms beat proof-of-human). The only near-zero-junk moat
  is delegated identity, because it externalises cost and identity to a
  platform. Studios wanting clean accounts set `oauth_only`; they should
  not expect the password path to be junk-free.
- **The `asobi_client_gate` seam stays distinct from
  `asobi_auth_plugin`**: "is this traffic allowed in" versus "who is the
  player." Gate implementations must not read or emit player identity.

## Alternatives considered

- **Per-game client API key / shared secret in the SDK** — rejected: a
  secret shipped in a downloadable client is extractable and proves
  nothing, and it re-warps the single-tenant library with a per-app
  credential we already removed once (the `ak_`-as-client-key model).
- **Mandatory OS attestation (Play Integrity / App Attest) in core** —
  rejected: native-mobile-only, breaks web/Defold-web/desktop entirely,
  and needs a vendor-controlled client a self-hoster does not have.
  Available to deployers at the app layer instead.
- **Default to `oauth_only` or mandatory CAPTCHA** — rejected: breaks the
  shipped `examples/` quickstarts and `asobi_register_bench` (headless
  username/password) and destroys first-run DX. Security posture must be
  opt-in per deployment.
- **Two booleans (`registration_enabled` + `require_oauth`)** — rejected
  as overlapping state; collapsed into the single `registration` enum.
