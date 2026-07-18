# 4. Guest auth is declared by the game; only the pepper is operator-injected

Date: 2026-07-18

## Status

Accepted

## Context

Anonymous guest auth (`POST /api/v1/auth/guest`, ADR 0002) is opt-in. Turning it
on needs two things:

1. a **toggle** — does this deployment offer no-account play?
2. a **verifier pepper** — a >= 32-byte secret mixed into the device-secret HMAC.

`guest_enabled/0` already gates on both: `guest_auth == true` AND a valid pepper;
a shorter/empty/absent pepper is treated as `undefined`, so it fails closed.

The first cut (asobi_lua #81, asobi_engine #60) sourced *both* values from OS env
vars (`ASOBI_GUEST_AUTH`, `ASOBI_GUEST_VERIFIER_PEPPER`), rendered into
`sys.config` at boot. That over-applied the env-var pattern: the toggle is a
game/deployment property that fits the existing game-Lua config mechanism
(`match_size`, `game_type`, `bots`, … declared as globals and read by
`asobi_lua_config`) far better than a coordinated pair of env vars. Only the
pepper is genuinely a secret that cannot live in a readable, sandboxed bundle.

## Decision

Split the toggle from the secret.

- **`guest_auth` is a boolean game global**, declared in the game's config script
  (`match.lua` for single-mode, `config.lua` for multi-mode) like any other game
  setting. A single reader, `asobi_lua_config:apply_guest_auth/1`, loads that
  script, reads the global, and `application:set_env(asobi, guest_auth, true)`
  when set. Both config-load paths call it: self-host
  (`asobi_lua_config:maybe_load_game_config/0`) and managed cloud
  (`asobi_engine`'s bundle loader), so behaviour is identical on both.
- **`guest_verifier_pepper` stays operator-injected** via
  `ASOBI_GUEST_VERIFIER_PEPPER` (env var -> secret). It is the one value that
  must not be committed to a bundle.
- **The `ASOBI_GUEST_AUTH` env var is removed.** Operator control collapses into
  "is a pepper present?", so a separate flag is redundant.
- `guest_enabled/0` is unchanged: **guest auth is on iff the game declared
  `guest_auth` AND the operator supplied a valid pepper.**

## Consequences

- **Better DX, correct ownership.** The toggle is declarative, versioned with the
  game, and hot-reloadable; the game author owns "I want guest play" without
  operator env plumbing. The operator owns only the secret.
- **Trust boundary enforced by construction.** A game can *ask* for guest play,
  but it is only actually on if the operator provisioned a pepper for that env.
  A third-party game author cannot unilaterally open an unauthenticated endpoint
  on the operator's infrastructure - mutual consent, enforced by the AND.
- **Per-env control via pepper presence.** The same bundle deploys to dev and
  prod; dev has no pepper (off), prod/demo has one (on). Per-environment
  behaviour without the toggle being per-env.
- **One operator lever.** The operator's only control is whether a valid pepper is
  present for a deployment; there is no separate flag to coordinate. How the pepper
  is supplied - an env var a self-hoster sets, or automated provisioning on a
  managed host - is outside this decision and out of scope for this library.
- **Self-host** operators are both parties: they set `guest_auth = true` in Lua
  and provide `ASOBI_GUEST_VERIFIER_PEPPER`.
- **Fails closed** everywhere: no game global -> `guest_auth` stays at its `false`
  default; no/weak pepper -> `pepper/1` returns `undefined`.

Supersedes the env-var toggle introduced in asobi_lua #81 / asobi_engine #60
(the pepper env var is retained).
