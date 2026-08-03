-module(prop_lua_input_robustness).
-include_lib("eunit/include/eunit.hrl").
-undef(LET).
-include_lib("proper/include/proper.hrl").

%% PropEr property: handle_input/3 must NEVER crash the calling
%% process regardless of what shape of map a client sends. We
%% generate random nested input maps and assert the bridge always
%% returns {ok, map()} — even when the Lua-side handle_input
%% throws because the input doesn't have the expected fields.

-define(NUMTESTS, 25).
-define(PD_KEY, {asobi_lua_world, zone_state}).

prop_input_robust_test_() ->
    {timeout, 60,
        ?_assert(
            proper:quickcheck(prop_random_input(), [
                {numtests, ?NUMTESTS}, {to_file, user}
            ])
        )}.

prop_random_input() ->
    ?FORALL(
        Inputs,
        proper_types:list(input_payload()),
        run_inputs(Inputs)
    ).

input_payload() ->
    ?LET(
        Pairs,
        proper_types:list({key(), val()}),
        maps:from_list(Pairs)
    ).

key() ->
    proper_types:elements([
        ~"kind", ~"x", ~"y", ~"shoot", ~"target", ~"surprise", ~"123"
    ]).

val() ->
    proper_types:oneof([
        proper_types:boolean(),
        proper_types:integer(-100, 100),
        proper_types:elements([~"move", ~"shoot", ~"junk", ~""]),
        proper_types:list(proper_types:integer(-10, 10))
    ]).

%% --- Runner ---

-spec run_inputs([map()]) -> boolean().
run_inputs(Inputs) ->
    erlang:erase(?PD_KEY),
    {ok, ZoneStates} = asobi_lua_world:generate_world(0, fixture_config()),
    case maps:get({0, 0}, ZoneStates, undefined) of
        undefined ->
            false;
        Z0 ->
            try
                %% Prime the proc dict so handle_input has a Lua state.
                {_, _Z1} = asobi_lua_world:zone_tick(#{}, Z0),
                lists:all(fun check_input/1, Inputs)
            after
                erlang:erase(?PD_KEY)
            end
    end.

check_input(Input) ->
    %% The bridge guarantees `{ok, _}` — the second element is whatever
    %% Lua's handle_input returned, decoded. Empty entities come back
    %% as `[]` (Luerl can't distinguish an empty table from an empty
    %% list), populated entities come back as `#{}`. Both shapes are
    %% valid; the contract is "no crash, no other tag".
    case asobi_lua_world:handle_input(~"prop_player", Input, #{}) of
        {ok, M} when is_map(M) -> true;
        {ok, []} -> true;
        _ -> false
    end.

fixture_config() ->
    #{game_config => #{lua_script => fixture_path("config_move_world.lua")}}.

fixture_path(Name) ->
    case code:lib_dir(asobi) of
        {error, _} -> error(asobi_not_loaded);
        Dir -> filename:join([Dir, "test", "fixtures", "lua", Name])
    end.
