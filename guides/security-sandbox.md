# Sandbox model

asobi_lua runs every Lua script in a hardened Luerl state. Sandbox
construction lives in `asobi_lua_loader:new/1` and
`asobi_lua_loader:init_sandboxed/0`.

## Removed from the global environment

The following standard-library entries are cleared (`= nil`) so a hostile
script cannot reach them:

- **OS escape hatches:** `os.execute`, `os.exit`, `os.getenv`,
  `os.remove`, `os.rename`, `os.tmpname`
- **Code loading:** `dofile`, `loadfile`, `load`, `loadstring`
- **I/O:** the entire `io` library
- **Package machinery:** the entire `package` library, plus the default
  `require`
- **Unstructured logging:** `print`, `eprint` — Luerl's defaults bypass
  the structured logger and write straight to BEAM stdout. Use
  `game.log(level, message[, meta])` instead: it routes a structured,
  size-bounded line through the host logger behind a rate limit (per
  match/zone plus a node-wide backstop), closing the two holes `print`
  was removed for. See the Lua scripting guide's "Logging" section.

`os.clock`, `os.date`, `os.difftime`, and `os.time` remain available so
games can timestamp.

## Replaced

- **`require/1`** is provided by asobi_lua. Names must match
  `[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)*` — letters, digits,
  underscores, with `.` separating segments. Names like `../foo`,
  `/etc/passwd`, `foo/bar`, `42`, or `''` are rejected. The validator
  uses the `dollar_endonly` regex flag so `require("foo\n")` does not
  slip through. The resolver joins the validated name to the directory
  of the script that was loaded (e.g. `require("bots.chaser")` →
  `<base>/bots/chaser.lua`) and reads the file with `file:read_file/1`.
  Symlinks at the resolved path are rejected before reading. Module
  results are cached in the Luerl state's private `_ASOBI_LOADED`
  table; `asobi_lua_match` clears that cache on hot-reload so changed
  modules pick up.
- **`math.random`** dispatches to Erlang's `rand:uniform`. Single-arg
  form returns an integer in `[1, N]`; no-arg form returns a float in
  `[0, 1)`. The two-arg `math.random(a, b)` form upstream Lua exposes
  is **not** supported.
- **`math.sqrt`** dispatches to Erlang's `math:sqrt/1`. Negative input
  returns `0.0` (upstream Lua returns NaN; Erlang would crash).

## Per-callback wall-clock limits

Every Lua callback the bridges call (init, tick, join, leave,
get_state, vote_requested, vote_resolved, generate_world,
phases, spawn_templates, on_phase_started/ended, on_zone_loaded/unloaded,
on_world_recovered, terrain_provider, spawn_position, post_tick,
zone_tick, bot `think`) runs in a child process with a wall-clock
budget. A runaway script (`while true do end`, deep recursion, huge
allocation) is killed when its budget elapses; the parent gen_server
logs a warning and continues with the previous state. Limits are tuned
per callback — init/generate_world get more time, per-tick callbacks
get less. See the `?*_TIMEOUT` macros in `asobi_lua_match.erl` and
`asobi_lua_world.erl`.

**`handle_input/3` is the exception: it is _not_ wall-clock-bounded.** It runs
inline for measured tail-latency wins at high input rates (ADR 0002), so a
`while true do end` there hangs the match until the gen_server timeout (5 s) and
the supervisor restarts the match — blast radius one match. It is not a sandbox
boundary; see the [trust model](security-trust-model.md#per-callback-isolation).

The same wall-clock wrapper is applied to the **initial script body**
load (`asobi_lua_loader:new/1`), the **hot-reload** path (in
`asobi_lua_match`'s reload helper), and the **config manifest**
evaluator (in `asobi_lua_config`). A `while true do end` at the top
of `match.lua` therefore can no longer hang application start or the
match gen_server.

## Cross-script isolation

Each match and each zone gets its own Luerl state. Globals, modules,
and the require cache live inside that state — there is no shared
table reachable from script code that crosses match boundaries.

## Atom exhaustion

`asobi_lua_api`'s `safe_to_atom` helper and `terrain_provider`
decoding both use `binary_to_existing_atom/1` so a Lua-supplied string
cannot inflate the global atom table. Additionally, the terrain
provider module name is matched against an explicit allowlist
(`asobi_terrain_flat`, `asobi_terrain_perlin` by default; configurable
via the `asobi_lua, terrain_providers` env) so a script cannot
dispatch into arbitrary loaded modules even if the underlying atom
already exists. There is a regression test in
`asobi_lua_sandbox_tests` that fails if the limit is widened.

## Decode depth cap

`asobi_lua_api`'s deep-decode helper recurses on Lua-side tables;
depth is capped at 64 levels and over-deep subtrees are replaced with
the atom `too_deep`. A malicious script returning a 100k-deep table
from a callback can no longer blow the parent process heap.
