# Known limitations (Lua sandbox)

The asobi_lua sandbox closes a deliberate set of attack surfaces
(documented in [Sandbox model](security-sandbox.md)). The list below is
the complement: properties the sandbox does **not** enforce. Operators
who care about any of these should plan their deployment accordingly.

## Resource bounds

### The reduction limit Luerl offers is not applied

A wall-clock timeout and a per-eval heap cap are the only resource
bounds asobi enforces. Neither bounds CPU: a script can soak its full
per-callback budget every tick without being throttled.

Luerl does expose a reduction limit. `luerl_sandbox:run/3` takes
`max_reductions` and kills the runner once its BEAM reduction count
passes the limit (luerl 1.5.1, the version asobi pins). asobi does not
use it, and it is not a drop-in:

- `luerl_sandbox:run/3` evaluates a chunk. asobi's hot path is
  `luerl:call_function/3` against an already-loaded state, which that
  entry point does not cover.
- The check polls the runner's reduction count from the parent on a
  fixed 100 ms interval. It bounds total work, not per-tick latency,
  and cannot fire sooner than one poll.

Tracked as [asobi#348](https://github.com/widgrensit/asobi/issues/348).

### The heap cap is per eval, not per script

Every callback runs in a child process carrying `max_heap_size` with
`kill => true` (`asobi_lua.max_heap_words`, 5,000,000 words by
default), so a single runaway allocation is killed and surfaces as
`{error, heap_exhausted}`. Nothing caps a script's *steady* footprint:
a state that stays just under the limit is copied into every later
eval, and the total across concurrent matches is unbounded. The decode
depth cap (64 levels) bounds recursion at the bridge boundary, not
table size.

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
