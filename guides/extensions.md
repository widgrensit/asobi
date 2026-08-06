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
| An operator, on the ops plane | `POST /api/v1/ops/ext/quests/define` | "add a daily quest" |

An extension with only the wire cannot observe gameplay; one with only Lua
cannot be triggered by a player action from the client. The third is a
different audience, not a third way to reach the same one: `rpc/0` is
player-scoped, and no player ever holds an operator capability.

## What you declare

```erlang
-module(asobi_quests_extension).
-behaviour(asobi_extension).
-export([info/0, rpc/0, lua/0, sup/0, owns/0, codes/0, ops/0, erase_player/1]).

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
                                 vms     => [match, world, zone]}}}.

sup()  -> [#{id    => asobi_quests_tracker,
             start => {asobi_quests_tracker, start_link, []}}].

owns() -> #{tables => [~"quests", ~"quest_progress"],
            rpc    => [~"quests"],
            lua    => [~"quests"],
            queues => [~"quests"]}.

codes() -> #{~"quests.already_claimed" =>
               #{status => 409, message => ~"This quest was already claimed."}}.

ops()  -> #{~"define" => #{method => post,
                           mfa    => {asobi_quests_ops, define, 2},
                           class  => config}}.

erase_player(PlayerId) ->
    {ok, _} = asobi_repo:delete_all(by_player(asobi_quest_progress, PlayerId)),
    ok.
```

Only `info/0` is required. The rest default to nothing.

- `rpc/0` - core cannot guess that `quests.claim` is `{asobi_quests_rpc, claim, 2}`.
  The arity is always 2; see [Writing an RPC handler](#writing-an-rpc-handler).
- `lua/0` - the `game.<ns>.*` surface a Lua game calls. `effects` is not
  decoration: probe VMs re-run the whole script body to ask `phases()` and swap
  every `write` function for an inert stub, so a `write` declared `none` fires
  twice on every match creation. `vms` may name `match`, `world` or `zone`;
  `bot` is refused. See [Writing a Lua binding](#writing-a-lua-binding).
- `sup/0` - child specs, if you want asobi supervising them.
- `owns/0` - the closed statement of what this extension claims. Every kind is
  derived from your own code as well, so `owns/0` is an assertion over the
  derivation rather than its source.
- `codes/0` - the error codes this extension mints. Core's set is closed, so
  an undeclared code answers 500 and logs as a core defect.
- `ops/0` - operator actions, reached on the ops plane rather than by a player.
  See [Writing an operator action](#writing-an-operator-action).
- `erase_player/1` - how to erase one player, when your rows do not cascade.
- `info/0` - the contract version, distinct from the package version, because a
  minor release can change an experimental contract.

## Writing an RPC handler

A client calls a declared method over the WebSocket:

```json
{"type": "rpc.call", "cid": "c-1",
 "payload": {"protocol": 1, "method": "quests.claim", "params": {"quest_id": "q-1"}}}
```

and gets back one of:

```json
{"type": "rpc.ok",    "cid": "c-1", "payload": {"result": {"reward": 100}}}
{"type": "rpc.error", "cid": "c-1", "payload": {"error": {"code": "quests.already_claimed", "message": "...", "details": {}}}}
```

`cid` is required here and validated server-side (1-64 printable ASCII bytes),
unlike the optional echo the rest of the socket takes: it is the only way a
client pairs a reply with the call it made. `params` and `result` are always
objects, so either can grow a field without breaking a shipped client.

The handler is `(Params, Ctx)`, which is why the arity in `rpc/0` is always 2:

```erlang
-spec claim(asobi_rpc:params(), asobi_rpc:ctx()) -> asobi_rpc:reply().
claim(#{~"quest_id" := QuestId}, #{player_id := PlayerId}) ->
    case asobi_quests:claim(PlayerId, QuestId) of
        {ok, Reward}               -> {ok, #{reward => Reward}};
        {error, already_claimed}   -> {error, ~"quests.already_claimed"};
        {error, {no_such, Id}}     -> {error, ~"quests.not_found", #{quest_id => Id}}
    end.
```

`{ok, map()} | {error, Code} | {error, Code, Details}`.

The failure half is a **code**, never a status and never an object you build
yourself. Both are derived from the code - `asobi_error:status/1` and
`asobi_error:object/2` - so two call sites cannot answer the same code
differently, and a code you declared in `codes/0` reaches the client as
itself. It is the same dialect core's own controllers speak
(`{asobi_error, Code, Details}`), so there is one shape to learn.

`Ctx` is `#{player_id, session, method}`. It may gain keys: match the ones you
need with `:=` and never match it exhaustively.

Everything else is a defect and answers `internal` with one logged line naming
the method: a handler that raises, one that returns outside the contract, one
declared at an arity other than 2, a result that cannot be JSON-encoded, and a
code you did not declare in `codes/0`. The last one is how the closed code set
survives this surface - every other call site's code is a binary literal
checked at build time, and a handler's is a runtime term it could have built
out of `params`.

**Every declared method is player-scoped.** The caller is the authenticated
player on that socket; an unauthenticated socket is refused before the method
is looked up. There is deliberately no per-method capability class:
`read | player_data | config` (ADR 0007) is an operator vocabulary that a
player never holds, so tagging a socket method with one would make it deniable
for every caller the dispatcher has. An operator-only method goes in `ops/0`
instead - see [Writing an operator action](#writing-an-operator-action).

### Readiness

The route table compiles during Nova's boot; migrations run afterwards, from
`asobi_app:start/2`. An extension endpoint is therefore reachable before its
tables exist, so the dispatcher fails closed until migrations finish: every
call answers `not_ready` (503) until then. You get this for free - there is
nothing to call.

## Writing an operator action

`rpc/0` is player-scoped by construction, so an admin action - defining a
quest, correcting a counter, anything a player must never call - has no home
there. `ops/0` is that home, and it is reached on the ops plane by an operator
credential:

```erlang
-spec ops() -> asobi_extension:ops().
ops() ->
    #{~"define" => #{method => post,
                     mfa    => {asobi_quests_ops, define, 2},
                     class  => config},
      ~"summary" => #{method => get,
                      mfa    => {asobi_quests_ops, summary, 2},
                      class  => read}}.
```

```
POST /api/v1/ops/ext/quests/define
GET  /api/v1/ops/ext/quests/summary?filter=active
```

You still declare no routes. Core owns exactly one - `/ext/:extension/:action`
- and dispatches every declared action behind it, the same way it owns one
WebSocket frame type and dispatches `rpc/0` behind that (ADR 0003).

A handler has the same shape as an RPC handler, because there is no reason for
a second one:

```erlang
-spec define(map(), asobi_ops_extension:ctx()) -> asobi_rpc:reply().
define(#{~"key" := Key}, #{actor := #{id := ActorId}}) ->
    case asobi_quests:define(Key, ActorId) of
        {ok, Quest}          -> {ok, #{quest => Quest}};
        {error, name_taken}  -> {error, ~"quests.name_taken"}
    end.
```

`Params` is the decoded JSON body for a write and the parsed query string for
a `get`. `Ctx` carries the actor that was admitted, so recording who asked
needs no second lookup.

Three things are core's, not yours:

- **`class` is the whole authorisation.** `read | player_data | config` is
  ADR 0007's vocabulary, the same one core's own ops routes carry. An action
  is admitted when its class is in the caller's capabilities and never
  otherwise. There is nothing to check inside your handler.
- **An undeclared action is denied, not 404.** It has no class, and a route
  with no class is refused - so an unknown extension, an unknown action and a
  method the action does not answer all answer 403. Which extensions are
  installed is not something an unauthorised caller gets to enumerate.
- **Every method but `get` is audited.** Core wraps the call in a durable
  audit row naming the operator before your function runs. You cannot opt out,
  and declaring a method other than `get` is what opts in.

## Writing a Lua binding

A game script calls the namespace as an ordinary part of `game`:

```lua
function on_player_kill(player_id, state)
    local result = game.quests.progress(player_id, 1)
    if result.error then
        game.log("warning", "quest progress failed: " .. result.error)
    end
end
```

The binding takes the declared arguments positionally, already decoded to the
types `args` names, and returns the same envelope every persistence-style
`game.*` call returns:

```erlang
-spec progress(binary(), integer()) -> {ok, term()} | {error, binary()}.
progress(PlayerId, Amount) ->
    case asobi_quests:progress(PlayerId, Amount) of
        {ok, Count} -> {ok, Count};
        {error, _}  -> {error, ~"progress failed"}
    end.
```

Lua reads `result.ok` or `result.error`. Nothing is ever silently nil: a wrong
or missing argument is `{ error = "argument 2 must be a integer" }` at the
script's own call site, and a binding that raises or returns outside the
contract is an error result plus one logged line naming the function.

`args` types are `binary`, `integer`, `number`, `boolean`, `table` and `any`.
Lua has a single number type, so a script writing `1` may hand over `1.0`; a
whole float satisfies `integer`.

`vms` decides which VM kinds see the binding. A `match` binding is absent from
a world's zone VMs, and its namespace table is not even created there. Bot VMs
get no `game.*` surface at all today, so `vms => [bot]` installs nothing.

Core calls `{M, F, A}` fully qualified rather than holding a fun, so a code
upgrade takes effect without waiting for every live match VM to end.

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
`<app>_extension`". Depending on asobi is not the filter: `asobi_engine` and
every game that embeds asobi have it in their closure and none is an
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

The claim set is `owns/0` plus what your own code already implies, and every
kind derives:

| Kind | Derived from |
|---|---|
| `rpc` | the prefixes in `rpc/0` and the domains in `codes/0` |
| `lua` | the namespaces in `lua/0` |
| `tables` | `table/0` on your `kura_schema` modules |
| `queues` | `queue/0` on your `shigoto_worker` modules |

So a collision is caught even before either extension has bothered with
`owns/0`, and a queue you actually run is claimed whether or not you remembered
to say so.

That leaves `owns/0` one job: it is the **closed-set assertion**. Naming a kind
at all says "this is the whole set", so anything derived outside it is a build
failure. That is what catches the typo - a worker on `quests`, an `owns/0`
saying `quest` - which used to be invisible, because nothing read `owns.queues`
at runtime.

Core's reserved names are derived from core itself, by the same two rules: Lua
namespaces from
`asobi_lua_surface`, tables from core's schemas, queues from core's shigoto
workers, and RPC prefixes from the domains of `asobi_error:core_codes/0` - an
RPC prefix and an error-code domain are the same token, so owning `storage`
would mint codes inside core's closed code set.

## Bots are not a target

`vms` may name `match`, `world` or `zone`. `bot` is **refused at
`rebar3 asobi check`**, not ignored.

A bot script is loaded without any `game` table at all - see
[Bots](lua-bots.md) - so a binding declaring `bot` would install nothing, and a
declaration that silently does nothing is a defect. Making it work was the
alternative and was rejected: `game.quests` in a bot VM would be one extension
namespace floating in a `game` table with no `game.log`, `game.economy` or
`game.storage` under it, and a bot has no `players.id` - `bot_Spark` is not a
player row - so the argument every extension binding takes cannot be supplied.

A bot decides from the state the match broadcasts and nothing more. Put what it
needs in that state.

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
advisory lock.

## Deleting a player

Cascade or declare an erase path - and an undeclared `on_delete` lowers to
`no_action`, so the foreign key `rebar3 kura compile` generates refuses the
delete until you have picked one. The first row your extension writes for a
player makes that player undeletable otherwise.

Cascade is one line on the association:

```erlang
#kura_assoc{
    name = player, type = belongs_to, schema = asobi_player,
    foreign_key = player_id, on_delete = cascade
}
```

`rebar3 kura compile` carries that into the generated migration as
`ON DELETE CASCADE`, and there is nothing else to write. The symptom of
declaring neither is guests quietly ceasing to be reaped.

Cascade is right for progress rows and wrong for a financial or audit row -
the case that rejected a blanket cascade in the first place. Implement
`erase_player/1` instead:

```erlang
-spec erase_player(binary()) -> ok | {error, term()}.
erase_player(PlayerId) ->
    {ok, _} = asobi_repo:delete_all(by_player(asobi_quest_progress, PlayerId)),
    ok.
```

Core calls it inside its own transaction, before deleting any of its own rows,
once per installed extension in dependency order. Do not open a transaction of
your own. Extensions run before core so an erase path can still read the
player's core rows.

**Erasure is atomic across every extension.** Returning `{error, Reason}` or
raising aborts the whole deletion - no extension's rows go, core's rows stay,
the player survives, and one logged line names the extension and the reason.
Best-effort was rejected: an erasure that half-succeeds and reports success
leaves an account gone with some extension's rows orphaned and nothing durable
saying which, which is a worse answer to a data-subject request than one that
fails loudly and can be retried.

The corollary: an erase path doing work the transaction cannot undo - deleting
a remote object, calling a third party - must be idempotent, because a later
extension's failure rolls back everything around it and the deletion is retried.

Omit `erase_player/1` when your rows cascade: it is the alternative to that
declaration, not a second copy of it. Cascade lives on the column because the
database is what enforces it, and a manifest key saying the same thing could
disagree with the schema that actually decides - which is why this is a
callback and not an `owns/0` key. Delete the rows or null the player reference
and keep the ledger; core only needs the player row to be able to go.

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

Your `sup/0` children are on the other side of that seam and get two guarantees,
so none of them needs a retry path:

- **They start in the order `sup/0` returns them**, and after the children of
  every extension your application depends on. That is OTP's own child order and
  `asobi_extensions:resolve/0`'s dependency order; nothing sorts either.
- **`init/1` may query.** Extension children start after migrations have run to
  completion, so the pool is up and every table - core's and yours - exists.

If migrations did not complete, `asobi_extension_sup` starts **no extension at
all** and logs which ones it did not start. The alternative is every extension
crash-looping into its own restart budget and going dark anyway, with an OTP
crash report as the only explanation. The marker is written once, before this
supervisor exists, so it cannot flip later and there is nothing to retry.

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
