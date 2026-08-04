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
-export([info/0, rpc/0, lua/0, sup/0, owns/0]).

info() -> #{name => quests, extension_version => 1}.

rpc()  -> #{~"quests.claim" => {asobi_quests_rpc, claim, 2}}.

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

Only `info/0` is required. `rpc/0`, `lua/0`, `sup/0` and `owns/0` default to
empty, because several are frequently empty: an extension with no processes
has no `sup/0`, and `owns/0` earns nothing until a second extension exists to
collide with.

An extension declaring neither `rpc/0` nor `lua/0` is reachable by nobody:
game logic calls `game.<ns>.*` from Lua, and clients call
`asobi.rpc("<ns>.<method>")` over the wire. `rebar3 asobi check` warns about
it rather than failing, because it is a legal state mid-development.

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
    token/0
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

-callback info() -> info().
-callback rpc() -> rpc().
-callback lua() -> lua().
-callback sup() -> [supervisor:child_spec()].
-callback owns() -> owns().

-optional_callbacks([rpc/0, lua/0, sup/0, owns/0]).
