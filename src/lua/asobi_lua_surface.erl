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
- `t:vm_kind/0` - the kinds of VM a Lua chunk runs in.
""".

-export([reserved_namespaces/0, is_reserved/1, name/1]).
-export([effects/0]).
-export([vm_kinds/0]).

-export_type([namespace/0, effect/0, vm_kind/0]).

-type namespace() :: [binary(), ...].
-type effect() :: write | none.
-type vm_kind() :: match | world | zone | bot.

%% Parent before child: a table can only be set on a table that already
%% exists, so the root leads and every nested namespace follows it.
-define(RESERVED_NAMESPACES, [
    [~"game"],
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
