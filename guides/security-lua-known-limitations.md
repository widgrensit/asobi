# Known limitations (Lua sandbox)

The asobi_lua sandbox closes a deliberate set of attack surfaces
(documented in [Sandbox model](security-sandbox.md)). The list below is
the complement: properties the sandbox does **not** enforce. Operators
who care about any of these should plan their deployment accordingly.

## Resource bounds

### No reduction limit / hard CPU cap

The wall-clock timeout is the only resource bound today. A script can
soak its full per-callback budget every tick without being throttled.
Luerl upstream does not currently expose a "reduction limit" or
"process-bound state" knob; a future hardening pass may add a soft
budget on the Luerl scheduler.

### No per-script heap cap

Lua tables grow inside the BEAM process heap. A pathological script
that allocates 100 MB of tables and drops them every tick will pressure
the OS memory allocator. The decode depth cap (64 levels) bounds
recursion at the bridge boundary, but does not bound table *size*.

### Per-callback state copy cost is linear

Each timeout-wrapped callback spawns a child process that takes a full
copy of the Luerl state (`spawn(fun() -> call(..., St) end)`). Cost is
linear in script-side allocation. A script that intentionally builds
large stable tables forces every later callback to pay the copy. Watch
for unexplained per-tick latency growth on long-lived matches.

## Deployment hygiene

### The container release tree is writable

The shipped Dockerfile runs as the non-root `asobi` user but does not
declare `--read-only`. The README example mounts `/app/game` `:ro`;
that mode is the **operator's** responsibility, not the runtime's. We
recommend `docker run --read-only --tmpfs /tmp` and chowning only
`/app/game` to the runtime user (the rest of `/app` should stay
root-owned + read-only).

### Symlinks under the game dir

`require` rejects symlinks at resolve time, so a misplaced symlink
under `<base>/foo.lua` no longer slips through. This is defense in
depth: keep the game dir mounted read-only and the build pipeline
should not produce symlinks in the first place.

## Behavioural

### Mid-callback rollback is best-effort

If a callback is killed by its wall-clock timeout *after* it has
already issued a side-effecting `game.*` API call (e.g.
`game.economy.debit`), the side effect persists. The Lua-side state
reverts to the prior tick but the asobi-side ledger does not. Treat
economy / leaderboard / storage mutations as **best-effort committed**.
For high-stakes flows, checkpoint state before/after the API call so
the next tick reconciles, or wrap mutations in a transactional helper
tagged with the call's ref.

### Bot `think/2` errors fall back to the built-in default AI

A rate-limited `logger:warning` is emitted (one line per bot per
minute) when the fallback fires so persistently-broken scripts are
visible — see the `maybe_log_think_error` helper in `asobi_bot`.
Operators who rely on bot scripts should still monitor behaviour
externally; a silent fallback bot will keep playing the match without
ever calling your custom AI.

## Logging

### `require_failed` error payload is truncated

When `luerl:do/2` rejects a `require`'d file (non-Lua content,
syntactically invalid Lua), the compiler error list is truncated to the
first three entries before propagating. This prevents a binary file
mistakenly placed under the game dir from dumping arbitrary bytes into
the structured log pipeline.
