# Known limitations (Lua sandbox)

The Lua sandbox closes a deliberate set of attack surfaces, documented in
[Sandbox model](security-sandbox.md). This page is the complement: what it does
not enforce. Plan the deployment around any of these that matter to you.

## Resource bounds

### The CPU bound is sampled, not exact

Every callback that runs in a child process carries three bounds: a wall-clock
timeout, a per-eval heap cap and a reduction budget. The reduction budget is
the CPU bound, and it is needed because a timeout bounds latency, not work: a
script can soak its whole wall-clock budget every tick and be killed at the
deadline each time, burning a scheduler indefinitely.

The budget is `max_reductions_per_ms` (50,000 by default) multiplied by that
callback's own wall-clock budget, so it scales with the callback: `tick` at 500
ms gets 25,000,000 reductions, a bot's `think` at 50 ms gets 2,500,000.
Overrun surfaces as `{error, reductions_exhausted}`, distinct from `timeout`
and `heap_exhausted`. As with the other two, the result is discarded and the
previous Lua state is kept; a match or zone is never torn down because one
callback overran. Set the rate to `0` to disable the check.

Two limits are worth knowing:

- The parent samples the child's reduction count every 10 ms
  (`?REDUCTION_POLL_MS`), so a script can overshoot by up to one interval's
  work before it is killed. The budget bounds sustained CPU, not the
  instantaneous peak.
- asobi does not use `luerl_sandbox:run/3`, which offers the same idea
  upstream. That function evaluates a chunk, whereas asobi's hot path is
  `luerl:call_function/3` against an already-loaded state, so the polling loop
  lives in `bounded_eval` in `asobi_lua_loader`, which had already spawned and
  monitored the worker.

`handle_input/3` is the exception: it runs inline in the calling process with
no child, so none of the three bounds apply. Its cost is a hung match or zone
process, not a supervisor event - see [handle-input is not a sandbox
boundary](security-trust-model.md#handle-input-is-not-a-sandbox-boundary).

### The heap cap is per eval, not per script

Each callback child carries `max_heap_size` with `kill => true`
(`max_heap_words`, 5,000,000 words by default), so one runaway allocation is
killed and surfaces as `{error, heap_exhausted}`. Nothing caps a script's
steady footprint: a state that sits just under the limit is copied into every
later eval, and the total across concurrent matches is unbounded. The decode
depth cap of 64 levels bounds recursion at the bridge boundary, not table size.

### The per-callback state copy is linear

Each bounded callback spawns a child that takes a full copy of the Luerl state.
Cost is linear in script-side allocation, so a script that deliberately builds
large stable tables makes every later callback pay the copy. Watch for
unexplained per-tick latency growth on long-lived matches.

## Deployment hygiene

### The release tree in the container is writable

The published image runs as the non-root `asobi` user, but its Dockerfile
chowns all of `/app` to that user and the image does not declare `--read-only`.
Mounting the game directory `:ro` is the operator's move, not the runtime's.
[Known limitations](security-known-limitations.md#the-release-tree-in-the-container-is-writable)
carries the run command that makes the rest of the tree read-only.

### Symlinks under the game directory

`require` refuses a symlink at resolve time, so a symlink at `<base>/foo.lua`
is not followed. That is defence in depth: keep the game directory mounted
read-only, and keep symlinks out of the build pipeline in the first place.

## Behavioural

### Mid-callback rollback is best-effort

If a callback is killed by its budget after it has already made a
side-effecting `game.*` call (`game.economy.debit`, say), the side effect
stands. The Lua state reverts to the previous tick; the asobi-side ledger does
not. Treat economy, leaderboard and storage mutations as best-effort committed.
For high-stakes flows, checkpoint state around the call so the next tick can
reconcile.

### A failing bot `think/2` falls back to the built-in AI

When `think/2` errors, `asobi_bot` substitutes the default AI and emits a
rate-limited warning, one line per bot per minute (`maybe_log_think_error`).
The match keeps running, so a broken bot script is visible in the logs but not
in the gameplay. Monitor for it if you rely on bot scripts.

## Logging

### The `require_failed` payload is truncated

When `luerl:do/2` rejects a `require`d file - non-Lua content, invalid syntax -
the compiler error list is cut to the first three entries plus a `truncated`
marker before it propagates. A binary file placed under the game directory by
mistake therefore cannot dump arbitrary bytes into the structured log pipeline.

## Related

- [Sandbox model](security-sandbox.md) - what the sandbox removes, replaces and bounds.
- [Trust model](security-trust-model.md) - what it is and is not a boundary against.
- [Known limitations](security-known-limitations.md) - the same for in-VM Erlang code.
- [Threat model](security-threat-model.md) - the node-level trust boundaries.
- [Auth and rate limiting](security-auth.md) - the request-side bounds.
