-module(asobi_zone_manager_tests).
-include_lib("eunit/include/eunit.hrl").

-define(BASE_OPTS, #{
    world_id => ~"test-world",
    grid_size => 3,
    zone_size => 100,
    zone_config => #{
        world_id => ~"test-world",
        ticker_pid => self(),
        game_module => asobi_test_world_game
    }
}).

setup() ->
    case whereis(nova_scope) of
        undefined -> pg:start_link(nova_scope);
        _ -> ok
    end,
    ok.

cleanup(_) ->
    ok.

start_manager() ->
    start_manager(#{}).

start_manager(Overrides) ->
    {ok, ZoneSup} = asobi_zone_sup:start_link(),
    unlink(ZoneSup),
    Opts = maps:merge(?BASE_OPTS, Overrides#{zone_sup => ZoneSup}),
    {ok, Pid} = asobi_zone_manager:start_link(Opts),
    unlink(Pid),
    #{mgr => Pid, zone_sup => ZoneSup}.

stop_manager(#{mgr := Pid, zone_sup := ZoneSup}) ->
    catch exit(Pid, shutdown),
    catch exit(ZoneSup, shutdown),
    timer:sleep(10),
    ok.

zone_manager_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        {"starts successfully", fun starts_ok/0},
        {"ensure_zone creates zone on demand", fun ensure_zone_creates/0},
        {"ensure_zone returns existing zone", fun ensure_zone_existing/0},
        {"get_zone returns not_loaded for missing", fun get_zone_not_loaded/0},
        {"get_zone returns pid for loaded", fun get_zone_loaded/0},
        {"get_active_zones returns all pids", fun get_active_zones/0},
        {"zone_terminated cleans up", fun zone_terminated_cleanup/0},
        {"DOWN monitor cleans up", fun down_monitor_cleanup/0},
        {"max_active_zones enforced", fun max_zones_enforced/0},
        {"pre_warm spawns all zones", fun pre_warm_all/0},
        {"touch_zone resets timer", fun touch_zone_resets/0},
        {"release_zone marks stale", fun release_zone_marks_stale/0},
        {"per-coord initial zone_state reaches zone init", fun initial_zone_states_threaded/0},
        {"missing per-coord state leaves zone_state default", fun initial_zone_states_default/0}
    ]}.

starts_ok() ->
    Ctx = start_manager(),
    ?assertMatch(#{mgr := Pid} when is_pid(Pid), Ctx),
    stop_manager(Ctx).

ensure_zone_creates() ->
    Ctx = #{mgr := Mgr} = start_manager(),
    {ok, ZonePid} = asobi_zone_manager:ensure_zone(Mgr, {0, 0}),
    ?assert(is_pid(ZonePid)),
    ?assert(is_process_alive(ZonePid)),
    stop_manager(Ctx).

ensure_zone_existing() ->
    Ctx = #{mgr := Mgr} = start_manager(),
    {ok, Pid1} = asobi_zone_manager:ensure_zone(Mgr, {1, 1}),
    {ok, Pid2} = asobi_zone_manager:ensure_zone(Mgr, {1, 1}),
    ?assertEqual(Pid1, Pid2),
    stop_manager(Ctx).

get_zone_not_loaded() ->
    Ctx = #{mgr := Mgr} = start_manager(),
    ?assertEqual(not_loaded, asobi_zone_manager:get_zone(Mgr, {2, 2})),
    stop_manager(Ctx).

get_zone_loaded() ->
    Ctx = #{mgr := Mgr} = start_manager(),
    {ok, ZonePid} = asobi_zone_manager:ensure_zone(Mgr, {0, 1}),
    ?assertEqual({ok, ZonePid}, asobi_zone_manager:get_zone(Mgr, {0, 1})),
    stop_manager(Ctx).

get_active_zones() ->
    Ctx = #{mgr := Mgr} = start_manager(),
    {ok, P1} = asobi_zone_manager:ensure_zone(Mgr, {0, 0}),
    {ok, P2} = asobi_zone_manager:ensure_zone(Mgr, {1, 0}),
    Active = asobi_zone_manager:get_active_zones(Mgr),
    ?assertEqual(2, length(Active)),
    ?assert(lists:member(P1, Active)),
    ?assert(lists:member(P2, Active)),
    stop_manager(Ctx).

zone_terminated_cleanup() ->
    Ctx = #{mgr := Mgr} = start_manager(),
    {ok, ZonePid} = asobi_zone_manager:ensure_zone(Mgr, {0, 0}),
    exit(ZonePid, kill),
    timer:sleep(50),
    ?assertEqual(not_loaded, asobi_zone_manager:get_zone(Mgr, {0, 0})),
    stop_manager(Ctx).

down_monitor_cleanup() ->
    Ctx = #{mgr := Mgr} = start_manager(),
    {ok, ZonePid} = asobi_zone_manager:ensure_zone(Mgr, {2, 1}),
    exit(ZonePid, kill),
    timer:sleep(50),
    ?assertEqual(not_loaded, asobi_zone_manager:get_zone(Mgr, {2, 1})),
    %% Can recreate after cleanup
    {ok, NewPid} = asobi_zone_manager:ensure_zone(Mgr, {2, 1}),
    ?assert(is_pid(NewPid)),
    ?assertNotEqual(ZonePid, NewPid),
    stop_manager(Ctx).

max_zones_enforced() ->
    Ctx = #{mgr := Mgr} = start_manager(#{max_active_zones => 2}),
    {ok, _} = asobi_zone_manager:ensure_zone(Mgr, {0, 0}),
    {ok, _} = asobi_zone_manager:ensure_zone(Mgr, {1, 0}),
    ?assertEqual({error, max_zones_reached}, asobi_zone_manager:ensure_zone(Mgr, {2, 0})),
    stop_manager(Ctx).

pre_warm_all() ->
    Ctx = #{mgr := Mgr} = start_manager(#{grid_size => 2}),
    ok = asobi_zone_manager:pre_warm(Mgr),
    Active = asobi_zone_manager:get_active_zones(Mgr),
    ?assertEqual(4, length(Active)),
    ?assertMatch({ok, _}, asobi_zone_manager:get_zone(Mgr, {0, 0})),
    ?assertMatch({ok, _}, asobi_zone_manager:get_zone(Mgr, {0, 1})),
    ?assertMatch({ok, _}, asobi_zone_manager:get_zone(Mgr, {1, 0})),
    ?assertMatch({ok, _}, asobi_zone_manager:get_zone(Mgr, {1, 1})),
    stop_manager(Ctx).

touch_zone_resets() ->
    Ctx = #{mgr := Mgr} = start_manager(),
    {ok, _} = asobi_zone_manager:ensure_zone(Mgr, {0, 0}),
    ok = asobi_zone_manager:touch_zone(Mgr, {0, 0}),
    timer:sleep(10),
    ?assertMatch({ok, _}, asobi_zone_manager:get_zone(Mgr, {0, 0})),
    stop_manager(Ctx).

release_zone_marks_stale() ->
    Ctx = #{mgr := Mgr} = start_manager(),
    {ok, _} = asobi_zone_manager:ensure_zone(Mgr, {0, 0}),
    ok = asobi_zone_manager:release_zone(Mgr, {0, 0}),
    timer:sleep(10),
    ?assertMatch({ok, _}, asobi_zone_manager:get_zone(Mgr, {0, 0})),
    stop_manager(Ctx).

%% Regression: per-coord state from generate_world/2 must reach the zone's
%% init. Before this fix, the world server discarded ZoneStates entirely so
%% callbacks like asobi_lua_world:handle_input/3 (which need lua_state in
%% zone_state) silently no-opped, breaking any Lua game's input handling.
initial_zone_states_threaded() ->
    Ctx = #{mgr := Mgr} = start_manager(),
    States = #{
        {0, 0} => #{marker => zero_zero, lua_state => fake_lua_zero},
        {1, 1} => #{marker => one_one, lua_state => fake_lua_one}
    },
    ok = asobi_zone_manager:set_initial_zone_states(Mgr, States),
    {ok, P00} = asobi_zone_manager:ensure_zone(Mgr, {0, 0}),
    {ok, P11} = asobi_zone_manager:ensure_zone(Mgr, {1, 1}),
    #{zone_state := ZS00} = sys:get_state(P00),
    #{zone_state := ZS11} = sys:get_state(P11),
    ?assertMatch(#{marker := zero_zero, lua_state := fake_lua_zero}, ZS00),
    ?assertMatch(#{marker := one_one, lua_state := fake_lua_one}, ZS11),
    stop_manager(Ctx).

initial_zone_states_default() ->
    Ctx = #{mgr := Mgr} = start_manager(),
    %% No set_initial_zone_states call — zone should still start with the
    %% default empty zone_state, not crash.
    {ok, P} = asobi_zone_manager:ensure_zone(Mgr, {0, 0}),
    #{zone_state := ZS} = sys:get_state(P),
    ?assertEqual(#{}, ZS),
    stop_manager(Ctx).
