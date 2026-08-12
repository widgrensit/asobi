# Extensions

An extension is an ordinary OTP application that depends on asobi, added as a
dependency of your release, plus one small module telling asobi the few things
it cannot discover.

No new packaging concept, no new lifecycle, nothing to learn beyond OTP.

This contract is experimental. The wire freezes, because SDK users vendor by
copying source. The manifest does not, until a real second consumer has said
what it is missing.

## Installing one

```erlang
%% your_game_app/rebar.config
{deps, [
    {asobi, "~> 0.68"},
    {asobi_quests, {git, "https://github.com/you/asobi_quests.git", {tag, "v1.0.0"}}}
]}.

{relx, [{release, {your_game, "1.0.0"},
         [your_game_app, asobi_quests, asobi, sasl]}]}.
```

Two lines. Removing an extension is deleting them; its tables survive until
deliberately purged, because destroying player progress on a dependency change
is the wrong default.

`asobi_quests` depends on `asobi` and your app depends on both. asobi never
depends on an extension, so the reverse edge is a cycle relx sorts into a build
failure and Hex rejects outright.

Validate the set before you boot it:

```erlang
{project_plugins, [{asobi, {git, "https://github.com/widgrensit/asobi.git", {tag, "v0.68.2"}}}]}.
```

```sh
rebar3 asobi check
```

Pin the plugin to the same tag as the dependency. Core's reserved names come
from the plugin's own copy of asobi, so a skewed pin validates against the
wrong reserved set.

This is the gate. asobi validates the same set again at boot, but a boot-time
failure is raised from inside Nova's route compilation and surfaces with Nova's
crash context rather than a legible asobi error.

The published image `ghcr.io/widgrensit/asobi` runs a release built from a
fixed application set at image build time, so installing a third-party
extension means building your own release from the Hex package.

## Who calls an extension

| Caller | Path | For |
|---|---|---|
| Game logic, in-match, server-side | `game.quests.progress(player_id, 1)` | "player killed something, +1" |
| Game client, over the network | an `rpc.call` frame - `ws.rpc(...)` in JS, `rpc_call(...)` in Godot, `realtime:rpc(...)` in Defold and LÖVE | "give me my reward" |
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
                                 vms     => [match, world]}}}.

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
```

Discovery looks for a module literally named `<app>_extension` in the
application's own module list (`application:get_key(App, modules)`). The
`-behaviour` attribute is not what makes it found; the name is. Depending on
asobi is not the filter either, or every game embedding asobi would be an
extension.

Only `info/0` is required. The rest default to nothing.

- `rpc/0` - core cannot guess that `quests.claim` is `{asobi_quests_rpc, claim, 2}`.
  The arity is always 2; see [Writing an RPC handler](#writing-an-rpc-handler).
- `lua/0` - the `game.<ns>.*` surface a Lua game calls. See
  [Writing a Lua binding](#writing-a-lua-binding).
- `sup/0` - child specs, if you want asobi supervising them.
- `owns/0` - the closed statement of what this extension claims. See
  [Namespaces](#namespaces).
- `codes/0` - the error codes this extension mints. See
  [Error codes](#error-codes).
- `ops/0` - operator actions, reached on the ops plane rather than by a player.
  See [Writing an operator action](#writing-an-operator-action).
- `erase_player/1` - how to erase one player, when your rows do not cascade.
  See [Deleting a player](#deleting-a-player).
- `info/0` - `name` is the extension's identity and the root of everything it
  owns. `extension_version` is recorded in the registry and printed by
  `rebar3 asobi check`; nothing enforces it, and no behaviour changes with it.

## Writing an RPC handler

A client calls a declared method over the WebSocket:

```json
{"type": "rpc.call", "cid": "c-1",
 "payload": {"protocol": 1, "method": "quests.claim", "params": {"quest_key": "daily_kills"}}}
```

and gets back one of:

```json
{"type": "rpc.ok",    "cid": "c-1", "payload": {"result": {"quest_key": "daily_kills", "currency": "gold", "amount": 100}}}
{"type": "rpc.error", "cid": "c-1", "payload": {"error": {"code": "quests.already_claimed", "message": "...", "details": {}}}}
```

See [WebSocket protocol](websocket-protocol.md) for the frames either side of
this one. `cid` is required here and validated server-side (1-64 printable
ASCII bytes), unlike the optional echo the rest of the socket takes: it is the
only way a client pairs a reply with the call it made. `params` and `result`
are always objects, so either can grow a field without breaking a shipped
client.

`protocol` is core's RPC payload version, currently `1`, and is unrelated to
your `extension_version`. Any other value answers `rpc.unsupported_protocol`
with `details.supported` listing what this node speaks. A node reports its own
from `asobi_rpc:protocol/0`.

You rarely build that frame by hand. Every client SDK wraps it, generates the
`cid` and correlates the reply for you:

```js
// asobi-js: resolves with `result`, rejects with an AsobiRpcError
try {
  const { currency, amount } = await ws.rpc("quests.claim", { quest_key: "daily_kills" });
} catch (e) {
  if (e.code === "quests.already_claimed") { /* domain outcome */ }
}
```

```gdscript
# asobi-godot: the reply arrives on the callable, keyed by the returned cid
realtime.rpc_call("quests.claim", {"quest_key": "daily_kills"}, func(ok, data):
    if ok: print(data["amount"], data["currency"])
    else:  print(data["code"]))
```

Without an SDK - to check a method by hand, or from a language with no asobi
SDK yet - it is two frames on the socket. RPC rides the game WebSocket, so this
is `websocat` rather than `curl`, and the socket must be authenticated first:
an `rpc.call` on an unauthenticated socket is rejected, because `rpc/0` is
player-scoped and there is no player yet.

```bash
TOKEN=$(curl -sX POST https://your-host/api/v1/auth/login \
  -H 'content-type: application/json' \
  -d '{"username":"alice","password":"..."}' | jq -r .access_token)

printf '%s\n%s\n' \
  "{\"type\":\"session.connect\",\"cid\":\"1\",\"payload\":{\"token\":\"$TOKEN\"}}" \
  '{"type":"rpc.call","cid":"2","payload":{"protocol":1,"method":"quests.claim","params":{"quest_key":"daily_kills"}}}' \
  | websocat wss://your-host/ws
```

The reply carries the `cid` you sent, which is what lets several calls be in
flight at once:

```json
{"type":"rpc.ok","cid":"2","payload":{"result":{"reward":100}}}
```

Branch on `code`, never on `message`. The shape is the same in every SDK - a
method name, a params object, and a reply that is either a result object or the
shared error object - so a method you declare here is callable from all of them
without a per-engine server change. `flame_asobi` is a Flame bridge over the
Dart SDK rather than a protocol implementation of its own, so it inherits
`rpc` from it.

The handler is `(Params, Ctx)`, which is why the arity in `rpc/0` is always 2:

```erlang
-spec claim(asobi_rpc:params(), asobi_rpc:ctx()) -> asobi_rpc:reply().
claim(#{~"quest_key" := QuestKey}, #{player_id := PlayerId}) ->
    case asobi_quests:claim(PlayerId, QuestKey) of
        {ok, #{currency := C, amount := A}} ->
            {ok, #{quest_key => QuestKey, currency => C, amount => A}};
        {error, already_claimed} -> {error, ~"quests.already_claimed"};
        {error, {no_such, Key}}  -> {error, ~"quests.not_found", #{quest_key => Key}}
    end.
```

`{ok, map()} | {error, Code} | {error, Code, Details}`.

The failure half is a code, never a status and never an object you build
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
survives a surface where the code is a runtime term the handler could have
built out of `params`.

### What the seam answers

| Code | Status | When |
|---|---|---|
| `rpc.unknown_method` | 404 | no installed extension declares that method, or `method` is not a string |
| `rpc.invalid_cid` | 400 | `cid` missing, empty, over 64 bytes, or not printable ASCII |
| `rpc.invalid_params` | 400 | `params` is not a JSON object |
| `invalid_payload` | 400 | `payload` is not a JSON object |
| `rpc.unsupported_protocol` | 400 | `protocol` is not this node's version |
| `unauthenticated` | 401 | the socket has not completed `session.connect` |
| `not_ready` | 503 | migrations have not finished on this node |
| `internal` | 500 | the handler is at fault; see above |

A rejected `cid` comes back on a frame carrying no `cid` at all, because there
is nothing trustworthy to echo. That one reply cannot be correlated: a client
that sends a malformed `cid` gets an answer it must match by shape, not by id.

### Before dispatch

The socket applies two limits ahead of any of the above, so a chatty method has
to be sized against them:

- 64 KiB per text frame. A larger frame answers `payload_too_large`.
- 60 messages per second per connection, in a fixed one-second window. Over it
  answers `rate_limited`.

Both answer on the legacy `error` frame with no `cid`, so neither is
correlatable either. The budget is per connection, held in the socket's own
state: it counts every frame the socket carries, not just `rpc.call`, and
adding nodes does not widen it. The buckets that are counted per node are the
HTTP and connect limiters - see [Clustering](clustering.md).

### Every declared method is player-scoped

The caller is the authenticated player on that socket; an unauthenticated
socket is refused before the method is looked up. There is deliberately no
per-method capability class: `read | player_data | config | erasure` is an operator
vocabulary that a player never holds, so tagging a socket method with one would
make it deniable for every caller the dispatcher has. An operator-only method
goes in `ops/0` instead.

## Writing an operator action

`rpc/0` is player-scoped, so an admin action - defining a quest, correcting a
counter, anything a player must never call - has no home there. `ops/0` is that
home, reached on the ops plane by an operator credential:

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

`/api/v1/ops/ext/:extension/:action` is the extension seam on the ops plane,
and this is what puts something behind it. Core's own routes there are reads
apart from erasing and exporting a player. You still declare no routes: core
owns `/ext/:extension/:action` and dispatches every declared action behind it,
the same way it owns one WebSocket frame type and dispatches `rpc/0` behind
that.

Know what gates it. On a stock deployment there is no `ops_secret`, so every
bearer request is denied 403 and none of this is reachable. Once a secret is
set, these routes are live whether or not the console is - `console` gates
`/console` only, never the ops plane. A holder of the secret holds every
capability class, so declaring `class => config` restricts which *minted* tokens
reach an action, not which secret-holders do. `erasure` is the one class a
console session does not get by default, so declaring it also keeps an action
out of a browser unless the operator set `console_erasure`. See
[Operator console](console.md).

The console can invoke an ops action, and an extension can ship the screens
that do it: React source under `priv/console`, composed into the console bundle
by `rebar3 asobi console`. See
[Extending the operator console](console-extensions.md). `/api/v1/ops/features`
reports `ops` for an extension that declares actions and `console` for one that
ships screens, alongside `lua`, `rpc` and `tables`.

Same handler shape as `rpc/0`:

```erlang
-spec define(map(), asobi_ops_extension:ctx()) -> asobi_rpc:reply().
define(#{~"key" := Key}, #{actor := #{id := ActorId}}) ->
    case asobi_quests:define(Key, ActorId) of
        {ok, Quest}          -> {ok, #{quest => Quest}};
        {error, name_taken}  -> {error, ~"quests.name_taken"}
    end.
```

`Params` is the decoded JSON body for a write and the parsed query string for
a `get`. `Ctx` is `#{actor, extension, action}`, so recording who asked and
what they reached needs no second lookup.

Readiness guards this plane as well as the socket: until migrations finish,
every action answers `not_ready` (503).

Three things are core's, not yours:

- `class` is the whole authorisation. `read | player_data | config | erasure` is
  the same vocabulary core's own ops routes carry. An action is admitted when its class
  is in the caller's capabilities and never otherwise. There is nothing to
  check inside your handler.
- An undeclared action is denied, not 404. It has no class, and a route with no
  class is refused - so an unknown extension, an unknown action and a method
  the action does not answer all answer 403. Which extensions are installed is
  not something an unauthorised caller gets to enumerate.
- Every method but `get` is audited. Core runs your function inside
  `asobi_ops_audit:mutation/4` and writes the row from what it returned. You
  cannot opt out, and declaring a method other than `get` is what opts in.

### What the audit records today

The audit path understands `{ok, Succeeded, Failed} | {error, Reason}`. An ops
handler returns `{ok, map()} | {error, Code} | {error, Code, Details}`, so only
the two-element `{error, Code}` matches. Everything else raises inside the
audit write, which is caught and downgraded to an error-level log line naming
the action, the exception class and the reason.

So today, a failing action returning `{error, Code}` records a durable row; a
successful mutation and a raising one are logged, not recorded. The response to
the caller is unaffected either way. Tracked as an open issue; do not build a
compliance story on the row until it is closed.

### Manifest validation

Each of these is a build failure at `rebar3 asobi check`, and again at boot:

- the action is one non-empty path segment, with no `/ . ? # %`
- `method` is `get`, `post`, `put` or `delete`
- `class` is `read`, `player_data` or `config`
- `mfa` is `{Module, Function, 2}`

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

`args` types are `binary`, `integer`, `number`, `boolean`, `table` and `any`,
one per `mfa` argument. Lua has a single number type, so a script writing `1`
may hand over `1.0`; a whole float satisfies `integer`.

`effects` is `write` or `none`, and it is not decoration: probe VMs re-run the
whole script body to ask `phases()` and swap every `write` function for an
inert stub, so a `write` declared `none` fires twice on every match creation.

`vms` decides which VM kinds see the binding, and may name `match`, `world` or
`zone`. A `match` binding is absent from a world's zone VMs, and its namespace
table is not even created there.

`bot` is refused at `rebar3 asobi check`, not ignored. A bot script is loaded
with no `game` table at all - see [Bots](lua-bots.md) - so a binding declaring
`bot` would install nothing, and a declaration that silently does nothing is a
defect. Making it work was rejected: a bot has no `players.id`, so the argument
every extension binding takes cannot be supplied. A bot decides from the state
the match broadcasts and nothing more; put what it needs in that state.

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
| Operator actions | Cannot be inferred | `ops/0` |
| Error codes | Cannot be inferred; the core set is closed | `codes/0` |
| Supervised processes | Optional | `sup/0` |
| Namespace ownership | Cannot be inferred | `owns/0` |

`rebar3 asobi check` warns that an extension declaring neither `rpc/0` nor
`lua/0` is "reachable by nobody". The check counts those two only, so the
warning also fires for an extension whose entire surface is `ops/0`, which is
reachable. It is spurious for that case and safe to ignore; tracked as an open
issue.

## Prefer a library application

If your extension has processes, omit `mod` from your `.app.src` and declare
children via `sup/0`.

```
asobi_sup  (one_for_one, 10/60)
  `- asobi_extension_sup       (one_for_one, 3/60)
       |- quests               (own restart budget)
       `- clans
```

Applications in a release are permanent by default, and in OTP a permanent
application terminating takes the whole runtime with it. So a normal OTP app
whose supervisor exceeds its restart intensity kills the node - matchmaking,
presence, every live match. Under `asobi_extension_sup` an extension that
exhausts its own budget goes dark, core logs which one, and the node survives.
This is the ordinary BEAM pattern: Ecto repos, Oban and Phoenix endpoints are
all started in the host's tree rather than by the library.

An application with its own `mod` also works; you then own the failure mode,
and the operator has to mark it non-permanent in the release. With no `mod`
there is no `start/2` for one-time setup: ETS tables and config validation move
into the `init/1` of a supervised worker.

Per-extension restart limits default to 5 in 60 and are settable:

```erlang
{asobi, [{extension_restart, #{intensity => 5, period => 60}}]}
```

`sup/0` children are per node. A supervised `gen_server` holding state holds N
copies of it across an N-node cluster, one per node, with nothing synchronising
them; and matches and worlds do not migrate between nodes. See
[Clustering](clustering.md).

## Boot order and readiness

The route table compiles during Nova's boot, inside `nova_sup:init/1`;
migrations run afterwards, from `asobi_app:start/2`. An extension endpoint is
therefore reachable before its tables exist, so both seams fail closed until
migrations finish: every RPC call and every ops action answers `not_ready`
(503) until then. You get this for free - there is nothing to call.

```erlang
case asobi_readiness:guard() of
    ok -> dispatch(Extension, Action, Actor, Req);
    {error, _Object} -> {asobi_error, ~"not_ready"}
end.
```

Your `sup/0` children are on the other side of that seam and get two
guarantees, so none of them needs a retry path:

- They start in the order `sup/0` returns them, and after the children of every
  extension your application depends on. That is OTP's own child order and
  `asobi_extensions:resolve/0`'s dependency order; nothing sorts either.
- `init/1` may query. Extension children start after migrations have run to
  completion, so the pool is up and every table - core's and yours - exists.

Two failure modes are worth stating plainly:

- An invalid manifest set stops the node. `asobi_extensions:resolve/0` raises
  `{asobi_extensions, Problems}` after logging each problem in prose, from
  inside Nova's route compilation. The node does not start. This is why
  `rebar3 asobi check` is the gate.
- If migrations did not complete, `asobi_extension_sup` starts no extension at
  all and logs which ones it did not start, and every extension seam answers
  503. The alternative is every extension crash-looping into its own restart
  budget and going dark anyway. The marker is written once, before this
  supervisor exists, so it cannot flip later and there is nothing to retry.

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
to say so. That leaves `owns/0` one job: the closed-set assertion. Naming a
kind at all says "this is the whole set", so anything derived outside it is a
build failure - which is what catches a worker on `quests` under an `owns/0`
saying `quest`.

Core's reserved names derive from core itself by the same rules: Lua namespaces
from `asobi_lua_surface:reserved_namespaces/0`, tables from core's schemas,
queues from core's shigoto workers.

Reserved RPC prefixes are the domains of `asobi_error:core_codes/0` plus every
core Lua namespace, because an RPC prefix and an error-code domain are the same
token. So `game`, `economy`, `leaderboard`, `storage`, `chat`, `spatial`,
`zone` and `terrain` are all refused as RPC prefixes as well as Lua
namespaces - owning `storage` would mint codes inside core's closed code set.

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

Every code must be `<domain>.<name>` with the domain an RPC prefix you own, so
`rebar3 asobi check` refuses a code in core's namespace or another extension's,
and refuses a bare one. `status` must be 100-599 and `message` non-empty. The
set is read once at boot, from the manifest, so it stays closed per
deployment - a string arriving in a request or a Lua script cannot become a
code.

## Tables

Three distinct things, and only one creates a table:

1. The schema - a `kura_schema` module. Describes.
2. The migration - generated by `rebar3 kura compile`, never hand-written.
   Creates.
3. `owns/0` - reserves the name. Creates nothing.

Rules:

- An extension may foreign-key into core. Core never foreign-keys into an
  extension.
- Extensions never alter core tables. Use a sidecar table keyed on
  `player_id`. Two extensions both adding `level` to `players` is
  unrecoverable, and core adding the same column later is worse.
- An extension FK into `players.id` must cascade or declare an erase path. A
  blanket cascade was rejected: cascading `players` into `iap_transactions`
  would destroy real-money purchase records that a refund or chargeback
  dispute still needs.

Your migrations run from your own application: kura discovers them through
`asobi_repo:migration_apps/0`, inside core's transaction and under one
advisory lock.

### A table extracted out of core

`owns/0` and the migration that creates a table are separable, and one case
needs them separate: a table that used to be core's.

`asobi_seasons` owns `seasons`, but the `CREATE TABLE` sits in an asobi
migration that has already run against live databases, and shares a file with a
table core kept. So the extension ships a schema and no migration, and asobi
keeps the history it cannot honestly disown. Ownership is the manifest's job;
history is append-only.

The operational consequence: core has no `seasons` schema, so `rebar3 kura
compile` will offer to drop the table. Decline it. The same applies to any
table extracted this way, and this is the shape of every future extraction. It
only applies to a table core once created: a table an extension invents is
created by the extension's own migration, like `quests`.

## Deleting a player

Cascade or declare an erase path - and an undeclared `on_delete` lowers to
`no_action`, so the foreign key `rebar3 kura compile` generates refuses the
delete until you have picked one. The first row your extension writes for a
player makes that player undeletable otherwise. The symptom of declaring
neither is guests quietly ceasing to be reaped.

Cascade is one line on the association:

```erlang
#kura_assoc{
    name = player, type = belongs_to, schema = asobi_player,
    foreign_key = player_id, on_delete = cascade
}
```

`rebar3 kura compile` carries that into the generated migration as
`ON DELETE CASCADE`, and there is nothing else to write.

Cascade is right for progress rows and wrong for a financial or audit row -
the case that rejected a blanket cascade in the first place. Implement
`erase_player/1` instead:

```erlang
-spec erase_player(binary()) -> ok | {error, term()}.
erase_player(PlayerId) ->
    {ok, _} = asobi_repo:delete_all(by_player(asobi_quest_progress, PlayerId)),
    ok.
```

### Who calls it, and when

`asobi_player_erase` does. That is the single place core deletes a player, and
it has two entry points: `asobi_player_erase:run/1` from an Erlang shell, and
`POST /api/v1/ops/players/:id/erase` on the ops plane. The guest reaper is one
more caller of the same code rather than a second implementation of it, so
there is one erasure path and your callback is on it whichever way the deletion
was asked for.

Core calls it inside its own transaction, before deleting any of its own rows,
once per installed extension in dependency order. Do not open a transaction of
your own. Extensions run before core so an erase path can still read the
player's core rows.

Erasure is atomic across every extension. Returning `{error, Reason}` or
raising aborts the whole deletion - no extension's rows go, core's rows stay,
the player survives, and one logged line names the extension and the reason. So
an erase path doing work the transaction cannot undo, such as deleting a remote
object, must be idempotent: a later extension's failure rolls back everything
around it and the deletion is retried.

Omit `erase_player/1` when your rows cascade: it is the alternative to that
declaration, not a second copy of it. Cascade lives on the column because the
database is what enforces it, which is why this is a callback and not an
`owns/0` key.

### The third option: sever the reference

Delete the rows, or null the player reference and keep the row. Core does both
in one function and it is worth reading as the worked example, because a
receipts table is exactly where authors get stuck.

`asobi_player_erase:steps/1` deletes eleven tables and severs two:

- `iap_transactions.player_id` is set to `NULL`. The receipt carries a
  provider, a store transaction id and a product id, and a refund or chargeback
  dispute needs it long after the account is gone. Statutory retention beats
  erasure for that row.
- `groups.creator_id` is set to `NULL`. Deleting the group to free the key
  would destroy every other member's data.

Everything else goes. That *is* the anonymisation: every player-referencing
table in core stores a bare uuid and nothing else about the person, so once
`players` and `player_identities` are gone the surviving id resolves to nobody.
Core does not mint a tombstone player row, and neither should you - a tombstone
is a record about a person you were told to erase.

Core's own foreign keys are all `no_action` and its erasure enumerates its
children explicitly rather than delegating to the database. That is deliberate,
and it is the reason a blanket `ON DELETE CASCADE` migration is refused rather
than merely discouraged: a database cascade fires below the transaction's
control flow, so `erase_player/1` would never be called at all and the receipts
would be destroyed silently.

### `export_player/1`

Core exports a player - `GET /api/v1/ops/players/:id/export` - and the payload
names **every** installed extension under an `extensions` key: the data your
`export_player/1` returned, or a `skipped` marker when you do not export one.

`erase_player/1` earns its keep because the foreign key forces you to answer:
skip it and the player row physically cannot be deleted. An export callback has
no such forcing function - an extension that skipped an unmarked one would
produce a silently incomplete export and nothing would fail - so the artefact
itself is the forcing function. A skipped extension is a visible marker in the
export a data subject or auditor reads, not an absence nobody can detect.

```erlang
-spec export_player(binary()) -> {ok, #{binary() => term()}} | {error, term()}.
export_player(PlayerId) ->
    {ok, Rows} = asobi_repo:all(by_player(asobi_quest_progress, PlayerId)),
    {ok, #{~"quest_progress" => [maps:with([quest_id, counter], Row) || Row <- Rows]}}.
```

The map keys are your own section names, mirroring core's per-table sections.
Apply the same rule core does: positive allowlists via `maps:with/2`, never
subtractive filters - an extension carrying a token or secret column is one
schema field away from exporting it otherwise.

A missing callback is a marker; a failing one fails the export. Returning
`{error, _}` or raising means data was promised and not delivered - exactly the
silent incompleteness the marker exists to prevent - so the whole request
answers `500 ops.export_incomplete` and no artefact is produced. There is no
transaction: core's export is a sequence of plain reads, and yours run in the
same untransacted pass, after core's own sections.

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

One statement, roughly
`INSERT ... ON CONFLICT (...) DO UPDATE SET "counter" = "quest_progress"."counter" + EXCLUDED."counter"`,
so two concurrent callers both land and the row is created if it is missing.
The conflict target must be a primary key or covered by a unique index, and a
field cannot be both a key and a counter.

There is no general `query/2`. Every identifier `increment/3` interpolates is
a field of the schema you pass and every value is a bound parameter, which is
a promise raw SQL through the seam could not make.

## Testing

Core's suites under `test/extensions/` are the worked examples.

A fixture extension needs no `.app` file and no separate build.
`asobi_fixture_app:install/3` hands `application:load/1` an application spec
directly, with your manifest module in its `modules` list - exactly what
discovery reads. `asobi_fixture_quests_extension` declares all of `rpc/0`,
`lua/0`, `ops/0`, `codes/0` and `owns/0`; `asobi_fixture_minimal_extension` is
the `info/0`-only case; `asobi_fixture_clans_extension` is a second extension
whose application depends on the first, so start order is observable.

Exercise `rpc/0` without a socket by calling the dispatcher directly.
`asobi_rpc:handle(Cid, Payload, Caller)` takes the payload map and a caller of
`#{player_id, session}` or the atom `unauthenticated`, and returns
`{Cid, Outcome}` - no cowboy, no connection. `asobi_rpc_tests` is the pattern:
reset the registry, install the fixture, `asobi_extensions:resolve()`,
`asobi_readiness:mark_ready()`, call, assert. Reset both in teardown, because
the registry and the readiness marker are `persistent_term`.
`asobi_ops_extension:handle/1` takes a `cowboy_req` map, so the ops seam is
tested from a hand-built map carrying `bindings` and `auth_data`;
`asobi_ops_extension_tests` shows the shape.

`rebar3 asobi check` belongs in your host release's CI, not the extension's
own: it validates a whole installed set, and an extension built alone has
nothing to collide with. Run it after `compile` (the provider already depends
on it) and before anything boots the node.

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

## Not sandboxed

An extension runs in the same node, the same supervision tree and with the same
database credentials as core. `asobi_repo` is unrestricted, and `os:cmd/1`,
`open_port/2` and `load_nif/2` are all reachable. Its migrations run with full
DDL privilege. Treat installing one as you would treat any dependency with
production credentials.

## Next steps

- [Extending the operator console](console-extensions.md) - screens for the
  actions declared above.
- [WebSocket protocol](websocket-protocol.md) - the frame `rpc.call` lives in.
- [Operator console](console.md) - turning the ops plane on.
- [Clustering](clustering.md) - what is per node and what is not.
- [Lua API](lua-api.md) - the `game.*` surface your namespace joins.
