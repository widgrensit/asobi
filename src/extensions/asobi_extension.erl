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
workers need no registration at all, and domain logic is just modules. This
behaviour covers only what core cannot infer.

```erlang
-module(asobi_quests_extension).
-behaviour(asobi_extension).
-export([info/0, rpc/0, lua/0, sup/0, owns/0, codes/0]).

info() -> #{name => quests, extension_version => 1}.

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
```

Only `info/0` is required. `rpc/0`, `lua/0`, `sup/0`, `owns/0` and `codes/0`
default to empty, because several are frequently empty: an extension with no
processes has no `sup/0`, and `owns/0` earns nothing until a second extension
exists to collide with.

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
    codes/0
]).

-doc "The extension's short name, and the root of everything it owns.".
-type name() :: atom().

-doc """
The contract version, distinct from the package version: a minor release may
change an experimental contract.
""".
-type info() :: #{name := name(), extension_version := pos_integer()}.

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
    queues => [token()]
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

-callback info() -> info().
-callback rpc() -> rpc().
-callback lua() -> lua().
-callback sup() -> [supervisor:child_spec()].
-callback owns() -> owns().
-callback codes() -> codes().

-optional_callbacks([rpc/0, lua/0, sup/0, owns/0, codes/0]).
