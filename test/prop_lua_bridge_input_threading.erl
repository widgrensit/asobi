-module(prop_lua_bridge_input_threading).
-include_lib("eunit/include/eunit.hrl").
-undef(LET).
-include_lib("proper/include/proper.hrl").

%% PropEr property for the asobi_lua_world bridge contract:
%%
%%   Once zone_tick/2 has run at least once for a given zone (priming
%%   the proc-dict-stashed Lua state), every subsequent handle_input/3
%%   call must invoke the Lua callback and return updated entities.
%%
%% This complements the existing eunit smoke test by exercising random
%% interleavings of zone_tick + handle_input across multiple players.
%% A regression where the bridge stops threading lua_state through the
%% proc dict (e.g. if zone_tick forgets to put/1, or handle_input forgets
%% to put/1 after a Lua call) would shrink to the minimal counterexample.

-define(NUMTESTS, list_to_integer(os:getenv("PROPER_NUMTESTS", "25"))).
-define(PD_KEY, {asobi_lua_world, zone_state}).

bridge_input_threading_test_() ->
    {timeout, 60,
        ?_assert(
            proper:quickcheck(prop_input_threading(), [{numtests, ?NUMTESTS}, {to_file, user}])
        )}.

%% --- Property ---

prop_input_threading() ->
    ?FORALL(
        Plan,
        plan(),
        run_plan(narrow_plan(Plan))
    ).

%% Plan: a list of operations exercising the bridge.
%%   - {tick}: call zone_tick to refresh the proc-dict state.
%%   - {input, PlayerId, X, Y}: call handle_input with a move payload;
%%     after the call we expect the entity for PlayerId to reflect (X, Y).
plan() ->
    proper_types:list(op()).

op() ->
    proper_types:oneof([
        {tick},
        {input, player(), coord(), coord()}
    ]).

player() ->
    proper_types:elements([~"p1", ~"p2", ~"p3", ~"p4"]).

coord() ->
    proper_types:integer(-50, 50).

%% --- Runner ---

-spec run_plan([term()]) -> boolean().
run_plan(Plan) ->
    erlang:erase(?PD_KEY),
    {ok, ZoneStates} = asobi_lua_world:generate_world(0, fixture_config()),
    case maps:get({0, 0}, ZoneStates, undefined) of
        undefined ->
            io:format(user, "fixture missing zone (0,0): ~p~n", [ZoneStates]),
            false;
        Z0Raw ->
            Z0 = asobi_lua_world:init_zone_state(fixture_config(), Z0Raw),
            try
                exec(Plan, Z0, #{}, #{}, false)
            after
                erlang:erase(?PD_KEY)
            end
    end.

%% exec(Plan, ZoneState, Entities, ExpectedAfterPrime, PrimedYet?)
-spec exec([term()], map(), map(), map(), boolean()) -> boolean().
exec([], _Zone, _Entities, _Expected, _Primed) ->
    true;
exec([{tick} | Rest], Zone, Entities, Expected, _Primed) ->
    case asobi_lua_world:zone_tick(Entities, Zone) of
        {Entities1, Zone1} when is_map(Zone1) ->
            exec(Rest, Zone1, Entities1, Expected, true)
    end;
exec([{input, P, X, Y} | Rest], Zone, Entities, Expected, Primed) when is_binary(P) ->
    Input = #{~"kind" => ~"move", ~"x" => X, ~"y" => Y},
    {ok, Entities1} = asobi_lua_world:handle_input(P, Input, Entities),
    case Primed of
        true ->
            %% Bridge contract: after a prior zone_tick, the move must land.
            %% Entity keys are atomized (x, y) - see widgrensit/asobi#270.
            case maps:get(P, Entities1, undefined) of
                #{x := X, y := Y} ->
                    Expected1 = Expected#{P => {X, Y}},
                    exec(Rest, Zone, Entities1, Expected1, Primed);
                Got ->
                    io:format(
                        user,
                        "input dropped for ~s: expected x=~p y=~p, got ~p~n",
                        [P, X, Y, Got]
                    ),
                    false
            end;
        false ->
            %% Without a prior zone_tick the bridge is contract-bound to be a
            %% no-op (no proc dict state to drive Lua). Verify entities are
            %% returned unchanged rather than corrupted.
            case Entities1 =:= Entities of
                true ->
                    exec(Rest, Zone, Entities, Expected, Primed);
                false ->
                    io:format(user, "no-op contract violated~n", []),
                    false
            end
    end.

-spec narrow_plan(term()) -> [term()].
narrow_plan(L) when is_list(L) -> L.

%% --- Fixture ---

fixture_config() ->
    #{game_config => #{lua_script => fixture_path("config_move_world.lua")}}.

fixture_path(Name) ->
    case code:lib_dir(asobi) of
        {error, _} ->
            error(asobi_not_loaded);
        Dir ->
            filename:join([Dir, "test", "fixtures", "lua", Name])
    end.
