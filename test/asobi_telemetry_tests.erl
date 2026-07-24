-module(asobi_telemetry_tests).

-include_lib("eunit/include/eunit.hrl").

game_error_emits_single_event_test() ->
    {ok, _} = application:ensure_all_started(telemetry),
    Self = self(),
    Ref = make_ref(),
    telemetry:attach(
        Ref, [asobi, error], fun(_Event, M, Meta, _) -> Self ! {ev, M, Meta} end, []
    ),
    try
        asobi_telemetry:game_error(lua_error, #{callback => post_tick}),
        receive
            {ev, M, Meta} ->
                ?assertEqual(1, maps:get(count, M)),
                ?assertEqual(lua_error, maps:get(kind, Meta)),
                ?assertEqual(#{callback => post_tick}, maps:get(details, Meta))
        after 1000 -> ?assert(false)
        end,
        %% arity-1 keeps count/kind and defaults details to an empty map.
        asobi_telemetry:game_error(lua_error),
        receive
            {ev, M2, Meta2} ->
                ?assertEqual(1, maps:get(count, M2)),
                ?assertEqual(lua_error, maps:get(kind, Meta2)),
                ?assertEqual(#{}, maps:get(details, Meta2))
        after 1000 -> erlang:error(no_event)
        end
    after
        telemetry:detach(Ref)
    end.
