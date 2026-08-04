-module(asobi_telemetry_tests).

-include_lib("eunit/include/eunit.hrl").

%% #312: setup/0's attach list was hand-maintained next to the emitters and
%% had drifted to 24 of the 35 events - the missing eleven being, aside from
%% auth_cache, exactly the failure and abuse signals someone turns the debug
%% logger on to see. Derive the emitted set from the module's own abstract
%% code so the list cannot silently fall behind an emitter again.
attach_list_covers_every_emitted_event_test() ->
    Declared = lists:sort(asobi_telemetry:events()),
    Emitted = emitted_events(),
    ?assertEqual([], Emitted -- Declared, "emitted but not attached by setup/0"),
    ?assertEqual([], Declared -- Emitted, "attached by setup/0 but never emitted"),
    ?assertEqual(Declared, lists:usort(asobi_telemetry:events())).

setup_attaches_a_handler_to_every_event_test() ->
    {ok, _} = application:ensure_all_started(telemetry),
    _ = telemetry:detach(~"asobi-metrics-logger"),
    ok = asobi_telemetry:setup(),
    try
        Attached = [Ev || #{event_name := Ev} <- telemetry:list_handlers([asobi])],
        ?assertEqual([], asobi_telemetry:events() -- Attached)
    after
        telemetry:detach(~"asobi-metrics-logger")
    end.

%% Every event name passed as a literal to telemetry:execute/3 anywhere in
%% asobi_telemetry. Reading the compiled abstract code rather than grepping
%% means a new emitter is picked up the moment it compiles.
%% get_object_code/1 rather than which/1: under cover the latter answers
%% `cover_compiled`, and the instrumented forms are not the ones we want to
%% read anyway.
emitted_events() ->
    {asobi_telemetry, Beam, _} = code:get_object_code(asobi_telemetry),
    {ok, {_, [{abstract_code, {_, Forms}}]}} = beam_lib:chunks(Beam, [abstract_code]),
    lists:usort(collect_execute_calls(Forms, [])).

collect_execute_calls(
    {call, _, {remote, _, {atom, _, telemetry}, {atom, _, execute}}, [EventArg | _]} = Node,
    Acc
) ->
    Acc1 =
        case literal_atom_list(EventArg) of
            {ok, Name} -> [Name | Acc];
            error -> Acc
        end,
    collect_execute_calls(tuple_to_list(Node), Acc1);
collect_execute_calls(Node, Acc) when is_tuple(Node) ->
    collect_execute_calls(tuple_to_list(Node), Acc);
collect_execute_calls([H | T], Acc) ->
    collect_execute_calls(T, collect_execute_calls(H, Acc));
collect_execute_calls(_, Acc) ->
    Acc.

literal_atom_list({nil, _}) ->
    {ok, []};
literal_atom_list({cons, _, {atom, _, Atom}, Rest}) ->
    case literal_atom_list(Rest) of
        {ok, Tail} -> {ok, [Atom | Tail]};
        error -> error
    end;
literal_atom_list(_) ->
    error.

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
