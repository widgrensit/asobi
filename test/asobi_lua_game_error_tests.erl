-module(asobi_lua_game_error_tests).

-include_lib("eunit/include/eunit.hrl").

emit_details_are_bounded_and_pii_free_test() ->
    {ok, _} = application:ensure_all_started(telemetry),
    Self = self(),
    Ref = make_ref(),
    telemetry:attach(Ref, [asobi, error], fun(_E, _M, Meta, _) -> Self ! {ev, Meta} end, []),
    try
        %% A path is reduced to its basename; a Lua error carrying player input
        %% classifies to runtime_error and the raw reason must NOT reach details.
        asobi_lua_game_error:emit(
            post_tick, {lua_error, ~"bad move for player Bob"}, ~"/games/g1/arena.lua"
        ),
        receive
            {ev, #{kind := Kind, details := D}} ->
                ?assertEqual(lua_error, Kind),
                ?assertEqual(post_tick, maps:get(callback, D)),
                ?assertEqual(~"arena.lua", maps:get(script, D)),
                ?assertEqual(runtime_error, maps:get(reason_class, D)),
                %% no raw reason / free-form message leaks through
                ?assertEqual(error, maps:find(reason, D)),
                ?assertEqual(error, maps:find(message, D))
        after 1000 -> erlang:error(no_event)
        end,
        asobi_lua_game_error:emit(tick, timeout, ~"arena.lua"),
        receive
            {ev, #{details := D2}} -> ?assertEqual(timeout, maps:get(reason_class, D2))
        after 1000 -> erlang:error(no_event)
        end
    after
        telemetry:detach(Ref)
    end.

non_binary_script_is_placeholder_test() ->
    {ok, _} = application:ensure_all_started(telemetry),
    Self = self(),
    Ref = make_ref(),
    telemetry:attach(Ref, [asobi, error], fun(_E, _M, Meta, _) -> Self ! {ev, Meta} end, []),
    try
        asobi_lua_game_error:emit(leave, some_reason, undefined),
        receive
            {ev, #{details := D}} -> ?assertEqual(~"<unknown>", maps:get(script, D))
        after 1000 -> erlang:error(no_event)
        end
    after
        telemetry:detach(Ref)
    end.
