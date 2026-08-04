-module(asobi_fixture_tunable_extension).
-moduledoc """
A manifest whose contents the test sets, so one module covers every invalid
and colliding shape instead of a file per case.
""".
-behaviour(asobi_extension).

-export([info/0, rpc/0, lua/0, sup/0, owns/0]).
-export([set/1, clear/0]).

-define(KEY, {?MODULE, manifest}).

-spec set(map()) -> ok.
set(Manifest) ->
    persistent_term:put(?KEY, Manifest).

-spec clear() -> ok.
clear() ->
    _ = persistent_term:erase(?KEY),
    ok.

-spec info() -> asobi_extension:info().
info() ->
    value(info, #{name => tunable, extension_version => 1}).

-spec rpc() -> asobi_extension:rpc().
rpc() ->
    value(rpc, #{}).

-spec lua() -> asobi_extension:lua().
lua() ->
    value(lua, #{}).

-spec sup() -> [supervisor:child_spec()].
sup() ->
    value(sup, []).

-spec owns() -> asobi_extension:owns().
owns() ->
    value(owns, #{}).

value(Key, Default) ->
    case maps:get(Key, persistent_term:get(?KEY, #{}), Default) of
        {raise, Reason} -> error(Reason);
        Value -> Value
    end.
