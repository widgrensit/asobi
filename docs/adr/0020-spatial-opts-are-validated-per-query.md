# ADR 0020: A spatial option is validated against the query that will read it

Date: 2026-08-23

## Status

**Accepted, and shipped** in widgrensit/asobi#550.

## Context

`game.spatial.*` takes an `opts` table with four keys - `type`, `exclude`,
`max_results`, `sort`. Until #550 the decoder ignored anything it did not
recognise, which gave a malformed table two failures that a script cannot tell
apart from a correct query and cannot tell apart from each other:

- an unrecognised key drops the whole filter, so the call returns **everything**
- a `type` list holding no strings becomes a filter nothing satisfies, so the
  call returns **nothing**

Both read at the call site as an empty result. `{ types = "npc" }` and
`{ type = "npc" }` differed only in what they quietly did, and
`guides/lua-api.md` promised the behaviour outright: "anything else in `opts` is
ignored".

This surfaced on asobi#544, where a game reported `neighbours_radius` returning
0 rows with an opts table and 12 without. That specific report is still
unexplained and is tracked in asobi#549 - it is not what this ADR fixes. What it
fixes is that the failure was undiagnosable from Lua, which is what made it
expensive.

The four entry points do not honour the same keys, and cannot be made to:

| | `type` | `exclude` | `max_results` | `sort` |
|---|---|---|---|---|
| `query_radius` (entity-list), `neighbours_radius` | yes | yes | yes | yes |
| `neighbours_rect` | yes | yes | yes | **no** |
| `nearest` | yes | yes | **no** | yes |

`query_rect/4` returns `{Id, Entity}` pairs. There is no distance in a rect
result, so `sort` there has no reference point that is not an invention.
`nearest/4` takes its cap from its `n` argument, so `max_results` is a second
name for it.

## Decision

**An option that the receiving query would not read is an error, not a
no-op - and which options a query reads is that query's own fact.**

1. `decode_spatial_opts/2` takes the query kind and returns
   `{ok, Opts} | {error, Msg}` naming the offending option.
2. The honoured-key table lives in `asobi_spatial:honours_opt/2`, the module
   whose code actually reads the options. The Lua bridge asks rather than
   keeping a copy.
3. `asobi_spatial:nearest/4` now honours `sort`, which it previously accepted
   and ignored. `sort = "farthest"` returns the `n` farthest, a query games
   want, and the sorted list was already being built.
4. Absent options stay absent: a missing argument, a `nil`, and `{}` all mean
   "no options". luerl passes a trailing `nil` through as an argument, so this
   is a real shape and not a theoretical one.

## Consequences

- **This is a breaking change for a script that today passes an option that is
  ignored.** That code gets `{ error = ... }` where it used to get a result. The
  repo is pre-1.0 and ADR 0010's freeze covers the wire, not `game.*`, so this
  is cheap now and expensive later. `guides/lua-api.md` documents the per-query
  table.
- **The pressure to reverse this will come from the shared opts table.** A
  developer naturally writes one `opts` and reuses it across entry points, and
  after this change a table with `sort` in it errors on `neighbours_rect`. That
  is the cost, it is real, and it is the reason this ADR exists: the alternative
  is a call that silently ignores part of what it was asked to do, which is what
  #544 cost a reporter a day over. Honour the option where it can be honoured -
  that is why `nearest` gained `sort` rather than keeping a third rejection.
- **Keeping the table in `asobi_spatial` is load-bearing, not tidiness.** A copy
  in the bridge would drift the moment one of those queries grew a capability,
  and it would drift in the silent direction: the bridge would keep rejecting an
  option the query had learned to read, and no test would fail. A test binds
  `honours_opt/2` to the decoder so a key claimed as honoured must decode.
- An Erlang game module calling `asobi_spatial:nearest/4` directly still gets
  the old silent ignore for `max_results`. The functions are not in `guides/`,
  so the exposure is small, but the asymmetry is deliberate: Erlang callers are
  typed and eqwalizer sees `query_opts()`, Lua callers are not.

## Alternatives considered

- **Make all four honour all four.** Rejected. It dies on `rect` + `sort`, which
  has no implementation that is not an invented reference point. Pursuing
  uniformity would mean either a worse rect API or a fifth option to configure
  what a rect sorts by.
- **Warn and proceed instead of erroring.** Rejected for the unknown-key and
  malformed-value cases, where nothing correct ever depended on the old
  behaviour. It is the honest fallback for the two remaining
  query-does-not-honour cells if the shared-opts-table pressure proves real in
  practice, and is the first thing to reach for before reverting this whole
  decision.
- **Leave it and document the trap.** Rejected: `guides/lua-api.md` had
  documented it, in the form of a promise that it was safe.
