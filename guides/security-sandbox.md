# Sandbox model

asobi runs every Lua script in a hardened Luerl state. Sandbox construction
lives in `asobi_lua_loader:new/1` and `asobi_lua_loader:init_sandboxed/0`.

## Removed from the global environment

These standard-library entries are erased (`strip_dangerous_globals/1` sets
them to `nil`, which removes the key from the underlying table) so a script
cannot reach them:

- OS escape hatches - `os.execute`, `os.exit`, `os.getenv`, `os.remove`,
  `os.rename`, `os.tmpname`
- Code loading - `dofile`, `loadfile`, `load`, `loadstring`
- I/O - the whole `io` library
- Package machinery - the whole `package` library, plus the default `require`
- Unstructured logging - `print` and `eprint`. Luerl's versions bypass the
  structured logger and write straight to BEAM stdout. Use
  `game.log(level, message[, meta])`, which routes a structured, size-bounded
  line through the host logger behind a rate limit (per match or zone, plus a
  node-wide backstop). See the Logging section of the Lua scripting guide.

`os.clock`, `os.date`, `os.difftime` and `os.time` stay, so games can timestamp.

## Replaced

`require/1` is asobi's own. A name must match
`[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)*` - letters, digits and
underscores, with `.` separating segments. `../foo`, `/etc/passwd`, `foo/bar`,
`42` and `''` are all rejected, and the validator runs with the
`dollar_endonly` flag so `require("foo\n")` does not slip past the anchor. The
resolver joins the validated name to the directory of the loaded script
(`require("bots.chaser")` resolves to `<base>/bots/chaser.lua`) and reads it
with `file:read_file/1`. A symlink at the resolved path is refused before the
read. Results are cached in the state's `_ASOBI_LOADED` table, which
`asobi_lua_reload` clears on hot-reload so a changed module is picked up.

`math.random` dispatches to `rand:uniform`. All three upstream forms work: no
argument returns a float in `[0, 1)`, `math.random(n)` returns an integer in
`[1, n]`, and `math.random(a, b)` returns an integer in `[a, b]`. An empty
interval raises a proper Lua error, so `pcall` traps it.

`math.sqrt` dispatches to `math:sqrt/1`, and negative input returns `0.0`
rather than crashing the process (upstream Lua returns NaN).

## Per-callback budgets

Every Lua callback the bridges call runs in a child process with three bounds:
a wall-clock timeout, `max_heap_size` with `kill => true`, and a reduction
budget. A runaway script - `while true do end`, deep recursion, a huge
allocation - is killed, the parent logs a warning and keeps the previous Lua
state, and the match or zone carries on. Failures surface as
`{error, timeout}`, `{error, heap_exhausted}` or `{error, reductions_exhausted}`.

The budgets are per callback: see the [trust
model](security-trust-model.md#per-callback-budgets) for the full table and
where each macro lives.

`handle_input/3` is the exception. It runs inline in the calling process, so
none of the three bounds apply to it. See [what that
costs](security-trust-model.md#handle-input-is-not-a-sandbox-boundary).

The same wrapper covers the three places script-author-controlled code is
evaluated rather than called:

| Path | Module | Budget |
|---|---|---|
| Initial script body | `asobi_lua_loader:new/3` | the caller's init budget: 1000 ms for a match, 2000 ms for a world, 5000 ms when a zone VM boots |
| Hot-reload | `asobi_lua_reload` (`?RELOAD_TIMEOUT_MS`) | 5000 ms |
| Config manifest | `asobi_lua_config` (`?CONFIG_TIMEOUT_MS`) | 2000 ms |

So a `while true do end` at the top of `match.lua` cannot hang application
start or the match process.

## Cross-script isolation

Each match and each zone gets its own Luerl state. Globals, modules and the
require cache live inside that state, and no table reachable from script code
crosses a match boundary.

## Atom exhaustion

`asobi_lua_api`'s `safe_to_atom` helper and the `terrain_provider` decoder both
use `binary_to_existing_atom/1`, so a Lua-supplied string cannot inflate the
global atom table. The terrain provider module is additionally matched against
an explicit allowlist, so a script cannot dispatch into an arbitrary loaded
module even when the atom already exists; a name outside the list is refused
with a `terrain_provider_not_allowed` warning.
`asobi_lua_sandbox_tests:atom_count_stable_under_unknown_keys_test/0` pins the
atom-table property, and `asobi_lua_world_tests` pins the allowlist.

The default list is `asobi_terrain_flat` and `asobi_terrain_perlin`, read
through `asobi_lua_env:get_env(terrain_providers, ...)`.

## Decode depth cap

`asobi_lua_api`'s deep-decode helper recurses over Lua-side tables with a depth
cap of 64 levels; an over-deep subtree is replaced with the atom `too_deep`. A
script returning a 100k-deep table from a callback cannot blow the parent
process heap.

## Related

- [Trust model](security-trust-model.md) - what this sandbox is and is not a boundary against.
- [Known limitations (Lua)](security-lua-known-limitations.md) - what it does not enforce.
- [Threat model](security-threat-model.md) - the node-level trust boundaries around it.
- [Known limitations](security-known-limitations.md) - the same for in-VM Erlang code.
- [Auth and rate limiting](security-auth.md) - the request-side bounds.
