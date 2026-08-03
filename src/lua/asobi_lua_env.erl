-module(asobi_lua_env).
-moduledoc """
Reads a Lua-runtime setting from the application environment.

The Lua runtime used to ship as its own OTP application, so its knobs
(`dev_errors`, `reload_mode`, `max_heap_words`, `terrain_providers`,
`config_watch_interval`, `rate_limits`) were configured under the `asobi_lua`
application key. After the asobi_lua merge there is no `asobi_lua`
application, and `application:get_env/3` on an application that is never loaded
silently returns the default - every existing `{asobi_lua, [...]}` block in a
`sys.config` would have become dead config with no warning.

So the lookup checks `asobi_lua` first and falls back to `asobi`: an existing
deployment keeps the exact behaviour it had, and `{asobi, [...]}` is the home
for new configuration. `rate_limits` is the one key both halves read, and their
limiter group names are disjoint (`log`/`log_global` here, `auth`/`api`/... in
`asobi_sup`), so a single merged map can carry both.
""".

-export([get_env/1, get_env/2]).

-spec get_env(atom()) -> undefined | {ok, term()}.
get_env(Key) ->
    case application:get_env(asobi_lua, Key) of
        undefined -> application:get_env(asobi, Key);
        {ok, _} = Found -> Found
    end.

-spec get_env(atom(), term()) -> term().
get_env(Key, Default) ->
    case get_env(Key) of
        {ok, Value} -> Value;
        undefined -> Default
    end.
