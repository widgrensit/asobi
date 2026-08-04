# Known limitations (Lua sandbox)

The asobi_lua sandbox closes a deliberate set of attack surfaces
(documented in [Sandbox model](security-sandbox.md)). The list below is
the complement: properties the sandbox does **not** enforce. Operators
who care about any of these should plan their deployment accordingly.

## Resource bounds

### The CPU bound is sampled, not exact

asobi enforces three resource bounds on every callback that runs in a
child process: a wall-clock timeout, a per-eval heap cap, and a
reduction budget. The reduction budget is the CPU bound - without it a
script could soak its full per-callback wall-clock budget every tick,
because the timeout bounds latency, not work.

The budget is `asobi_lua.max_reductions_per_ms` (50,000 by default)
multiplied by that callback's own wall-clock budget, so it scales with
the callback: `tick` (500 ms) gets 25,000,000 reductions, a bot's
`think` (50 ms) gets 2,500,000. Overrun surfaces as
`{error, reductions_exhausted}`, distinct from `timeout` and
`heap_exhausted`. As with the other two, the callback's result is
discarded and the previous Lua state is kept - a match or zone is never
torn down because one callback overran. Set the rate to `0` to disable
the check.

Two limits are worth knowing:

- The parent samples the child's reduction count every 10 ms, so a
  script can overshoot by up to one interval's work before it is
  killed. The budget bounds sustained CPU, not the instantaneous peak.
- asobi does not use `luerl_sandbox:run/3`, which offers the same idea
  upstream: it evaluates a chunk, whereas asobi's hot path is
  `luerl:call_function/3` against an already-loaded state. The polling
  loop lives in the `bounded_eval` helper in `asobi_lua_loader`
  instead, which already spawned and monitored the worker.

`handle_input/3` is the exception: per ADR 0002 it runs in the calling
process with no child, so none of the three bounds apply to it.

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
