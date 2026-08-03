-module(prop_lua_error_containment).
-include_lib("eunit/include/eunit.hrl").
-undef(LET).
-include_lib("proper/include/proper.hrl").

%% PropEr property for asobi_lua_world's error-containment contract:
%%
%%   Random sequences of zone_tick / handle_input calls — including
%%   payloads that intentionally crash the Lua VM (`error()`, nil-index,
%%   stack overflow, type error) — never blow up the calling process and
%%   always return a value of the correct shape:
%%     - zone_tick returns {map(), map()}
%%     - handle_input returns {ok, map()}
%%
%% The bridge logs lua errors and returns the previous (entities, state)
%% so a misbehaving Lua callback can't escalate to a zone-process crash.

-define(NUMTESTS, list_to_integer(os:getenv("PROPER_NUMTESTS", "30"))).
-define(PD_KEY, {asobi_lua_world, zone_state}).

lua_error_containment_test_() ->
    {timeout, 60,
        ?_assert(
            proper:quickcheck(prop_lua_error_containment(), [
                {numtests, ?NUMTESTS}, {to_file, user}
            ])
        )}.

%% --- Property ---

prop_lua_error_containment() ->
    ?FORALL(
        Plan,
        plan(),
        run_plan(narrow_plan(Plan))
    ).

plan() ->
    proper_types:list(op()).

op() ->
    proper_types:oneof([
        {tick},
        {tick_crash, tick_crash_mode()},
        {input, player(), proper_types:oneof([clean, input_crash_mode()])}
    ]).

%% zone_tick still runs under bounded_eval (TICK_TIMEOUT) so infinite_loop
%% is contained.
tick_crash_mode() ->
    proper_types:elements([
        ~"error", ~"type_error", ~"arith_error", ~"stack_overflow", ~"infinite_loop"
    ]).

%% handle_input intentionally has no wall-clock budget per ADR 0002, so
%% `infinite_loop` is excluded from the input crash modes — feeding it
%% would actually wedge the property runner.
input_crash_mode() ->
    proper_types:elements([
        ~"error", ~"type_error", ~"arith_error", ~"stack_overflow"
    ]).

player() ->
    proper_types:elements([~"e1", ~"e2", ~"e3"]).

%% --- Runner ---

-spec run_plan([term()]) -> boolean().
run_plan(Plan) ->
    erlang:erase(?PD_KEY),
    {ok, ZoneStates} = asobi_lua_world:generate_world(0, fixture_config()),
    case maps:get({0, 0}, ZoneStates, undefined) of
        undefined ->
            io:format(user, "fixture missing zone (0,0): ~p~n", [ZoneStates]),
            false;
        Z0 ->
            try
                exec(Plan, Z0, #{})
            after
                erlang:erase(?PD_KEY)
            end
    end.

-spec exec([term()], map(), map()) -> boolean().
exec([], _Zone, _Entities) ->
    true;
exec([{tick} | Rest], Zone, Entities) ->
    case asobi_lua_world:zone_tick(Entities, Zone) of
        {Entities1, Zone1} when is_map(Zone1) ->
            exec(Rest, Zone1, Entities1);
        Other ->
            io:format(user, "zone_tick returned bad shape: ~p~n", [Other]),
            false
    end;
exec([{tick_crash, Mode} | Rest], Zone, Entities) ->
    Zone1 = Zone#{~"crash_next" => Mode},
    case asobi_lua_world:zone_tick(Entities, Zone1) of
        {Entities1, Zone2} when is_map(Zone2) ->
            %% The bridge swallowed the error (returns {Entities, ZoneState}
            %% from the original maps); we just verify shape and continue.
            exec(Rest, Zone2, Entities1);
        Other ->
            io:format(user, "zone_tick crash didn't contain: ~p~n", [Other]),
            false
    end;
exec([{input, P, clean} | Rest], Zone, Entities) when is_binary(P) ->
    Input = #{~"kind" => ~"move", ~"x" => 1, ~"y" => 1},
    case asobi_lua_world:handle_input(P, Input, Entities) of
        {ok, Entities1} when is_map(Entities1) ->
            exec(Rest, Zone, Entities1);
        Other ->
            io:format(user, "handle_input(clean) returned bad shape: ~p~n", [Other]),
            false
    end;
exec([{input, P, Mode} | Rest], Zone, Entities) when is_binary(P), is_binary(Mode) ->
    Input = #{~"kind" => ~"crash", ~"crash_mode" => Mode},
    case asobi_lua_world:handle_input(P, Input, Entities) of
        {ok, Entities1} when is_map(Entities1) ->
            exec(Rest, Zone, Entities1);
        Other ->
            io:format(user, "handle_input(~s) didn't contain: ~p~n", [Mode, Other]),
            false
    end.

-spec narrow_plan(term()) -> [term()].
narrow_plan(L) when is_list(L) -> L.

%% --- Fixture ---

fixture_config() ->
    #{game_config => #{lua_script => fixture_path("error_world.lua")}}.

fixture_path(Name) ->
    case code:lib_dir(asobi) of
        {error, _} ->
            error(asobi_not_loaded);
        Dir ->
            filename:join([Dir, "test", "fixtures", "lua", Name])
    end.
