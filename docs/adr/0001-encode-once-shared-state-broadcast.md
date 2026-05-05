# ADR 0001: Encode-once shared-state match broadcast

Date: 2026-05-05

## Status

Accepted. Shipped in asobi#117.

Retroactive ADR — written after the change merged. The decision was
worth recording because the API addition (a new optional behaviour
callback) is one we'll be tempted to extend or replace later.

## Context

`asobi_match_server` broadcasts the per-tick game state by calling
`Mod:get_state(PlayerId, GameState)` once per player and JSON-encoding
each result. At 200 players × 10 Hz that is 2000 calls/sec to
`Mod:get_state/2` plus 2000 `json:encode/1` calls. The zone path
(`asobi_zone:broadcast_deltas/3`) had already adopted an
encode-once-and-fanout pattern via `zone_delta_raw`; the match path had
no equivalent.

Many games — FFA shooters, racing, party games, watching-from-the-stands
modes — return the same payload to every player. For these, the
per-player shape is wasted work.

Some games — fog-of-war strategy, hidden-information card games, anything
with per-player privacy — genuinely need per-player filtering and cannot
adopt a shared payload without leaking information.

## Decision

Add an optional behaviour callback `get_state/1` to `asobi_match`:

```erlang
-callback get_state(GameState :: term()) -> SharedState :: map().
```

`asobi_match_server:broadcast_state/1` checks
`erlang:function_exported(Mod, get_state, 1)` at runtime per tick. When
true, it calls `get_state/1` once, JSON-encodes once, and ships the same
pre-encoded binary to every subscriber via a new `match_state_raw` message
that the WS handler emits as a text frame without re-encoding.

Both `get_state/1` and `get_state/2` are listed in
`-optional_callbacks([...])` so a behaviour module may export either —
not both. This loosens the contract slightly (a misbehaving module could
export neither and crash at runtime) in exchange for letting bridge
modules express their semantics naturally.

For Lua scripts the choice is opt-in via `state_strategy = "shared"` in
the match script's globals. asobi_lua_config propagates this as
`state_strategy => shared` in mode config; `asobi_game_modes` and
`asobi_matchmaker` resolve `{lua, Script}` + `state_strategy => shared`
to a separate bridge module `asobi_lua_match_shared` (see
`asobi_lua/docs/adr/0001`) instead of `asobi_lua_match`.

## Consequences

- Games whose `get_state` ignores `PlayerId` get an O(N) → O(1) reduction
  in `Mod:get_state` calls and `json:encode/1` calls per tick (200 → 1
  at 200 players). Smaller absolute win than expected because Luerl-eval
  CPU dominates encode CPU at this load — see `asobi_lua/docs/adr/0002`
  for the follow-up that actually moved the needle on tail latency.
- Backward compatible: existing modules exporting `get_state/2` keep
  the per-player path with no changes.
- Mirrors the existing `zone_delta_raw` pattern in `asobi_zone`. Reduces
  the number of distinct broadcast strategies a contributor has to learn.
- Convention is "export exactly one of `get_state/1` or `get_state/2`".
  The framework only checks `function_exported(Mod, get_state, 1)` and
  otherwise calls `Mod:get_state(PlayerId, GS)` blindly — a module that
  exports neither will crash at first tick. Documented in the behaviour
  module and in `guides/architecture.md`. No compile-time enforcement.

## Alternatives considered

- **Single `get_state/2` with a runtime "want shared" hint in GameState** —
  rejected because match state is opaque to the framework; reading a
  framework-defined key from user state breaks the abstraction.
- **A dedicated `is_shared_state/1` runtime callback** — would have let
  one bridge module expose both paths. Rejected for asobi as redundant
  with `function_exported/3`. asobi_lua needed it for a different reason
  and ended up using a separate bridge module instead (ADR 0001 in
  asobi_lua).
- **Always shared, deprecate per-player** — would break every existing
  game module. Per-player is also a real use case (privacy) that we don't
  want to push games to work around.
- **Make the framework compute deltas across ticks** — possible follow-up
  (the architecture-guardian's "fix #2"); orthogonal to the encode-once
  question because deltas still need to be encoded per recipient unless
  ALSO shared. Punted.
