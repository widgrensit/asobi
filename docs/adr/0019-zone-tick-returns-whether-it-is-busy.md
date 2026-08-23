# ADR 0019: `zone_tick/2` returns whether its zone is busy

Date: 2026-08-23

## Status

**Accepted, and shipped.** Supersedes
`docs/adr/0018-zone-busy-vetoes-demotion.md`, which shipped the same intent
through a `zone_busy/1` callback and a `_keep_hot` field on the zone state. Both
are removed. ADR 0016 stands.

`_keep_hot` existed only in v0.97.0, released hours earlier on 2026-08-22, so
nothing had time to depend on it.

## Context

ADR 0018 gave a game a way to say "this zone has work asobi cannot see", so an
entity-less wave spawner would not be demoted to `cold_tick_divisor`. Its
central argument was cost: asobi consults the answer on every idle tick, so a
Lua *callback* would add one marshalled crossing per tick to exactly the zones
ADR 0016 exists to make cheaper. It therefore chose a field, `_keep_hot`, read
with one `get_table_key`, on the reasoning that "one table read is affordable; a
second callback is the disease".

**That reasoning rested on a false premise, and a retrospective security review
found it.** `luerl:get_table_key/3` is not a raw read. When the key is absent
and the table has an `__index`, `luerl_emul:get_table_key/3` calls the
metamethod (`luerl_emul.erl:167`). `_keep_hot` is absent from almost every zone
state, so that was the *ordinary* path, not an edge case - and the metamethod ran
inline on the zone `gen_server`, with no wall-clock timeout, no `max_heap_size`,
no reduction budget and the whole `game.*` API in scope.

`setmetatable(zone_state, Zone)` with a function `__index` is ordinary OOP Lua.
It needed no adversary. Measured on the shipped build: a metamethod looping
2,000,000 times cost 345 ms on the zone process, and `while true do end` never
returned from `handle_cast` at all - the world ticker kept casting into a
mailbox that never drained, with no supervisor intervention because the process
was neither dead nor idle.

`guides/security-trust-model.md` names `handle_input/3` as the single
unbudgeted callback. ADR 0018 silently added a second entry point, at tick
cadence, and did not amend that guide.

Two further problems with the field shape, independent of the security one:

- **A field latches; a value cannot.** `_keep_hot` persists in the Lua table
  until overwritten, so "vetoes forever" was the default failure of anyone who
  set it at the start of a wave and forgot to clear it.
- **The two halves did not agree.** `asobi_zone` failed safe (keep hot) on a
  raise; the Lua bridge caught everything and returned `false`, so it failed
  *cold and silent*, and `bad_zone_busy` telemetry was unreachable for every Lua
  game. The guides promised the Erlang behaviour to a Lua-first audience.

## Decision

**The answer rides on `zone_tick/2`'s return value.**

1. `zone_tick/2` may return `{Entities, ZoneState, Busy :: boolean()}`. Lua
   scripts `return entities, zone_state, true`. The ordinary two-tuple means
   "not busy", so this is additive.
2. `asobi_zone:reclassify/1` runs immediately after `zone_tick/2` in the same
   `handle_cast`, so the value is wanted at exactly the instant the callback
   already returns. **Nothing is read to obtain it**, which is what makes the
   metamethod class impossible rather than merely guarded.
3. Lua truthiness decides (`nil` and `false` are not busy), so returning a
   countdown works as well as returning a comparison. `_keep_hot` required a
   literal `true`, and `_keep_hot = 1` reading as "not busy" was a silent
   failure the guides actively invited.
4. Fail-safe stays "keep the zone hot" for a non-boolean, logged with the
   module's bounded formatter rather than an unbounded `~0p` of a game term.
5. **A busy zone is not hibernated and not reaped.** ADR 0018 accounted for
   neither: an entity-less zone at full rate hibernates every tick, which is a
   full-sweep GC of the whole Luerl state per tick, and the idle sweep would
   still tear the zone down mid-countdown at `zone_idle_timeout`.

## Consequences

- The unbudgeted script-execution path is gone, not bounded. There is no read,
  so there is no metamethod, in either VM mode.
- One less magic field, and no Erlang/Lua asymmetry: both halves are one return
  value with one meaning.
- A veto cannot latch by accident. It must be produced on the tick it applies to.
- `zone_tick/2`'s contract widens. A game module that returns a three-tuple on
  an older asobi gets a `badmatch` and a dead zone, so this is forward-only.
- `guides/security-trust-model.md`'s statement that `handle_input/3` is the only
  unbudgeted callback is **still wrong, and this bullet was wrong when written.**
  Removing `_keep_hot` removed the entry point this ADR added, but ADR 0017 had
  already added another: `handle_effects/2` also goes through
  `asobi_lua_loader:call/3` (`asobi_lua_world.erl:395`). The guide named one
  callback until widgrensit/asobi#550. Left in place rather than quietly edited,
  because this ADR accuses ADR 0018 of exactly the sin it then committed itself -
  changing what the sandbox promises and not amending the guide.

## Alternatives considered

- **Keep `_keep_hot`, read it with `luerl_heap:raw_get_table_key/3`.** Rejected,
  though it does close the security hole: it keeps the latching failure, keeps
  the asymmetry, keeps the literal-`true` trap, and still costs a read per idle
  tick - a `gen_server` round trip under ADR 0015's `owned` mode. Removing the
  read is strictly better than making the read safe.
- **A `zone_busy/1` callback in both languages.** Rejected on ADR 0018's own
  cost argument, which is correct even though its conclusion was not: a Lua
  callback copies the whole Luerl state under the default `copy` mode.
- **Infer it from `zone_state` changing between ticks.** Rejected as in ADR
  0018: any script stamping a tick counter is permanently busy. Under `owned`
  the handle does not change when the state does, so the comparison is not
  merely wrong but impossible.
- **A zone-level timer reachable from Lua**, so `asobi_idle/1` could see the
  countdown itself. Not rejected - it is the better answer for the countdown
  *shape* specifically, and `asobi_entity_timer` already exists with no `game.*`
  surface. It does not cover conditional or accumulating work, so a veto is
  still wanted. Left as follow-up.
