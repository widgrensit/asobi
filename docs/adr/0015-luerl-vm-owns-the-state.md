# ADR 0015: The Luerl VM owns the state; callbacks stop copying it

Date: 2026-08-21

## Status

**Proposed. Nothing implemented.** This records a decision to be taken, not one
taken. The evidence is a test-only spike
(`test/asobi_lua_vm_spike.erl`, `test/asobi_lua_vm_spike_bench.erl` on branch
`spike/lua-vm-process`, which is deliberately not merged - the bench asserts
nothing and would add eight seconds to every CI eunit run); no `src/` module
has been moved onto this shape.

asobi#536 shipped separately and is not this ADR. That change made the eval
heap budget mean what it says and made the state size observable. It did not
remove the copy, and this ADR is about the copy.

Two things its review turned up that bear directly on the decision below, and
which are recorded here because they change the shape of the argument:

- **The old absolute heap cap never bounded the persistent state.** It killed
  the eval *worker*; the state lived in the parent gen_server and survived the
  kill untouched. A 690 MB state was 690 MB before and after. So there is no
  ceiling being given up here - there never was one - and an absolute cap on
  the eval is not a backstop, it is a denial of service on the callback that
  reclaims nothing.
- **The bridge process already runs script code today**, in one place: the
  collector's `_G` anchor write. That was fixed by writing it raw, but it is a
  reminder that "the bridge never executes Lua" was already not quite true.

## Context

Every Lua callback with a wall-clock budget runs in a process spawned per call
(`asobi_lua_loader:bounded_eval/2`, `src/lua/asobi_lua_loader.erl:267`). The
spawn copies the closure into the new process, and the closure holds the whole
persistent Luerl state. So the sandbox that bounds a callback costs one full
copy of the state, in and back out, on every callback — every `zone_tick`,
every `post_tick`, every match tick, and every optional callback besides.

That cost is linear in the state and it is the dominant term. Measured here on
OTP 29 / luerl 1.5.1, for a callback that **does nothing at all**:

| state | `call/4` (worker + copy) | `call/3` (inline) | `luerl:gc/1` |
|---|---|---|---|
| 0.4 MB | 1.81 ms | 0.003 ms | 0.1 ms |
| 6 MB | 41.19 ms | 0.005 ms | 1.6 ms |
| 24 MB | 101.63 ms | 0.006 ms | 5.7 ms |
| 62 MB | 418.19 ms | 0.004 ms | 14.3 ms |

Roughly 7 ms per MB. The reporter on asobi#536 measured zone states of
400–690 MB with one peak at 4.5 GB, which is three to five seconds per
callback in copying alone — before the script runs a line. Their symptom was
"the world is empty" and "I can't connect", and it is fully explained by this
table: the zone does not fail, it just cannot finish a tick.

Two things follow that are worth naming, because they are easy to mistake for
tuning problems:

- **No heap budget can be both correct and absolute here.** asobi#536 fixed
  the budget by measuring it relative to the copied state, because an absolute
  cap bounds the state instead of the callback. But a relative budget means
  there is no static ceiling on the state at all, and the copy cost grows with
  it regardless. Bounding the state is not something the eval budget can do.
- **The copy is why several other things are shaped the way they are.**
  `handle_input/3` is exempt from the sandbox and runs inline on the zone
  process (`src/lua/asobi_lua_world.erl:300`) — the latency of a copy per
  input frame was never affordable. The per-zone ETS table holding the live
  spawn-template set exists only because a callback's `self()` is an ephemeral
  worker rather than the zone (`src/lua/asobi_lua_world.erl:183-197`). Both are
  workarounds for the copy, not for anything else.

The spike measures the alternative. Same shape as `zone_tick` — encode the
entity map, call the script, decode what came back — with the state held by a
`gen_server` and the bridge holding a pid plus opaque Luerl refs:

| state | copying (`call/4`) | owned VM | speedup |
|---|---|---|---|
| 0 MB | 0.97 ms | 0.113 ms | 9x |
| 3 MB | 5.04 ms | 0.170 ms | 30x |
| 12 MB | 25.86 ms | 1.028 ms | 25x |
| 37 MB | 67.69 ms | 0.820 ms | 83x |
| 75 MB | 205.77 ms | 0.336 ms | 613x |

The owned path is not faster in kind — it is **flat**. It is O(work) where the
current path is O(state). It also wins at a state of no size, because
spawn-copy-monitor costs more than a `gen_server` round trip on its own.

## Decision

**Invert the ownership. A per-bridge Luerl VM process holds the state; the
bridge holds a pid and opaque refs, and every `luerl:*` operation becomes a
small message to the process that owns the state.**

1. A `gen_server` per bridge (one per zone, one per world, one per match) owns
   `lua_state`. It is supervised alongside the bridge and dies with it.
2. `asobi_lua_world`, `asobi_lua_match` and `asobi_lua_api` stop holding
   `lua_state` and stop calling `luerl:*` directly. `game_state` stays what it
   is today — a Luerl ref — and is passed back and forth as an opaque term,
   which is small.
3. `asobi_lua_loader:call/4`'s per-call spawn is removed. The wall-clock budget
   becomes the `gen_server:call` timeout; the heap and reduction budgets become
   process flags on the VM, where — for the first time — an absolute
   `max_heap_size` genuinely bounds the persistent state rather than the
   callback.
4. **A runaway callback costs the VM, not the tick.** This is the price and it
   is the whole argument. Today the thing killed is a throwaway, so a script
   that spins or allocates costs one tick and the zone carries on. Under this
   shape the only killable thing is the process holding the state, so a
   timeout, heap or reduction overrun kills it and the state has to come back
   from somewhere.
5. Where it comes back from differs by bridge, and the asymmetry is the part
   that needs a ruling:
   - **Zones already have the path.** `dump_zone_state/1` decodes `game_state`
     to a plain Erlang map and `restore_game_state/2` re-encodes it into a
     fresh VM (`src/lua/asobi_lua_world.erl:948-964`), and
     `maybe_restore_from_snapshot/1` (`src/world/asobi_zone.erl:316`) already
     rebuilds a zone from the DB snapshot on boot. A killed zone VM restarts
     into the last snapshot. What is lost is anything a script keeps outside
     `game_state` — module-level locals, upvalues, globals — which asobi has
     never promised to persist but has also never destroyed mid-match.
   - **Matches have no equivalent.** `asobi_match_server` holds `game_state` in
     the FSM and never persists it; matches are ephemeral by design. A killed
     match VM is a lost match. Today a runaway callback in a match costs one
     tick.
6. Selectable by config and **defaulting off** for at least one release, so the
   old path stays available while the new one takes real traffic.

## Consequences

- A Lua tick's cost stops tracking the size of the state. That is the entire
  point, and it is what makes a large-state game viable rather than merely
  diagnosable.
- **Every Luerl reference held across a call must be anchored, and this needs to
  be a stated contract before 0015 lands rather than reasoned about per site.**
  Decision item 2 makes "the bridge holds opaque refs and passes them back and
  forth" the normal shape, so what is today one value (`game_state`, anchored by
  `collect_state/1`) becomes many. `handle_input_batch/2` is the first of those,
  and the failure mode is worth stating precisely, because "nothing collects
  here" is the reasoning that produces it. luerl's root set is `_G`, the stack
  and the live call frames, so a table Erlang carries between calls is reachable
  only while some frame names it - and a script declaring
  `function handle_input(p, i)` when three arguments were passed drops it. A
  collection at that moment frees it, its slot returns to the free list, the
  next `luerl:encode/2` recycles it, and the held reference aliases that data.
  Reproduced during this PR: a zone's entire entity map came back as one
  player's input frame, which `asobi_zone` accepts (it is still a map) and the
  snapshotter persists.

  Three things close it, and only the last generalises. `collectgarbage` was
  reachable from Lua and has since been stripped from the sandbox
  (`guides/security-sandbox.md`), which removes the reachable path.
  `asobi_lua_loader:anchor_ref/2` roots the reference in a second raw `_G` slot
  alongside the collector's, and `ref_anchored/2` re-checks it after every call
  because `_G` is script-writable. Under 0015 the class is what matters: every
  ref crossing a call boundary needs the same treatment, which is why this
  belongs in the contract rather than in a fix.

  A second lesson from the same change, and the one that will matter more under
  0015: **the Luerl state being functional is a rollback primitive.** A batched
  `handle_input` hands the script the entity table itself, so an empty return
  could not "leave the entities alone" the way the per-input path does - there
  is no Erlang-side copy to fall back on. Reverting to the state from before the
  call reverts the heap the mutation lived in, at no cost. Anything under 0015
  that needs to undo a callback's effect without copying has the same tool.
- **The blast radius of a killed VM widens if `handle_input` is ever batched and
  budgeted.** The Consequences below reopen the `handle_input` sandbox exemption
  on the grounds that its reason is gone. If it comes back under a budget, note
  that a batched `handle_input` makes one bad input cost the whole tick's inputs
  rather than one, because the batch is a single callback.
- The `handle_input` exemption (ADR 0002 in the asobi_lua lineage) can be
  revisited, because the reason for it — a copy per input frame — is gone.
  Whether it *should* be is a separate decision.
- The per-zone ETS template table can go: a closure's `self()` becomes the VM
  process, which is stable for the zone's lifetime.
- `game.zone.spawn`'s self-cast deadlock hazard does **not** go away and may
  get sharper. The Lua now runs in a different process from the zone, but the
  zone is blocked in a `gen_server:call` to it, so a synchronous call back into
  the zone still deadlocks. Anything reaching back into the caller has to stay
  asynchronous or read shared state.
- One more process per zone. Worlds are lazy and zones are already one process
  each, so this doubles the per-zone process count. Cheap on the BEAM, but it
  is a number that shows up in `process_limit` sizing for large grids.
- Migration surface, counted on `main` at c160ddf: 51 direct `luerl:*` call
  sites outside the loader (world 16, api 11, config 10, match 7, reload 2,
  phases 1, bots 4), 97 references to `lua_state` threaded through bridge state
  maps, 31 `asobi_lua_loader:call` sites. `asobi_lua_config` is the one that
  may not need to move at all — it evaluates a manifest once at boot with no
  long-lived state.
- The wire is untouched and no game script changes. This is invisible to a
  script that behaves.

## Rejected alternatives

- **Leave it, and treat the copy as a documented property.** Rejected: at 7 ms
  per MB the property is not a cost, it is a ceiling on how large a game asobi
  can host, and asobi#536 shows an ordinary game reaching it with one player.
- **Run bounded callbacks inline on the owning process, unguarded**, as
  `handle_input` already does. Rejected: this is the same 4-orders-of-magnitude
  win with none of the guard back, and it silently upgrades a runaway script
  from "costs a tick" to "wedges the zone forever" with no kill available at
  all. The VM process keeps a kill switch; this throws it away.
- **Keep the copy and cap the state size instead**, refusing callbacks once the
  state crosses a threshold. Rejected: the threshold is a cliff the operator
  cannot act on mid-session, and a zone refusing to tick is the failure being
  fixed, arrived at deliberately.
- **Bound the eval with a Luerl trace hook** (`luerl:set_trace_func/2`) instead
  of process isolation, keeping the state in the bridge and running inline.
  Rejected on two counts: it stores a `fun` inside the Luerl state, which
  breaks any future checkpoint or snapshot of that state and crosses a module
  boundary with a closure; and the hook fires per call, per return and per
  line (`luerl_emul.erl:645,668,767`), which puts a `fun` call on the hot path
  of every statement a script executes. It also does not bound allocation.
- **Snapshot the state before each risky callback so a kill can roll back.**
  Rejected: the snapshot is a copy, which is the cost being removed. It would
  reintroduce it in full and buy only the rollback.
- **Raise `max_heap_words` until it converges.** Rejected on the reporter's own
  evidence: they ran 4x the default and the state still reached 400–690 MB. The
  state outruns any static number, which is why asobi#536 made the budget
  relative rather than larger.
