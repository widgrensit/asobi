-module(asobi_lua_surface).
-moduledoc """
Owns the vocabulary of the `game.*` Lua API surface.

Three things live here, and only here:

- `reserved_namespaces/0` - the `game.*` tables the library owns.
  `asobi_lua_api:install/2` creates exactly this list plus whatever the
  installed extensions declare in `c:asobi_extension:lua/0`, and
  `asobi_lua_api_tests` asserts the core half of that. Anything that later
  has to decide whether a name belongs to the library - validating a
  game-declared or extension-declared namespace, say - reads the list from
  here instead of repeating it.
- `t:effect/0` - what a `game.*` function does to the world. `write`
  means it mutates durable state, fans an event out to players, or moves
  a resource; `none` means it only reads or computes. Probe VMs
  (`asobi_lua_api:install/2`) suppress every `write`.
- `t:vm_kind/0` - the kinds of VM a Lua chunk runs in, and
  `extension_vm_kinds/0`, the subset an extension may bind into.
""".

-export([reserved_namespaces/0, is_reserved/1, name/1]).
-export([effects/0]).
-export([vm_kinds/0, extension_vm_kinds/0]).

-export_type([namespace/0, effect/0, vm_kind/0]).

-type namespace() :: [binary(), ...].
-type effect() :: write | none.
-type vm_kind() :: match | world | zone | bot.

%% Parent before child: a table can only be set on a table that already
%% exists, so the root leads and every nested namespace follows it.
-define(RESERVED_NAMESPACES, [
    [~"game"],
    [~"game", ~"match"],
    [~"game", ~"bots"],
    [~"game", ~"economy"],
    [~"game", ~"leaderboard"],
    [~"game", ~"storage"],
    [~"game", ~"chat"],
    [~"game", ~"spatial"],
    [~"game", ~"zone"],
    [~"game", ~"terrain"]
]).

-spec reserved_namespaces() -> [namespace()].
reserved_namespaces() ->
    ?RESERVED_NAMESPACES.

-spec is_reserved(namespace()) -> boolean().
is_reserved(Namespace) ->
    lists:member(Namespace, ?RESERVED_NAMESPACES).

-doc "Renders a namespace or function path as its Lua name, e.g. `game.economy.grant`.".
-spec name([binary(), ...]) -> binary().
name(Path) ->
    iolist_to_binary(lists:join(~".", Path)).

-spec effects() -> [effect(), ...].
effects() ->
    [write, none].

-spec vm_kinds() -> [vm_kind(), ...].
vm_kinds() ->
    [match, world, zone, bot].

-doc """
The VM kinds an extension's `lua/0` binding may name.

`bot` is absent, and its absence is enforced rather than documented. A bot
script is loaded by `asobi_lua_loader:new/1`, whose PreInstall is the identity,
so it never reaches `asobi_lua_api:install/2` and has no `game` table at all -
see `guides/lua-bots.md`. A binding declaring `bot` would therefore install
nothing, and a declaration that silently does nothing is the failure mode this
list exists to prevent: `asobi_extensions` refuses it at
`rebar3 asobi check`.

Making it work instead was the alternative, and it was rejected. A bot decides
from the state the match broadcasts and nothing more, so `game.<ns>` in a bot
VM would be one extension namespace floating in a `game` table with no
`game.log`, no `game.economy` and no `game.storage` under it. A bot also has no
`players.id` - `bot_Spark` is not a player row - so the one argument every
extension binding takes cannot be supplied. The documented route stands: put
the value in the state the match broadcasts.
""".
-spec extension_vm_kinds() -> [vm_kind(), ...].
extension_vm_kinds() ->
    [match, world, zone].
