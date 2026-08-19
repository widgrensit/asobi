# ADR 0014: An operator layer over the game's guest-auth declaration

Date: 2026-08-19

## Status

Accepted.

Amends ADR 0004 (which removed operator control of the flag) and ADR 0006
(which recorded `guest_auth` as replaced rather than layered).

## Context

ADR 0004 made `guest_auth` a game global and gave the operator a single lever:
supply a pepper, or do not. ADR 0006 kept that shape while moving the write
into `asobi_game_config`. Both assumed the game declares and the operator
consents.

A deployment that embeds asobi as an Erlang library breaks the assumption. It
ships no Lua bundle, so there is no script to declare anything, and
`asobi_lua_config:declared_config/1` derives `guest_auth => false` from the
missing entry point. That value was written to the same key the operator uses,
by an `asobi_sup` child, on every boot. `{guest_auth, true}` in `sys.config`
was therefore overwritten during the start that read it, with no error and no
warning, and `POST /api/v1/auth/guest` answered `403 guest.disabled` for ever
(asobi#494).

The operator lever ADR 0004 left in place did not help. The pepper is an AND,
so it can only keep guest auth off; nothing could turn it on for a deployment
with no game script to declare it.

The `false` write is not itself the bug and cannot simply be dropped. It is
what resets a stale `true` when a bundle is replaced by one that no longer
declares the global. The bug is that a derived value and an operator's value
shared one key.

## Decision

**Two keys and one reader, the way ADR 0006 already split the mode registry.**

1. `guest_auth` - the operator layer, from `sys.config`. asobi never writes it.
2. `script_guest_auth` - the script layer, what the currently loaded game
   declares. `apply_config/1` replaces it wholesale, including the `false` a
   missing or broken bundle derives.

`asobi_game_config:guest_auth/0` composes them. **The operator layer wins on
key presence, not on truth**: an operator `false` pins guest auth off against a
bundle declaring `true`, and an operator `true` survives a boot with no bundle
at all. Only omitting the key defers to the game.

| `guest_auth` | `script_guest_auth` | effective |
| --- | --- | --- |
| `true` | anything | `true` |
| `false` | anything | `false` |
| unset | `true` | `true` |
| unset | `false` or unset | `false` |

Anything that is not a boolean in the operator key pins guest auth off and does
not fall through to the game, so a typo cannot open the endpoint.

**The pepper AND is unchanged.** `asobi_guest_controller:enabled/0` is the one
place the whole gate is written down: the composed flag AND a pepper of at
least 32 bytes. ADR 0004's mutual consent still holds in the direction that
matters - a game author cannot open an unauthenticated endpoint on an
operator's infrastructure, because the operator can pin the flag off as well as
withhold the pepper.

## Alternatives rejected

**Let the game win, and give it a third state.** `read_global_bool/2` already
distinguishes "absent" from `false`; the loader collapses the two. Keeping the
distinction and letting a declared value outrank `sys.config` would fix
asobi#494 just as well, and it is the more natural reading of "the game
declares its own posture".

It fails wherever the person who writes the game and the person who runs the
server are not the same person. ADR 0004 assumed the operator could always
decline by withholding a pepper, but that is not a usable veto: the verifier is
keyed on the pepper, so withdrawing one leaves every existing guest unable to
authenticate. An operator who wants to close an unauthenticated endpoint needs
something reversible that a bundle cannot overrule, and the flag is it. On a
single-operator self-host the two models are indistinguishable anyway, so the
choice costs that deployment nothing.

**Keep one key and move the config load earlier in `asobi_sup`.** Changes what
every core child sees at boot in order to fix one key, and still leaves a
derived value and an operator's value fighting over it.

## Consequences

- **A pure-Erlang deployment can turn guest auth on.** The reported case works:
  `{guest_auth, true}` plus a pepper, no Lua anywhere.
- **The operator gains a kill switch.** `{guest_auth, false}` stops the
  endpoint without touching the pepper, so existing guests stay
  authenticatable. Note it also stops `asobi_guest_reaper` sweeping, since the
  reaper reads the same composed flag: retention pauses while the feature is
  off. `POST /api/v1/ops/players/guests/purge` is the manual lever meanwhile.
- **An existing `{guest_auth, ...}` in a `sys.config` becomes authoritative on
  upgrade.** It previously did nothing whenever a bundle loaded, so a key left
  behind after an experiment now decides the posture. Release-note material.
- **`guest_auth` is no longer the whole picture.** Anything reading the raw
  app-env key sees only the operator layer, exactly as ADR 0006 warned for
  `game_modes`. In-tree readers go through `asobi_game_config:guest_auth/0`;
  out-of-tree code must do the same. A loader that writes the raw key is now
  writing the operator's answer, and no later load can clear it.
- **The lever exists only where a `sys.config` is written.** A deployment that
  generates its configuration has to set the key deliberately; leaving it unset
  keeps the previous behaviour, where the game's declaration decides.
- **`registration` and `guest_auth` now layer identically**, and both differ
  from `modes/0` only in that a boolean has no per-key merge to do.
