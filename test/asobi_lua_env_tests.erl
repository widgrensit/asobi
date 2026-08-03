-module(asobi_lua_env_tests).
-include_lib("eunit/include/eunit.hrl").

%% The asobi_lua merge left the Lua runtime without its own OTP application.
%% Every knob an operator had under `{asobi_lua, [...]}` in sys.config would
%% silently resolve to its default once that application stopped existing, so
%% the reader keeps honouring the old key and falls back to `asobi` for new
%% config.

env_test_() ->
    {foreach, fun clear/0, fun(_) -> clear() end, [
        {"legacy asobi_lua key still wins", fun legacy_key_honoured/0},
        {"asobi key is read when asobi_lua is unset", fun new_key_read/0},
        {"asobi_lua takes precedence over asobi", fun legacy_key_precedence/0},
        {"default is returned when neither is set", fun default_when_unset/0},
        {"get_env/1 reports undefined when neither is set", fun undefined_when_unset/0}
    ]}.

clear() ->
    application:unset_env(asobi_lua, reload_mode),
    application:unset_env(asobi, reload_mode).

legacy_key_honoured() ->
    application:set_env(asobi_lua, reload_mode, off),
    ?assertEqual(off, asobi_lua_env:get_env(reload_mode, auto)).

new_key_read() ->
    application:set_env(asobi, reload_mode, off),
    ?assertEqual(off, asobi_lua_env:get_env(reload_mode, auto)).

legacy_key_precedence() ->
    application:set_env(asobi_lua, reload_mode, off),
    application:set_env(asobi, reload_mode, auto),
    ?assertEqual(off, asobi_lua_env:get_env(reload_mode, auto)).

default_when_unset() ->
    ?assertEqual(fallback, asobi_lua_env:get_env(reload_mode, fallback)).

undefined_when_unset() ->
    ?assertEqual(undefined, asobi_lua_env:get_env(reload_mode)).
