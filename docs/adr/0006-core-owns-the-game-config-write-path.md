# ADR 0006: Core owns the game-config write path

Date: 2026-08-04

## Status

Accepted.

## Context

The Lua config loader wrote asobi's own application environment directly.
`asobi_lua_config` set `guest_auth` and `game_modes` with
`application:set_env/3`, and core read those keys back in several places
(`asobi_game_modes`, `asobi_matchmaker`, `asobi_bot_spawner`,
`asobi_lua_config_watcher`, the guest endpoints). Even inside a single OTP
application that is one module reaching into another module's configuration
with no defined ordering: nothing said who writes, who wins, or when.

The mode registry made that concrete. The write was:

```erlang
Merged = maps:merge(Existing, Modes),
application:set_env(asobi, game_modes, Merged)
```

"New wins, nothing is ever removed", against the single key the operator also
configures. Two consequences, both wrong:

- **A deleted mode lived forever.** Drop `ctf` from `config.lua`, reload, and
  `ctf` was still in the registry, still matchable, still spawning matches from
  the previous definition, until the node restarted.
- **A bundle overwrote operator config.** A mode declared in the operator's
  `sys.config` was silently replaced by a same-named mode from a game bundle -
  and the config watcher does that on every mode-shape edit, not just at boot.

`guest_auth` had the same shape of problem in reverse: it is legitimately
game-declared (ADR 0004), but the loader chose both the value and the moment it
landed, so the ordering rule lived in the caller rather than in core.

## Decision

Core owns the write path. `asobi_game_config` is the only module that writes
these keys; a loader derives a config term and hands it over:

```erlang
asobi_game_config:apply_config(#{guest_auth => true, modes => Modes})
```

**Modes are two layers in two keys, never one merged key.**

1. `game_modes` - the operator layer, from `sys.config`. asobi never writes it.
2. `script_game_modes` - the script layer, the complete set the currently
   loaded game declares. `apply_config/1` replaces it wholesale.

`asobi_game_config:modes/0` composes them, in that order: script modes first,
operator modes overlaid on top. Every reader in core goes through `modes/0`;
none reads the raw keys.

**Write order inside `apply_config/1`:** `guest_auth` first, then the modes. A
key absent from the term is not written, which is how
`asobi_lua_config:reload_game_modes/0` refreshes mode shape from the watcher
without touching auth posture at runtime.

`guest_auth` is replaced rather than merged: it is the game's half of ADR
0004's two-key AND, and the operator's half is the pepper, not the flag.

## Consequences

- **A removed mode is actually removed.** The script layer is a replacement, so
  the registry always matches what the game currently declares. A pure-Erlang
  deployment is unaffected: with no game scripts the script layer is empty and
  `sys.config` is the whole registry.
- **Operator config is authoritative.** A `sys.config` mode wins a name clash
  and cannot be dropped by a bundle. A game author cannot redefine an
  operator's mode by picking its name - the same trust direction ADR 0004
  established for guest auth.
- **One writer, one documented order.** Ordering questions have one answer in
  one module instead of being implied by call order in a loader.
- **Loaders stay loaders.** `asobi_lua_config` reads Lua and returns a config
  term; `asobi_engine`'s bundle loader keeps calling
  `asobi_lua_config:maybe_load_game_config/0` and inherits the new semantics
  with no change. A future non-Lua config source implements the same term.
- **`game_modes` is no longer the whole picture.** Anything reading the raw
  app-env key sees only the operator layer. In-tree readers were moved to
  `asobi_game_config:modes/0`; out-of-tree code that reads the key directly
  must do the same.
