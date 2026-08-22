-module(asobi_lua_vm_tests).
-include_lib("eunit/include/eunit.hrl").

%% ADR 0015. The point of these is parity plus the one behaviour that genuinely
%% differs: under `owned` a runaway callback costs the state, not the tick.

-spec fixture(string()) -> file:filename_all().
fixture(Name) ->
    Dir =
        case code:lib_dir(asobi) of
            {error, bad_name} -> error(asobi_not_loaded);
            D -> D
        end,
    filename:absname(filename:join([Dir, "test", "fixtures", "lua", Name])).

with_mode(Mode, Fun) ->
    Prev = application:get_env(asobi, lua_vm_mode),
    application:set_env(asobi, lua_vm_mode, Mode),
    try
        Fun()
    after
        case Prev of
            {ok, V} -> application:set_env(asobi, lua_vm_mode, V);
            undefined -> application:unset_env(asobi, lua_vm_mode)
        end
    end.

zone_state(Script) ->
    Config = #{game_config => #{lua_script => Script}},
    ZS = asobi_lua_world:init_zone_state(Config, #{}),
    erlang:erase({asobi_lua_world, zone_state}),
    ZS.

vm_test_() ->
    [
        {"copy mode hands back a raw Luerl state", fun copy_mode_is_unchanged/0},
        {"owned mode hands back a VM handle", fun owned_mode_returns_a_handle/0},
        {"both modes tick a zone identically", fun both_modes_agree/0},
        {"both modes apply input identically", fun both_modes_agree_on_input/0},
        {"a dead VM reports vm_down rather than crashing", fun dead_vm_is_reported/0},
        {"release stops the VM", fun release_stops_the_vm/0},
        {"a throwaway probe never starts a VM", fun probe_states_are_copied/0},
        {"the mode defaults to copy", fun default_mode_is_copy/0}
    ].

default_mode_is_copy() ->
    Prev = application:get_env(asobi, lua_vm_mode),
    application:unset_env(asobi, lua_vm_mode),
    try
        ?assertEqual(copy, asobi_lua_loader:vm_mode())
    after
        case Prev of
            {ok, V} -> application:set_env(asobi, lua_vm_mode, V);
            undefined -> ok
        end
    end.

copy_mode_is_unchanged() ->
    with_mode(copy, fun() ->
        #{lua_state := St} = zone_state(fixture("config_move_world.lua")),
        ?assertNot(asobi_lua_vm:is_handle(St))
    end).

owned_mode_returns_a_handle() ->
    with_mode(owned, fun() ->
        #{lua_state := St} = ZS = zone_state(fixture("config_move_world.lua")),
        ?assert(asobi_lua_vm:is_handle(St)),
        ?assert(asobi_lua_vm:is_alive(St)),
        asobi_lua_loader:release(maps:get(lua_state, ZS))
    end).

%% The load-bearing assertion of the whole change: a bridge cannot tell.
both_modes_agree() ->
    Script = fixture("config_move_world.lua"),
    Entities = #{~"p1" => #{type => ~"player", x => 1.0, y => 2.0}},
    Copy = with_mode(copy, fun() -> tick_once(Script, Entities) end),
    Owned = with_mode(owned, fun() -> tick_once(Script, Entities) end),
    ?assertEqual(Copy, Owned).

tick_once(Script, Entities) ->
    ZS = zone_state(Script),
    {Ents, ZS1} = asobi_lua_world:zone_tick(Entities, ZS),
    asobi_lua_loader:release(maps:get(lua_state, ZS1)),
    erlang:erase({asobi_lua_world, zone_state}),
    Ents.

both_modes_agree_on_input() ->
    Script = fixture("config_move_world.lua"),
    Input = #{~"kind" => ~"move", ~"x" => 42, ~"y" => 7},
    Copy = with_mode(copy, fun() -> input_once(Script, Input) end),
    Owned = with_mode(owned, fun() -> input_once(Script, Input) end),
    ?assertMatch(#{~"p1" := #{x := 42, y := 7}}, Owned),
    ?assertEqual(Copy, Owned).

input_once(Script, Input) ->
    ZS = zone_state(Script),
    {_, ZS1} = asobi_lua_world:zone_tick(#{}, ZS),
    {ok, Entities} = asobi_lua_world:handle_input(~"p1", Input, #{}),
    asobi_lua_loader:release(maps:get(lua_state, ZS1)),
    erlang:erase({asobi_lua_world, zone_state}),
    Entities.

%% A handle whose VM has died is still a handle. Dispatching on liveness instead
%% of shape would hand the tuple to luerl:encode/2 and crash the zone.
dead_vm_is_reported() ->
    with_mode(owned, fun() ->
        #{lua_state := St} = zone_state(fixture("config_move_world.lua")),
        asobi_lua_loader:release(St),
        ?assert(asobi_lua_vm:is_handle(St)),
        ?assertNot(asobi_lua_vm:is_alive(St)),
        ?assertEqual({nil, St}, asobi_lua_loader:encode(#{~"a" => 1}, St)),
        ?assertEqual(nil, asobi_lua_loader:decode(nil, St)),
        ?assertEqual({error, vm_down}, asobi_lua_loader:call(zone_tick, [nil, nil], St, 100)),
        ?assertNot(asobi_lua_loader:is_defined(zone_tick, St))
    end).

release_stops_the_vm() ->
    with_mode(owned, fun() ->
        #{lua_state := {asobi_lua_vm, Pid} = St} = zone_state(fixture("config_move_world.lua")),
        ?assert(is_process_alive(Pid)),
        asobi_lua_loader:release(St),
        ?assertNot(is_process_alive(Pid))
    end).

%% A probe state answers one question and is dropped, so an owned VM there would
%% be a process nothing ever stops.
probe_states_are_copied() ->
    with_mode(owned, fun() ->
        Before = erlang:system_info(process_count),
        Config = #{
            mode => ~"test",
            game_config => #{lua_script => fixture("config_game_type_world.lua")}
        },
        {ok, _} = asobi_lua_world:generate_world(0, Config),
        ?assert(erlang:system_info(process_count) =< Before + 2)
    end).

%% A refused join must not advance the game state - otherwise a client drives a
%% script by being turned away over and over. Under `copy` that revert is free
%% (the mutated state is simply dropped); under `owned` the mutation has already
%% happened inside the VM, and this is the test that caught it not being undone.
join_refusal_reverts_test_() ->
    [
        {"copy mode reverts a refused join", fun() -> assert_refusal_reverts(copy) end},
        {"owned mode reverts a refused join", fun() -> assert_refusal_reverts(owned) end}
    ].

assert_refusal_reverts(Mode) ->
    with_mode(Mode, fun() ->
        {ok, State0} = asobi_lua_match:init(#{lua_script => fixture("join_refuse.lua")}),
        {error, _} = asobi_lua_match:join(~"silent", State0),
        {error, _} = asobi_lua_match:join(~"silent", State0),
        {ok, State1} = asobi_lua_match:join(~"p1", #{~"code" => ~"OPEN"}, State0),
        #{~"attempts" := Attempts} = asobi_lua_match:get_state(~"p1", State1),
        ?assertEqual(1, Attempts),
        asobi_lua_loader:release(maps:get(lua_state, State1))
    end).

%% The same property one level down, so a regression is diagnosed at the
%% primitive rather than through a match.
revert_undoes_the_last_call_test_() ->
    [
        {"copy mode: dropping the state is the revert", fun() -> assert_revert(copy) end},
        {"owned mode: the VM is asked to revert", fun() -> assert_revert(owned) end}
    ].

assert_revert(Mode) ->
    with_mode(Mode, fun() ->
        %% new/3, not new/1: new/1 is always the copying path, so an "owned"
        %% case built on it would silently test copy twice.
        {ok, St} = asobi_lua_loader:new(fixture("counter.lua"), 2000, fun(S) -> S end),
        ?assertEqual(Mode =:= owned, asobi_lua_vm:is_handle(St)),
        {ok, [One | _], St1} = asobi_lua_loader:call(bump, [], St, 1000),
        ?assertEqual(1, trunc(One)),
        {ok, [Two | _], _St2} = asobi_lua_loader:call(bump, [], St1, 1000),
        ?assertEqual(2, trunc(Two)),
        %% Undo the second bump. Under `copy` that means carrying on with St1;
        %% under `owned` St1 and St2 are the same handle and only the VM can do it.
        Reverted = asobi_lua_loader:revert(St1),
        {ok, [Again | _], St3} = asobi_lua_loader:call(bump, [], Reverted, 1000),
        ?assertEqual(2, trunc(Again)),
        asobi_lua_loader:release(St3)
    end).
