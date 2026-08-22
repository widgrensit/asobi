-module(asobi_lua_reload_tests).
-include_lib("eunit/include/eunit.hrl").

reload_mode_test_() ->
    [
        {"reload_mode = off skips the stat", fun off_short_circuits/0},
        {"reload_mode = auto polls mtime", fun auto_polls/0},
        {"unknown env value falls back to auto", fun unknown_env_is_auto/0},
        {"reload_mode = off clears a stale just_reloaded flag",
            fun off_clears_stale_just_reloaded_flag/0},
        {"auto polls at most once per interval", fun auto_throttles_the_stat/0},
        {"an interval of 0 polls every call", fun zero_interval_polls_always/0}
    ].

%% widgrensit/asobi#543: `auto` used to stat the script on every tick, which at
%% 80 Hz across 225 zones is 18,000 syscalls a second to notice an edit a human
%% makes every few minutes. The stamp is what proves the second call did not
%% reach the stat.
auto_throttles_the_stat() ->
    with_auto(fun() ->
        Old = application:get_env(asobi_lua, reload_poll_interval_ms),
        application:set_env(asobi_lua, reload_poll_interval_ms, 60_000),
        try
            State = #{
                script => "/nonexistent.lua",
                script_mtime => {{1970, 1, 1}, {0, 0, 0}},
                lua_state => fake_lua_state
            },
            First = asobi_lua_reload:maybe_hot_reload(State),
            Deadline = maps:get(reload_poll_at, First),
            Second = asobi_lua_reload:maybe_hot_reload(First),
            %% Same deadline means maybe_poll/1 took the "too soon" branch: it
            %% only re-stamps when it actually polls.
            ?assertEqual(Deadline, maps:get(reload_poll_at, Second))
        after
            restore(reload_poll_interval_ms, Old)
        end
    end).

zero_interval_polls_always() ->
    with_auto(fun() ->
        Old = application:get_env(asobi_lua, reload_poll_interval_ms),
        application:set_env(asobi_lua, reload_poll_interval_ms, 0),
        try
            State = #{
                script => "/nonexistent.lua",
                script_mtime => {{1970, 1, 1}, {0, 0, 0}},
                lua_state => fake_lua_state
            },
            %% No stamp at all on this path - the old per-tick behaviour, byte
            %% for byte.
            ?assertEqual(State, asobi_lua_reload:maybe_hot_reload(State))
        after
            restore(reload_poll_interval_ms, Old)
        end
    end).

with_auto(Fun) ->
    OldEnv = application:get_env(asobi_lua, reload_mode),
    application:set_env(asobi_lua, reload_mode, auto),
    try
        Fun()
    after
        restore(reload_mode, OldEnv)
    end.

%% When reload_mode is `off`, the function returns the state unchanged
%% even if the script's mtime has actually moved. Set up a state where
%% an auto run would clearly reload, then prove `off` does not.
off_short_circuits() ->
    OldEnv = application:get_env(asobi_lua, reload_mode),
    application:set_env(asobi_lua, reload_mode, off),
    try
        State = #{
            script => "/nonexistent-but-doesnt-matter.lua",
            script_mtime => {{1970, 1, 1}, {0, 0, 0}},
            lua_state => fake_lua_state
        },
        ?assertEqual(State, asobi_lua_reload:maybe_hot_reload(State))
    after
        restore(reload_mode, OldEnv)
    end.

%% `auto` stamps the poll deadline into the state, so an auto run is never
%% byte-identical to its input. Compare everything else.
assert_unchanged_but_stamped(State) ->
    Out = asobi_lua_reload:maybe_hot_reload(State),
    ?assert(maps:is_key(reload_poll_at, Out)),
    ?assertEqual(State, maps:remove(reload_poll_at, Out)).

%% When reload_mode is `auto`, the function actually consults
%% filelib:last_modified on the path. We can't easily induce a real
%% reload here without a fixture script + mtime bump, but we can prove
%% the path is hit by passing a non-existent file and observing that
%% the state is returned unchanged because last_modified returns 0.
auto_polls() ->
    OldEnv = application:get_env(asobi_lua, reload_mode),
    application:set_env(asobi_lua, reload_mode, auto),
    try
        State = #{
            script => "/nonexistent.lua",
            script_mtime => {{1970, 1, 1}, {0, 0, 0}},
            lua_state => fake_lua_state
        },
        assert_unchanged_but_stamped(State)
    after
        restore(reload_mode, OldEnv)
    end.

%% A typo in the env var must not silently disable reload — it should
%% fall back to auto. Set a bogus value and prove the auto path runs.
unknown_env_is_auto() ->
    OldEnv = application:get_env(asobi_lua, reload_mode),
    application:set_env(asobi_lua, reload_mode, garbage_value),
    OldOs = os:getenv("ASOBI_LUA_RELOAD"),
    %% os:unset_env/1 doesn't exist on some OTPs; clearing via putenv with
    %% an empty string lets reload_mode fall through to its default.
    os:putenv("ASOBI_LUA_RELOAD", ""),
    try
        State = #{
            script => "/nonexistent.lua",
            script_mtime => {{1970, 1, 1}, {0, 0, 0}},
            lua_state => fake_lua_state
        },
        assert_unchanged_but_stamped(State)
    after
        restore(reload_mode, OldEnv),
        case OldOs of
            false -> os:putenv("ASOBI_LUA_RELOAD", "");
            V -> os:putenv("ASOBI_LUA_RELOAD", V)
        end
    end.

%% just_reloaded is a one-tick signal, not persistent state. If a reload
%% stamps it true on one tick and reload_mode flips to `off` before the
%% next, the flag must not survive - a caller like
%% asobi_lua_world:spawn_templates_hint/1 would otherwise see
%% just_reloaded => true forever and re-apply "changed" every tick.
off_clears_stale_just_reloaded_flag() ->
    OldEnv = application:get_env(asobi_lua, reload_mode),
    application:set_env(asobi_lua, reload_mode, off),
    try
        State = #{
            script => "/nonexistent-but-doesnt-matter.lua",
            script_mtime => {{1970, 1, 1}, {0, 0, 0}},
            lua_state => fake_lua_state,
            just_reloaded => true
        },
        Result = asobi_lua_reload:maybe_hot_reload(State),
        ?assertNot(maps:is_key(just_reloaded, Result))
    after
        restore(reload_mode, OldEnv)
    end.

restore(Key, {ok, V}) -> application:set_env(asobi_lua, Key, V);
restore(Key, undefined) -> application:unset_env(asobi_lua, Key).
