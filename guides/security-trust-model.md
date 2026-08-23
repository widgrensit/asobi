# Trust model

asobi treats the Lua scripts mounted at `/app/game` as trusted in the same
sense the `/app/bin/asobi` binary is trusted: you control what files end up
there. The [sandbox](security-sandbox.md) protects against incidental scripting
bugs - infinite loops, missed nil checks, atom exhaustion driven by player
input - and makes it harder for a compromised dependency or a `require`d module
to escape. It is not a defence against a deliberate, Erlang-aware adversary who
can write `/app/game/match.lua`.

## Documented properties

Three properties of the sandbox that are easy to re-derive wrongly, with where
to check them.

### Metatables cannot recover a stripped function

`strip_dangerous_globals/1` in `asobi_lua_loader` sets each dangerous key to
`nil`, and Luerl's `set_table_key_key/4` erases the entry from the underlying
dict rather than storing a nil. So `setmetatable(_G, ...)` and
`setmetatable(os, ...)` remain allowed, and an `__index` metatable does
intercept lookups for the now-absent keys - but the Erlang function references
for `os.execute` and the rest lived only in the dict entry that was erased.
Nothing else in the Luerl state holds them, so there is no Lua-reachable path
back to them.

### `_ASOBI_LOADED` is visible to script code

The require cache is installed as a global. A script can iterate it, mutate it
or delete entries. There is no privilege boundary inside a single Luerl state,
so this is by design: cross-match isolation comes from each match owning its
own state, and a script that clobbers its own cache only denies itself.
`lookup_loaded` in `asobi_lua_loader` turns a clobbered cache into a clean Lua
error rather than a `case_clause` crash.

### `terrain_provider` cannot inflate the atom table

A script returning `{ module = "<name>", ... }` from `terrain_provider/1`
cannot mint an atom: the bridge uses `binary_to_existing_atom/1`. It also
requires the module to be on an allowlist, so naming an unrelated loaded module
(`gen_server`, `rpc`) is rejected with a `terrain_provider_not_allowed`
warning. The default is `asobi_terrain_flat` and `asobi_terrain_perlin`, read
through `asobi_lua_env:get_env(terrain_providers, ...)`.

## Per-callback budgets

Almost every Lua callback runs inside a child process spawned by the
`bounded_eval` helper in `asobi_lua_loader`, with a wall-clock timeout,
`max_heap_size` with `kill => true`, and a reduction budget. A runaway loop or
allocation kills
the child, the parent gen_server sees `{error, timeout | heap_exhausted |
reductions_exhausted}`, and the match or zone continues on its previous state.

| Callback | Bridge | Bounded | Budget |
|---|---|---|---|
| `init/1` | match, world | yes | 1000 ms match, 2000 ms world |
| `generate_world/2` | world | yes | 5000 ms |
| `tick/1`, `zone_tick/2`, `post_tick/2` | match, world | yes | 500 ms |
| `join/2`, `leave/2` | match, world | yes | 200 ms |
| `get_state/{1,2}` | match, world | yes | 100 ms |
| `spawn_position/2` | world | yes | 100 ms |
| `vote_requested/1`, `vote_resolved/3` | match | yes | 200 ms |
| `phases/1` | match, world | yes | 1000 ms match, 2000 ms world |
| `on_phase_started/2`, `on_phase_ended/2` | match, world | yes | 200 ms |
| `on_zone_loaded/3`, `on_zone_unloaded/3` | world | yes | 200 ms |
| `spawn_templates/1` | world | yes | 2000 ms |
| `on_world_recovered/2` | world | yes | 2000 ms |
| `terrain_provider/1` | world | yes | 2000 ms |
| bot `think/2` | bot | yes | 50 ms |
| `handle_input/3` | match, world | **no** | see below |

The macros are not all in one place. Match budgets are `?*_TIMEOUT` in
`asobi_lua_match.erl` and world budgets are `?*_TIMEOUT` in
`asobi_lua_world.erl`, but `get_state/1` on the shared-state path has its own
`?GET_STATE_TIMEOUT` in `asobi_lua_match_shared.erl`, and the bot `think`
budget is a literal `50` at the call site in `asobi_bot.erl` rather than a
macro. Grep for `asobi_lua_loader:call(` if you need the authoritative set.

## The anchors are written past `_G`'s metatable

asobi holds Luerl references between callbacks, and Lua's root set is `_G`, the
stack and the live call frames - so a reference Erlang is carrying is reachable
only while something roots it. There are two anchors:

- `game_state`, rooted for the duration of a collection.
- The entity map, rooted for the duration of an input batch
  (`handle_input_batch/2`). This one is live **while your script runs**, which
  the next section explains.

Both are written **raw**, past any metatable the script has installed on `_G`.

That matters because `setmetatable(_G, ...)` is permitted (above), and the
metamethod-honouring setter would make asobi's own bookkeeping write run script
code on the zone, world or match process itself - outside the spawned child, so
with no wall-clock budget, no reduction budget and no heap cap. A `__newindex`
that never returns would wedge that process permanently; an ordinary
strict-globals `__newindex` that raises would make every collection silently
fail while the collector reported itself healthy. Neither is reachable: the raw
write runs no Lua and cannot fail.

The collector's anchor is cleared again before the callback runs, so a script
never observes that one. The batch anchor is different and deliberately so: it
has to stay rooted across the calls it protects, so a script **can** see
`__asobi_ref_anchor` in `pairs(_G)` and can clear it. Clearing it does not
corrupt anything. asobi re-checks the anchor after every call with a raw read -
which a `__index` metamethod cannot spoof, for the same reason the write cannot
be intercepted - and a batch whose anchor has gone abandons the tick's inputs
and hands the zone back the entity map it started with. The cost of tampering
falls on the script that tampered.

## handle-input is not a sandbox boundary

`handle_input/3` is the one callback that does not spawn-isolate. At realistic
input rates - one tick times N players times the message rate - the per-call
spawn cost dominated the actual Lua work: roughly 30 to 50 microseconds of
spawn, monitor and heap-cap setup against 50 to 200 microseconds of input
handling. Removing the wrapper recovered measured tail-latency wins at 200
players and 10 Hz input.

What that costs is worth stating precisely, because it is not a supervisor
event. Input arrives as a cast and is queued; the queue is drained inside the tick,
by `apply_inputs/3` in `asobi_match_server` and in `asobi_zone`. There is no
`gen_server:call` behind it and no call timeout to trip. A
`while true do end` inside `handle_input` therefore hangs the match or
zone process indefinitely: the tick stops, no supervisor restart happens, and
every later call against that process times out in its own caller. Blast radius
is one match or one zone. Recovery is manual.

`game.zone.apply` is the one call that can send from inside `handle_input` into
a *different* process, so it carries its own bound rather than relying on the
caller having one: an event is capped at 4 KB and a caller at 64 sends per tick,
both spent on the sender before the term is copied. The receiving zone caps what
it queues as well (by count and by bytes), but that cap is only consulted once
the message has already arrived, so the sender-side one is what keeps the blast
radius at one zone. See [World server](world-server.md#seeing-across-a-seam).

So treat `handle_input/3` as a hot path for trusted-author scripts, not as a
boundary. Audit the inputs your script accepts, avoid dispatching on
attacker-controlled strings, and treat it the way you would an Erlang
`handle_call/3` you wrote yourself. Per-tick safety belongs in `tick/1`, which
still spawn-isolates and is the right place to enforce fairness across players.

## Related

- [Sandbox model](security-sandbox.md) - what the sandbox removes, replaces and bounds.
- [Known limitations (Lua)](security-lua-known-limitations.md) - what it does not enforce.
- [Threat model](security-threat-model.md) - the node-level trust boundaries.
- [Known limitations](security-known-limitations.md) - the same for in-VM Erlang code.
- [Auth and rate limiting](security-auth.md) - the request-side bounds.
