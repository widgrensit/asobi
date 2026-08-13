-module(asobi_extension).
-moduledoc """
The extension contract.

An extension is an ordinary OTP application that depends on `asobi` and is a
dependency of the **host** release, plus one module named `<app>_extension`
implementing this behaviour. asobi never depends on an extension: every
extension depends on asobi, so the reverse edge is a cycle relx and Hex both
reject.

Most of what an extension provides is discovered rather than declared.
Migrations and schemas come from `application:get_key(App, modules)`, shigoto
workers need no registration at all, operator console screens are React source
at `priv/console/index.jsx` and are found by being there, and domain logic is
just modules. This behaviour covers only what core cannot infer.

```erlang
-module(asobi_quests_extension).
-behaviour(asobi_extension).
-export([info/0, requires/0, rpc/0, lua/0, sup/0, owns/0, codes/0, erase_player/1, export_player/1]).

info() -> #{name => quests, extension_version => 1}.

requires() -> [economy].

rpc()  -> #{~"quests.claim" => {asobi_quests_rpc, claim, 2}}.

codes() -> #{~"quests.already_claimed" =>
               #{status => 409, message => ~"This quest was already claimed."}}.

lua()  -> #{~"quests" =>
              #{~"progress" => #{mfa     => {asobi_quests_lua, progress, 2},
                                 args    => [binary, integer],
                                 effects => write,
                                 vms     => [match, world]}}}.

sup()  -> [#{id => asobi_quests_tracker,
             start => {asobi_quests_tracker, start_link, []}}].

owns() -> #{tables => [~"quests"], rpc => [~"quests"],
            lua => [~"quests"], queues => [~"quests"]}.

erase_player(PlayerId) ->
    {ok, _} = asobi_repo:delete_all(by_player(asobi_quest_progress, PlayerId)),
    ok.

export_player(PlayerId) ->
    {ok, Rows} = asobi_repo:all(by_player(asobi_quest_progress, PlayerId)),
    {ok, #{~"quest_progress" => [maps:with([quest_id, counter], Row) || Row <- Rows]}}.
```

Only `info/0` is required. `requires/0`, `rpc/0`, `lua/0`, `sup/0`, `owns/0`,
`codes/0`, `ops/0`, `routes/0`, `erase_player/1` and `export_player/1` default
to nothing, because several are frequently empty: an extension with no
processes has no `sup/0`, and one whose rows cascade needs no `erase_player/1`.

An extension declaring neither `rpc/0` nor `lua/0` is reachable by nobody:
game logic calls `game.<ns>.*` from Lua, and clients call
`asobi.rpc("<ns>.<method>")` over the wire. `rebar3 asobi check` warns about
it rather than failing, because it is a legal state mid-development.

## The two calling conventions

Both are fixed, and they are written down here because the alternative is a
second extension inventing a third shape. `m:asobi_rpc` and `m:asobi_lua_api`
are what call them.

**An RPC handler** is `(Params, Ctx)`, so the arity in `rpc/0` is always 2:

```erlang
-spec claim(asobi_rpc:params(), asobi_rpc:ctx()) -> asobi_rpc:reply().
claim(#{~"quest_id" := QuestId}, #{player_id := PlayerId}) ->
    case asobi_quests:claim(PlayerId, QuestId) of
        {ok, Reward}          -> {ok, #{reward => Reward}};
        {error, already_done} -> {error, ~"quests.already_claimed"}
    end.
```

`{ok, map()} | {error, Code} | {error, Code, Details}`. The failure half is a
**code**, never a status: the status and the whole error object are derived
from it (`asobi_error:status/1`, `asobi_error:object/2`), and a code you
declared in `codes/0` surfaces as itself rather than as `internal`. `Ctx` is
`#{player_id, session, method}` and may gain keys; match what you need.

**A Lua binding** takes the declared arguments positionally, already decoded
to the types `args` names, and returns the same envelope every
persistence-style `game.*` call returns:

```erlang
-spec progress(binary(), integer()) -> {ok, term()} | {error, binary()}.
progress(PlayerId, Amount) ->
    case asobi_quests:progress(PlayerId, Amount) of
        {ok, Count} -> {ok, Count};
        {error, _}  -> {error, ~"progress failed"}
    end.
```

Lua reads `result.ok` or `result.error`. A binding that raises, or returns
anything else, becomes `{ error = "..." }` and one logged line naming the
function - a game developer must never see a silent nil.

`sup/0` exists so an extension can be a **library** application, with no `mod`
in its `.app.src`. Applications in a release are permanent by default and a
permanent application terminating takes the whole runtime with it, so an
extension supervising itself can kill the node. See `m:asobi_extension_sup`.

Two guarantees a `sup/0` child may rely on, so no extension has to reinvent a
retry path around them:

- **Children start in the order `sup/0` returns them**, and one extension's
  children start after every extension its application depends on. That is
  OTP's own child order and `asobi_extensions:resolve/0`'s dependency order;
  nothing sorts either.
- **`init/1` may query.** Extension children start after
  `kura_migrator:migrate/1` has run to completion, so the pool is up and every
  table - core's and the extension's own - exists. If migrations did not
  complete, `asobi_extension_sup` starts no extension at all rather than
  letting each one crash-loop into its restart budget and go dark with an OTP
  crash report as the only explanation.

This contract is experimental and deliberately unfrozen. The wire freezes,
because SDK users vendor by copying source; this module freezes when a real
second consumer has said what it is missing.
""".

-export_type([
    name/0,
    info/0,
    method/0,
    rpc/0,
    lua/0,
    lua_namespace/0,
    lua_function/0,
    lua_arg/0,
    owns/0,
    token/0,
    code_spec/0,
    codes/0,
    ops/0,
    ops_action/0,
    ops_entry/0,
    route/0
]).

-doc "The extension's short name, and the root of everything it owns.".
-type name() :: atom().

-doc """
The contract version, distinct from the package version: a minor release may
change an experimental contract.
""".
-type info() :: #{name := name(), extension_version := pos_integer()}.

-doc """
The subsystems and extensions this extension calls, by name.

A bare list of names - core subsystems (`economy`, `leaderboards`, `world`,
...) and other installed extensions - never version ranges. Which versions are
compatible is the dependency pin's job (`{asobi, "~> 0.83.0"}`, and the
bundle's lockstep for a first-party set); this list says only *that* you call
into a thing, never *which* of it. `requires => [economy]` says "I call into
economy" and nothing about which economy.

Two things read it, and both run the same `asobi_extensions:check/0`:

- **Refusal.** `rebar3 asobi check` and the boot backstop reject a set where a
  required name resolves to nothing - neither a core subsystem nor an
  installed extension. A missing dependency is a build failure naming the
  extension and the name, not an `undef` the first time a client reaches the
  moved code.
- **Boot order.** A requirement on another extension must be backed by an OTP
  application dependency, so the resolver already lists the provider first
  (`c:sup/0`'s start-order guarantee); a requirement whose provider is not
  ordered before it is refused, because boot would otherwise start them out of
  order. A requirement on an always-present core subsystem imposes no order.

The resolution set is the union of core's subsystem names and the installed
extensions' names, and that union is what keeps `requires/0` correct across an
extraction: when a core subsystem later ships as its own package the name
simply moves from the core side of the union to the extension side, and a
`requires` on it stays satisfied - the bundle installs the package. This is
the seam the Wave 3 tournaments->leaderboards dependency rides.
""".
-callback requires() -> [name()].

-doc "An RPC method, `<prefix>.<method>`.".
-type method() :: binary().

-doc """
The RPC methods this extension serves.

Every target is applied as `Module:Function(Params, Ctx)`, so the arity is
always 2. `m:asobi_rpc` refuses any other arity as a defect rather than
letting it reach a client as a mystery.
""".
-type rpc() :: #{method() => mfa()}.

-doc "A `game.<ns>` table, without the `game.` root.".
-type lua_namespace() :: binary().

-type lua() :: #{lua_namespace() => #{binary() => lua_function()}}.

-doc """
One `game.<ns>.<fun>` binding.

`effects` is not decoration. Probe VMs re-run the whole script body to ask
`phases()`, and `asobi_lua_api` swaps every `write` function for an inert
stub. An effectful function declared `none` fires twice on every match
creation.

`mfa` is called fully qualified rather than stored as a fun, so a code upgrade
takes effect without waiting for every live match VM to end.

`vms` may name any of `asobi_lua_surface:extension_vm_kinds/0`. `bot` is not
one of them and is refused rather than ignored: a bot script has no `game`
table at all, so the binding would install nothing.
""".
-type lua_function() :: #{
    mfa := mfa(),
    args := [lua_arg()],
    effects := asobi_lua_surface:effect(),
    vms := [asobi_lua_surface:vm_kind()]
}.

-type lua_arg() :: binary | integer | number | boolean | table | any.

-doc "A name claimed in one namespace: a table, an RPC prefix, a Lua namespace or a queue.".
-type token() :: binary().

-type owns() :: #{
    tables => [token()],
    rpc => [token()],
    lua => [token()],
    queues => [token()],
    http => [token()]
}.

-doc "The HTTP status and human-readable message one code carries.".
-type code_spec() :: #{status := 100..599, message := binary()}.

-doc """
The error codes this extension mints.

`asobi_error`'s own set is closed, so without this an ordinary domain failure
answers 500 and logs as a core defect. Every code must be
`<domain>.<name>` and every domain must be an RPC prefix this extension owns:
a code domain and an RPC prefix are the same token, so `rebar3 asobi check`
refuses a code in core's namespace or in another extension's.

The set is read once, at resolve time, from this manifest - so it is closed
per deployment and nothing reachable from a request can widen it.
""".
-type codes() :: #{asobi_error:code() => code_spec()}.

-doc """
Erase everything this extension holds about one player.

An extension foreign-keying into `players.id` must **cascade or declare an
erase path**, and this is the erase path. Declare neither and installing the
extension makes players undeletable: an undeclared `on_delete` lowers to
`no_action`, so the first extension row for a player turns core's delete into a
constraint violation.

Cascade is right for progress rows and wrong for a financial or audit row - the
case that rejected a blanket cascade in the first place. An extension holding
one exports this instead, and answers erasure in whatever way its own law
requires: delete the rows, or null the player reference and keep the ledger.
Core does not care which, only that the player row can then go.

Not an `owns/0` key. `owns/0` is a set of names, validated at build time and
read by nothing at runtime; it reserves, it does not execute. Cascade is
already declared where the database can enforce it - `on_delete = cascade` on
the `#kura_assoc`, carried into the generated migration - and a second
declaration of the same fact in the manifest could disagree with the schema
that actually decides. So the two alternatives stay in the two places that
enforce them: cascade on the column, erase here.

## When it runs, and what a failure does

Core calls it **inside its own transaction**, before deleting any of its own
rows, once per installed extension in dependency order. Do not open a
transaction of your own.

Extensions before core, because an erase path may want to read what core still
has (a player's stats, its identities) while writing its own summary row. Order
*between* extensions is not load-bearing and is not promised beyond dependency
order: extensions never foreign-key each other, only core.

**Erasure is atomic across every extension, not best-effort with a report.**
Returning `{error, Reason}` or raising aborts the whole deletion: no extension's
rows go, core's rows stay, the player survives, and one logged line names the
extension and the reason. The alternative was considered and rejected. A
best-effort erasure ends with the account gone and some extension's rows
orphaned, or the reverse, and nothing durable saying which - a half-finished
erasure that reports success is a worse answer to a data-subject request than
one that fails loudly and can be retried. Every extension shares `asobi_repo`,
so the single transaction that makes this true costs nothing to arrange.

The corollary is that an erase path doing work the transaction cannot undo -
deleting a remote object, calling a third party - must be idempotent, because a
later extension's failure will roll back everything around it and the whole
deletion will be retried.

Idempotence is not reversibility, and the difference is the one hole in this
contract. Extensions run first, so by the time a later extension refuses, or
core's own audit insert fails, a remote delete has already happened and no
rollback reaches it. The reachable end state is a player who still exists and
whose remote data does not - and because a rolled-back attempt writes no audit
row, nothing durable records that it happened. Ordering does not fix it: order
between extensions is not promised, and core's audit insert follows all of
them.

If you hold data outside this database, write the *intent* to erase it as a row
in your own tables inside the transaction, and let a `m:shigoto` worker perform
the remote call once that row has committed. Then the rollback takes the intent
with it, and the irreversible step only ever runs after the erasure is final.

Core deletes a player in exactly one place, `m:asobi_player_erase`, so that is
where this runs. `asobi_guest_reaper` is one caller of it and the ops route
`POST /api/v1/ops/players/:id/erase` is another; both reach this callback
through the same function, in the same position, under the same transaction.
(`asobi_guest_controller` also deletes, but only a player row it inserted
microseconds earlier and lost a race on, which no extension has been told about
yet.) `m:asobi_extension_erase` is the seam.

Core's own foreign keys are all `no_action` and its erasure enumerates its
children in code. A blanket `ON DELETE CASCADE` across core would fire below
the transaction's control flow, so this callback would never run - which is
the same reason the guide gives an extension author for not reaching for one.
""".
-callback erase_player(PlayerId :: binary()) -> ok | {error, term()}.

-doc """
Export everything this extension holds about one player, keyed by the
extension's own section names - mirroring core's per-table sections.

The read half of `c:erase_player/1`, and optional for a different reason.
Erasure has a physical forcing function: skip it and the foreign key blocks
the delete. An export callback has none, so for a long time there was
deliberately no contract here - an extension that skipped it would have
produced a silently incomplete export and nothing would have failed. What
made one shippable is that the artefact itself now forces the answer: core's
export names **every** installed extension, and one without this callback
appears under a `skipped` marker rather than being silently absent, so a data
subject or auditor can see exactly which extensions contributed and which did
not.

Apply the same projection rule core does: positive allowlists via
`maps:with/2`, never subtractive filters - an extension carrying a token or
secret column is one schema field away from exporting it otherwise. And every
row you return must be one this player owns - core cannot check that for you.
Where one column holds several players' data, lift out this player's part
rather than exporting the column whole, the way core exports only the
requester's own choice from `votes.votes_cast`.

A missing callback is a marker; a failing one fails the export. Returning
`{error, Reason}` or raising means data was promised and not delivered, which
is exactly the silent incompleteness the marker exists to prevent, so the
whole export fails and no artefact is produced. The sections must be
JSON-encodable - the export is served as one JSON object, so a section
`json:encode/1` refuses fails the export the same way, attributed to this
extension rather than surfacing as an unattributed 500 after the payload left
the controller. There is no transaction: the export is a sequence of plain
reads, and this runs in the same untransacted pass, after core's own sections.
`m:asobi_extension_export` is the seam.
""".
-callback export_player(PlayerId :: binary()) ->
    {ok, #{binary() => term()}} | {error, term()}.

-doc "One operator action, the last segment of `/api/v1/ops/ext/<name>/<action>`.".
-type ops_action() :: binary().

-doc """
One operator action: the method it answers, the target, and its capability
class.

`class` is `read | player_data | config | erasure` (ADR 0007), the same
vocabulary core's own ops routes carry, and it is the only thing that
authorises the call. An action with no class is not reachable, because
`asobi_ops_caps` denies a route it cannot tag.

`erasure` means one thing: the action cannot be undone by a later call. It is
not "extra sensitive" - it is held apart from `player_data` because an operator
console is granted every other class by default and this one only on request.
Declare it for an action that destroys data and for nothing else.

`mfa` is applied as `Module:Function(Params, Ctx)` - the same shape as `rpc/0`,
for the same reason - where `Params` is the decoded JSON body for a write and
the query string for a read, and `Ctx` carries the `t:asobi_ops_auth:actor/0`
that was admitted.

Anything but `get` is audited: core wraps it in `asobi_ops_audit:mutation/4`
before it runs, so an extension cannot write on the ops plane without a durable
row naming the operator who asked. That is not something an extension can opt
out of, which is why the method is declared here rather than inferred.
""".
-type ops_entry() :: #{
    method := get | post | put | delete,
    mfa := mfa(),
    class := asobi_ops_caps:class()
}.

-doc """
The operator actions this extension serves, as `Action => t:ops_entry/0`.

`rpc/0` is player-scoped by construction: the caller is the authenticated
player on that socket, and `read | player_data | config | erasure` is an operator
vocabulary no player ever holds. So an extension with an admin surface - the
first one hit it immediately with `quests.define` - had nowhere to put it.
This is that home.

Extensions contribute **no operator routes** - `routes/0` mounts player and
webhook surfaces, never this plane. Core owns one route,
`/api/v1/ops/ext/:extension/:action`, and dispatches it here exactly as it owns
one WebSocket frame type and dispatches `rpc/0` behind it. An action is
therefore reachable at:

```
POST /api/v1/ops/ext/quests/define
```

Actions cannot collide across extensions: they are keyed by the extension's
own name, and two extensions cannot share a name.

An extension can also ship the operator screens that call these, as React
source at `priv/console/index.jsx`, composed into a host's console bundle by
`rebar3 asobi console`. That is discovered rather than declared, so there is no
callback for it here. See `guides/console-extensions.md`.
""".
-type ops() :: #{ops_action() => ops_entry()}.

-doc """
One HTTP route this extension serves, mounted by core's router.

`path` is absolute and `/`-rooted, made of non-empty segments that are either
literals (`[A-Za-z0-9_~-]` - RFC 3986 unreserved minus the dot, which
routing_tree does not normalise) or `:name` bindings. `mfa` is a Nova
controller - applied as `Module:Function(Req)`, so the arity is always 1,
unlike the `rpc/0` and `ops/0` seams whose handlers never see a request -
and it must name an exported function, checked at build time rather than
discovered as a 500.

`security` picks the chain in front of the handler:

- `player` - the same authenticated player-token check every core `/api/v1`
  route carries. The handler's `Req` arrives with `auth_data` holding
  `player_id`, exactly as a core controller's does. This is the default
  choice, and the only right one for anything a client calls.
- `webhook` - no player check, for a server-to-server caller that cannot hold
  a token (a store's receipt notification). The handler must authenticate its
  caller itself - a signature, a shared secret - because nothing else will,
  and the rate limiter puts the path in the dedicated `webhook` bucket
  (10/s per caller, iap's shape) rather than the general api one, because
  per-request signature crypto on the api bucket's budget is a CPU
  amplifier.

Either way the route mounts inside core's global plugin chain - body cap,
rate limiter, security headers - which an extension can neither replace nor
reorder. One path carries exactly one security class: declaring it under
both is refused at build time.
""".
-type route() :: #{
    path := binary(),
    method := get | post | put | delete,
    mfa := mfa(),
    security := player | webhook
}.

-doc """
The HTTP routes this extension serves. Core's router mounts them at boot;
extensions never mount anything themselves.

This exists to preserve extracted REST surfaces and to receive server-to-server
webhooks. A new client-facing feature should use `rpc/0` instead: one
`rpc(method, params)` symbol reaches every SDK with zero per-extension SDK
work, while a new REST route has no SDK surface at all. That is a listing
guideline, not a mechanical ban - "it is a webhook" is an accepted answer.

Every declared path is a derived `http` claim, validated like tables, rpc,
lua and queues - but the comparison is structural rather than token equality:
two paths collide when the routing tree cannot serve both, so `/saves/:slot`
and `/saves/:id` are one claim, a literal sitting under another table's
binding is caught, and so is a pattern that diverges from an existing route
at a binding at any depth - the shape that lets one route swallow another's
lookups. A collision with another extension, with a path any co-mounted
application serves (core's own table, Nova's, `nova_apps` such as
nova_resilience's `/health`), or with a privileged plane prefix
(`/api/v1/ops`, `/api/v1/auth`, `/api/v1/iap`, `/console`, `/ws`) refuses
boot; a declared route can never be silently shadowed first-compiled-wins.

An unmounted route - the extension absent, the path never declared - is
absent from the table: 404, indistinguishable at the path level from a path
that never meant anything. This discipline is path-level only: a mounted
path answers a wrong-method request with 405 and an allow header, as every
core route does, so which methods a declared path serves is enumerable.
That trade is accepted - method behaviour follows HTTP rather than hiding.
""".
-callback routes() -> [route()].

-callback info() -> info().
-callback rpc() -> rpc().
-callback lua() -> lua().
-callback sup() -> [supervisor:child_spec()].
-callback owns() -> owns().
-callback codes() -> codes().
-callback ops() -> ops().

-optional_callbacks([
    requires/0,
    rpc/0,
    lua/0,
    sup/0,
    owns/0,
    codes/0,
    ops/0,
    routes/0,
    erase_player/1,
    export_player/1
]).
