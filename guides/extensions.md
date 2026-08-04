# Extensions

An extension is an ordinary OTP application that depends on asobi, added as a
dependency of your release, plus one small module telling asobi the few things
it cannot discover.

No new packaging concept, no new lifecycle, nothing to learn beyond OTP.

> This contract is **experimental**. The wire freezes, because SDK users vendor
> by copying source. This module does not, until a real second consumer has
> said what it is missing.

## Installing one

```erlang
%% your_game_app/rebar.config
{deps, [
    {asobi,        {git, "https://github.com/widgrensit/asobi.git", {tag, "v0.50.0"}}},
    {asobi_quests, {git, "https://github.com/you/asobi_quests.git", {tag, "v1.0.0"}}}
]}.

{relx, [{release, {your_game, "1.0.0"},
         [your_game_app, asobi_quests, asobi, sasl]}]}.
```

Two lines. Removing an extension is deleting them; its tables survive until
deliberately purged, because destroying player progress on a dependency change
is the wrong default.

`asobi_quests` depends on `asobi`. Your app depends on both. asobi never
depends on an extension: every extension depends on asobi, so the reverse edge
is a cycle relx sorts into a build failure and Hex rejects outright.

Validate the set before you boot it:

```erlang
{project_plugins, [{asobi, {git, "https://github.com/widgrensit/asobi.git", {tag, "v0.50.0"}}}]}.
```

```sh
rebar3 asobi check
```

This is the gate. asobi validates the same set again at boot, but a boot-time
failure is raised from inside Nova's route compilation and surfaces with Nova's
crash context rather than a legible asobi error.

## Who calls an extension

Two consumption paths, and an extension wants both.

| Caller | Path | For |
|---|---|---|
| Game logic, in-match, server-side | `game.quests.progress(player_id, 1)` | "player killed something, +1" |
| Game client, over the network | `asobi.rpc("quests.claim", ...)` | "give me my reward" |

An extension with only the wire cannot observe gameplay; one with only Lua
cannot be triggered by a player action from the client.

## What you declare

```erlang
-module(asobi_quests_extension).
-behaviour(asobi_extension).
-export([info/0, rpc/0, lua/0, sup/0, owns/0, codes/0]).

info() -> #{name => quests, extension_version => 1}.

rpc()  -> #{~"quests.list"  => {asobi_quests_rpc, list,  2},
            ~"quests.claim" => {asobi_quests_rpc, claim, 2}}.

lua()  -> #{~"quests" =>
              #{~"progress" => #{mfa     => {asobi_quests_lua, progress, 2},
                                 args    => [binary, integer],
                                 effects => write,
                                 vms     => [match, world]},
                ~"status"   => #{mfa     => {asobi_quests_lua, status, 1},
                                 args    => [binary],
                                 effects => none,
                                 vms     => [match, world, bot]}}}.

sup()  -> [#{id    => asobi_quests_tracker,
             start => {asobi_quests_tracker, start_link, []}}].

owns() -> #{tables => [~"quests", ~"quest_progress"],
            rpc    => [~"quests"],
            lua    => [~"quests"],
            queues => [~"quests"]}.

codes() -> #{~"quests.already_claimed" =>
               #{status => 409, message => ~"This quest was already claimed."}}.
```

Only `info/0` is required. The rest default to empty.

- `rpc/0` - core cannot guess that `quests.claim` is `{asobi_quests_rpc, claim, 2}`.
- `lua/0` - the `game.<ns>.*` surface a Lua game calls. `effects` is not
  decoration: probe VMs re-run the whole script body to ask `phases()` and swap
  every `write` function for an inert stub, so a `write` declared `none` fires
  twice on every match creation.
- `sup/0` - child specs, if you want asobi supervising them.
- `owns/0` - the tokens this extension claims. It earns nothing with one
  extension installed; it is the N >= 2 key.
- `codes/0` - the error codes this extension mints. Core's set is closed, so
  an undeclared code answers 500 and logs as a core defect.
- `info/0` - the contract version, distinct from the package version, because a
  minor release can change an experimental contract.

## Most of it is discovered

| Thing | How asobi finds it | You declare |
|---|---|---|
| Migrations | `application:get_key(App, modules)`, matched on `m<14 digits>_` | nothing |
| Schemas | Same module list, filtered by "exports `table/0` and `fields/0`" | nothing |
| Background jobs | Nothing at all. The job row names the worker module | nothing |
| Domain logic | Nothing. They are modules; other code calls them | nothing |
| RPC handlers | Cannot be inferred | `rpc/0` |
| Lua namespace | Cannot be inferred | `lua/0` |
| Supervised processes | Optional | `sup/0` |
| Namespace ownership | Cannot be inferred | `owns/0` |

Discovery walks the OTP application graph, filtering on "exports
`<app>_extension`". Depending on asobi is not the filter: `asobi_lua`,
`asobi_engine` and `asobi_admin` all have asobi in their closure and none is an
extension.

## Prefer a library application

If your extension has processes, **omit `mod` from your `.app.src`** and
declare children via `sup/0`.

```
asobi_sup  (one_for_one, 10/60)
  `- asobi_extension_sup       (one_for_one, 3/60)
       |- quests               (own restart budget)
       `- clans
```

The reason is specific. Applications in a release are permanent by default, and
in OTP a permanent application terminating takes the whole runtime with it. So
a normal OTP app whose supervisor exceeds its restart intensity **kills the
node** - matchmaking, presence, every live match. Under
`asobi_extension_sup` an extension that exhausts its own budget goes dark,
core logs which one, and the node survives.

This is the ordinary BEAM pattern, not an invention: Ecto repos, Oban and
Phoenix endpoints are all started in the host's tree rather than by the library.

A normal OTP application with its own `mod` also works. You then own the
failure mode, and the operator has to remember to mark it non-permanent in the
release.

**Consequence:** with no `mod` there is no `start/2` for one-time setup. ETS
tables and config validation move into the `init/1` of a supervised worker, and
`application:which_applications()` will not show the extension as running.

Per-extension restart limits default to 5 in 60 and are settable:

```erlang
{asobi, [{extension_restart, #{intensity => 5, period => 60}}]}
```

## Namespaces

`owns/0` reserves names. Two extensions claiming the same table, RPC prefix,
Lua namespace or job queue is a build failure naming both claimants, and so is
claiming a name core reserves.

The claim set is `owns/0` plus what the manifest already implies: the prefixes
in `rpc/0` and the namespaces in `lua/0`. So a collision is caught even before
either extension has bothered with `owns/0`.

Core's reserved names are derived from core itself: Lua namespaces from
`asobi_lua_surface`, tables from core's schemas, queues from core's shigoto
workers, and RPC prefixes from the domains of `asobi_error:core_codes/0` - an
RPC prefix and an error-code domain are the same token, so owning `storage`
would mint codes inside core's closed code set.

## Error codes

`asobi_error`'s set is closed, so a code you have not declared answers 500 and
logs as a core defect. Declare yours:

```erlang
codes() -> #{~"quests.already_claimed" =>
               #{status => 409, message => ~"This quest was already claimed."},
             ~"quests.not_found" =>
               #{status => 404, message => ~"No quest exists with this id."}}.
```

`{asobi_error, ~"quests.already_claimed"}` then answers 409 with the shared
object and logs nothing.

Every code must be `<domain>.<name>`, and the domain is an RPC prefix you own:
a code domain and an RPC prefix are the same token, so `rebar3 asobi check`
refuses a code in core's namespace or in another extension's, and refuses a
bare one. The set is read once at boot, from the manifest, so it stays closed
per deployment - a string arriving in a request or a Lua script still cannot
become a code.

## Tables

Three distinct things, and only one creates a table:

1. **The schema** - a `kura_schema` module. Describes.
2. **The migration** - generated by `rebar3 kura compile`, never hand-written.
   Creates.
3. **`owns/0`** - reserves the name. Creates nothing.

Rules:

- An extension may foreign-key into core. **Core never foreign-keys into an
  extension.**
- **Extensions never alter core tables.** Use a sidecar table keyed on
  `player_id`. Two extensions both adding `level` to `players` is
  unrecoverable, and core adding the same column later is worse.
- An extension FK into `players.id` must cascade or declare an erase path. A
  blanket cascade was rejected: cascading `wallets` would erase the financial
  ledger through `transactions.wallet_id`.

Your migrations run from your own application: kura discovers them through
`asobi_repo:migration_apps/0`, inside core's transaction and under one
advisory lock. Declare `on_delete = cascade` on the `#kura_assoc` into
`players.id` and the generated migration carries it.

### A table extracted out of core

`owns/0` and the migration that creates a table are separable, and one case
needs them separate: a table that used to be core's.

`asobi_seasons` owns `seasons`, but the `CREATE TABLE` sits in an asobi
migration that has already run against live databases - and shares a file with
a table core kept. So the extension ships a schema and no migration, and asobi
keeps the history it cannot honestly disown. Ownership is the manifest's job;
history is append-only.

This is the shape of every future extraction, not a special case for seasons.
It only applies to a table core once created: a table an extension invents is
created by the extension's own migration, like `quests`.

## Counters

`update_all/2` SETs literals and kura's `on_conflict` overwrites, so neither
accumulates. `asobi_repo:increment/3` is the primitive for the counter every
progress-shaped extension needs:

```erlang
{ok, Row} = asobi_repo:increment(
    asobi_quest_progress,
    #{player_id => PlayerId, quest_id => QuestId},
    #{counter => 1}
).
```

One `INSERT ... ON CONFLICT ... DO UPDATE SET counter = t.counter + EXCLUDED.counter`,
so two concurrent callers both land and the row is created if it is missing.
The conflict target must be a primary key or covered by a unique index.

There is no general `query/2`. Every identifier `increment/3` interpolates is
a field of the schema you pass and every value is a bound parameter, which is
a promise raw SQL through the seam could not make.

## Readiness

The route table compiles during Nova's boot; migrations run afterwards, from
`asobi_app:start/2`. An extension endpoint is therefore reachable before its
tables exist, so core fails closed until migrations finish:

```erlang
case asobi_readiness:guard() of
    ok -> dispatch(Method, Params);
    {error, Object} -> {asobi_error, 503, Object}
end.
```

The `not_ready` code is 503, because retrying works.

## Where the logic goes

```
asobi_quests/
  src/
    asobi_quests.app.src           applications: [kernel, stdlib, asobi]
    asobi_quests_extension.erl     the declarations
    asobi_quests.erl               THE DOMAIN LOGIC - plain Erlang
    asobi_quests_rpc.erl           thin: decode, call domain, encode
    schemas/     asobi_quest.erl, asobi_quest_progress.erl
    migrations/  m20260803174500_create_quests.erl   (generated)
    workers/     asobi_quests_rollover_worker.erl
```

`asobi_quests.erl` knows nothing about HTTP, RPC, Lua or the console. Each of
those is a thin adapter over it, which is what makes one implementation
reachable from a client call, a background job and a Lua binding.

## Installing versus consuming

**Consuming** an installed extension from Lua or from a client works on every
tier. A bundled first-party extension is callable as `game.quests.*` by any Lua
game, including on managed hosting.

**Installing a third-party extension** is where the tier matters:

    Library / self-host from your own release ....... yes
    Self-host from the published container image .... no
    Managed hosting ................................ first-party only

The published image and the managed service run a fixed application set decided
at image build time.

## Not sandboxed

An extension runs in the same node, the same supervision tree and with the same
database credentials as core. `asobi_repo` is unrestricted, and `os:cmd/1`,
`open_port/2` and `load_nif/2` are all reachable. Its migrations run with full
DDL privilege. Treat installing one as you would treat any dependency with
production credentials.
