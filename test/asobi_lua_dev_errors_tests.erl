-module(asobi_lua_dev_errors_tests).
-include_lib("eunit/include/eunit.hrl").

dev_errors_test_() ->
    {foreach, fun setup/0, fun cleanup/1, [
        {"off by default", fun off_by_default/0},
        {"app env true enables", fun app_env_enables/0},
        {"app env non-true fails closed", fun app_env_fails_closed/0},
        {"env var true enables when app env unset", fun env_var_enables/0},
        {"env var 1 enables", fun env_var_one_enables/0},
        {"env var other value fails closed", fun env_var_fails_closed/0},
        {"app env false wins over env var", fun app_env_wins/0},
        {"disabled maybe_notify is a no-op", fun disabled_no_op/0},
        {"enabled maybe_notify sends script_error", fun sends_script_error/0},
        {"second notify inside window is dropped", fun rate_limited/0},
        {"notify after window is sent", fun window_elapsed_sends/0},
        {"timeout reason gets a readable message", fun timeout_message/0},
        {"lua_error reason is formatted", fun lua_error_formatted/0},
        {"oversized message is bounded", fun message_bounded/0},
        {"failing match handle_input notifies the player", fun match_input_notifies/0},
        {"world handle_input rate limit survives a zone_tick", fun world_cross_tick_rate_limited/0}
    ]}.

setup() ->
    application:unset_env(asobi_lua, dev_errors),
    os:unsetenv("ASOBI_DEV_ERRORS"),
    meck:new(asobi_presence, [non_strict, no_link]),
    meck:expect(asobi_presence, send, fun(_, _) -> ok end),
    ok.

cleanup(_) ->
    application:unset_env(asobi_lua, dev_errors),
    os:unsetenv("ASOBI_DEV_ERRORS"),
    meck:unload(asobi_presence).

off_by_default() ->
    ?assertNot(asobi_lua_dev_errors:enabled()).

app_env_enables() ->
    application:set_env(asobi_lua, dev_errors, true),
    ?assert(asobi_lua_dev_errors:enabled()).

app_env_fails_closed() ->
    application:set_env(asobi_lua, dev_errors, "true"),
    ?assertNot(asobi_lua_dev_errors:enabled()).

env_var_enables() ->
    os:putenv("ASOBI_DEV_ERRORS", "true"),
    ?assert(asobi_lua_dev_errors:enabled()).

env_var_one_enables() ->
    os:putenv("ASOBI_DEV_ERRORS", "1"),
    ?assert(asobi_lua_dev_errors:enabled()).

env_var_fails_closed() ->
    os:putenv("ASOBI_DEV_ERRORS", "on"),
    ?assertNot(asobi_lua_dev_errors:enabled()).

app_env_wins() ->
    application:set_env(asobi_lua, dev_errors, false),
    os:putenv("ASOBI_DEV_ERRORS", "true"),
    ?assertNot(asobi_lua_dev_errors:enabled()).

disabled_no_op() ->
    State = #{script => ~"game.lua"},
    ?assertEqual(
        State,
        asobi_lua_dev_errors:maybe_notify(handle_input, timeout, ~"p1", State)
    ),
    ?assertNot(meck:called(asobi_presence, send, '_')).

sends_script_error() ->
    application:set_env(asobi_lua, dev_errors, true),
    State = #{script => ~"priv/lua/game.lua"},
    State1 = asobi_lua_dev_errors:maybe_notify(handle_input, timeout, ~"p1", State),
    ?assert(is_integer(maps:get(dev_error_at, State1))),
    [{_, {_, send, [Player, {script_error, Payload}]}, ok}] = meck:history(asobi_presence),
    ?assertEqual(~"p1", Player),
    ?assertEqual(~"handle_input", maps:get(~"callback", Payload)),
    ?assertEqual(~"game.lua", maps:get(~"script", Payload)),
    ?assert(is_binary(maps:get(~"message", Payload))).

rate_limited() ->
    application:set_env(asobi_lua, dev_errors, true),
    State1 = asobi_lua_dev_errors:maybe_notify(handle_input, timeout, ~"p1", #{}),
    State2 = asobi_lua_dev_errors:maybe_notify(handle_input, timeout, ~"p1", State1),
    ?assertEqual(State1, State2),
    ?assertEqual(1, meck:num_calls(asobi_presence, send, '_')).

window_elapsed_sends() ->
    application:set_env(asobi_lua, dev_errors, true),
    Past = erlang:system_time(millisecond) - 5000,
    _ = asobi_lua_dev_errors:maybe_notify(handle_input, timeout, ~"p1", #{
        dev_error_at => Past
    }),
    ?assertEqual(1, meck:num_calls(asobi_presence, send, '_')).

timeout_message() ->
    application:set_env(asobi_lua, dev_errors, true),
    _ = asobi_lua_dev_errors:maybe_notify(handle_input, timeout, ~"p1", #{}),
    [{_, {_, send, [_, {script_error, Payload}]}, ok}] = meck:history(asobi_presence),
    ?assertEqual(~"callback timed out", maps:get(~"message", Payload)).

lua_error_formatted() ->
    application:set_env(asobi_lua, dev_errors, true),
    Reason = {lua_error, {badarith, ~"+", [nil, 1]}},
    _ = asobi_lua_dev_errors:maybe_notify(handle_input, Reason, ~"p1", #{}),
    [{_, {_, send, [_, {script_error, Payload}]}, ok}] = meck:history(asobi_presence),
    Msg = maps:get(~"message", Payload),
    ?assertMatch({_, _}, binary:match(Msg, ~"arithmetic")).

message_bounded() ->
    application:set_env(asobi_lua, dev_errors, true),
    Huge = binary:copy(~"x", 5000),
    _ = asobi_lua_dev_errors:maybe_notify(handle_input, {lua_error, Huge}, ~"p1", #{}),
    [{_, {_, send, [_, {script_error, Payload}]}, ok}] = meck:history(asobi_presence),
    ?assert(string:length(maps:get(~"message", Payload)) =< 500).

match_input_notifies() ->
    application:set_env(asobi_lua, dev_errors, true),
    Path = temp_script(
        ~"""
        match_size = 1
        function init(_) return { x = 0 } end
        function join(id, s) return s end
        function leave(id, s) return s end
        function handle_input(_, _, _) error('boom') end
        function tick(s) return s end
        function get_state(_, s) return s end
        """
    ),
    {ok, State} = asobi_lua_match:init(#{lua_script => Path}),
    {ok, State1} = asobi_lua_match:handle_input(~"p1", #{~"message" => ~"up"}, State),
    ?assert(is_integer(maps:get(dev_error_at, State1))),
    [{_, {_, send, [Player, {script_error, Payload}]}, ok}] = meck:history(asobi_presence),
    ?assertEqual(~"p1", Player),
    ?assertMatch({_, _}, binary:match(maps:get(~"message", Payload), ~"boom")).

world_cross_tick_rate_limited() ->
    application:set_env(asobi_lua, dev_errors, true),
    Path = temp_script(
        ~"""
        function zone_tick(entities, zs) return entities, zs end
        function handle_input(pid, input, entities) error('boom') end
        """
    ),
    {ok, LuaSt} = asobi_lua_loader:new(Path),
    ZoneState = #{lua_state => LuaSt, script => Path},
    erlang:put({asobi_lua_world, zone_state}, ZoneState),
    try
        {ok, _} = asobi_lua_world:handle_input(~"p1", #{~"a" => 1}, #{}),
        {_, _} = asobi_lua_world:zone_tick(#{}, ZoneState),
        {ok, _} = asobi_lua_world:handle_input(~"p1", #{~"a" => 1}, #{}),
        ?assertEqual(1, meck:num_calls(asobi_presence, send, '_'))
    after
        erlang:erase({asobi_lua_world, zone_state})
    end.

temp_script(Code) ->
    Name = "dev_errors_" ++ integer_to_list(erlang:unique_integer([positive])) ++ ".lua",
    Path = filename:join([filename:basedir(user_cache, "asobi_lua_tests"), Name]),
    ok = filelib:ensure_dir(Path),
    ok = file:write_file(Path, Code),
    Path.
