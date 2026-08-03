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
        {"stale zone is reaped on sweep", fun stale_zone_reaped_on_sweep/0},
        {"an occupied zone survives a reap sweep against a stale timestamp",
            fun occupied_zone_survives_reap/0},
        {"revive_zone replaces a zone reaped under a caller holding its pid",
            fun revive_zone_replaces_reaped_zone/0},
        {"revive_zone returns the live zone when the coords were already recreated",
            fun revive_zone_returns_already_recreated_zone/0},
        {"revive_zone declines while the named zone is still running",
            fun revive_zone_declines_live_zone/0},
        {"per-coord initial zone_state reaches zone init", fun initial_zone_states_threaded/0},
        {"missing per-coord state leaves zone_state default", fun initial_zone_states_default/0}
    ]}.

starts_ok() ->
    Ctx = start_manager(),
    ?assertMatch(#{mgr := Pid} when is_pid(Pid), Ctx),
    stop_manager(Ctx).

ensure_zone_creates() ->
    Ctx = #{mgr := Mgr} = start_manager(),
    {ok, ZonePid, created} = asobi_zone_manager:ensure_zone(Mgr, {0, 0}),
    ?assert(is_pid(ZonePid)),
    ?assert(is_process_alive(ZonePid)),
    stop_manager(Ctx).

ensure_zone_existing() ->
    Ctx = #{mgr := Mgr} = start_manager(),
    {ok, Pid1, created} = asobi_zone_manager:ensure_zone(Mgr, {1, 1}),
    {ok, Pid2, existing} = asobi_zone_manager:ensure_zone(Mgr, {1, 1}),
    ?assertEqual(Pid1, Pid2),
    stop_manager(Ctx).

get_zone_not_loaded() ->
    Ctx = #{mgr := Mgr} = start_manager(),
    ?assertEqual(not_loaded, asobi_zone_manager:get_zone(Mgr, {2, 2})),
    stop_manager(Ctx).

get_zone_loaded() ->
    Ctx = #{mgr := Mgr} = start_manager(),
    {ok, ZonePid, created} = asobi_zone_manager:ensure_zone(Mgr, {0, 1}),
    ?assertEqual({ok, ZonePid}, asobi_zone_manager:get_zone(Mgr, {0, 1})),
    stop_manager(Ctx).

get_active_zones() ->
    Ctx = #{mgr := Mgr} = start_manager(),
    {ok, P1, created} = asobi_zone_manager:ensure_zone(Mgr, {0, 0}),
    {ok, P2, created} = asobi_zone_manager:ensure_zone(Mgr, {1, 0}),
    Active = asobi_zone_manager:get_active_zones(Mgr),
    ?assertEqual(2, length(Active)),
    ?assert(lists:member(P1, Active)),
    ?assert(lists:member(P2, Active)),
    stop_manager(Ctx).

zone_terminated_cleanup() ->
    Ctx = #{mgr := Mgr} = start_manager(),
    {ok, ZonePid, created} = asobi_zone_manager:ensure_zone(Mgr, {0, 0}),
    exit(ZonePid, kill),
    timer:sleep(50),
    ?assertEqual(not_loaded, asobi_zone_manager:get_zone(Mgr, {0, 0})),
    stop_manager(Ctx).

down_monitor_cleanup() ->
    Ctx = #{mgr := Mgr} = start_manager(),
    {ok, ZonePid, created} = asobi_zone_manager:ensure_zone(Mgr, {2, 1}),
    exit(ZonePid, kill),
    timer:sleep(50),
    ?assertEqual(not_loaded, asobi_zone_manager:get_zone(Mgr, {2, 1})),
    %% Can recreate after cleanup
    {ok, NewPid, created} = asobi_zone_manager:ensure_zone(Mgr, {2, 1}),
    ?assert(is_pid(NewPid)),
    ?assertNotEqual(ZonePid, NewPid),
    stop_manager(Ctx).

max_zones_enforced() ->
    Ctx = #{mgr := Mgr} = start_manager(#{max_active_zones => 2}),
    {ok, _, created} = asobi_zone_manager:ensure_zone(Mgr, {0, 0}),
    {ok, _, created} = asobi_zone_manager:ensure_zone(Mgr, {1, 0}),
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
    {ok, _, created} = asobi_zone_manager:ensure_zone(Mgr, {0, 0}),
    ok = asobi_zone_manager:touch_zone(Mgr, {0, 0}),
    timer:sleep(10),
    ?assertMatch({ok, _}, asobi_zone_manager:get_zone(Mgr, {0, 0})),
    stop_manager(Ctx).

release_zone_marks_stale() ->
    Ctx = #{mgr := Mgr} = start_manager(),
    {ok, _, created} = asobi_zone_manager:ensure_zone(Mgr, {0, 0}),
    ok = asobi_zone_manager:release_zone(Mgr, {0, 0}),
    timer:sleep(10),
    ?assertMatch({ok, _}, asobi_zone_manager:get_zone(Mgr, {0, 0})),
    stop_manager(Ctx).

%% Sanity check for the forced-sweep technique the next test relies on: a
%% genuinely-idle (released, never re-touched) zone is torn down once a reap
%% sweep runs past its idle_timeout. Triggers the sweep directly via the
%% manager's own reap_ref instead of waiting out ?REAP_INTERVAL.
stale_zone_reaped_on_sweep() ->
    Ctx = #{mgr := Mgr} = start_manager(#{idle_timeout => 20}),
    {ok, ZonePid, created} = asobi_zone_manager:ensure_zone(Mgr, {0, 0}),
    ok = asobi_zone_manager:release_zone(Mgr, {0, 0}),
    force_reap_sweep(Mgr),
    ?assertEqual(not_loaded, asobi_zone_manager:get_zone(Mgr, {0, 0})),
    ?assert(not is_process_alive(ZonePid)),
    stop_manager(Ctx).

%% Regression widgrensit/asobi#283, found via the prop_input_never_dropped
%% nightly flake (asobi#282): release_zone/2 backdates zone_last_active as
%% soon as a zone empties out, and nothing un-stales it on re-occupation - a
%% zone's own tick only touches the manager when it has live subscribers
%% (asobi_zone.erl, map_size(Subs) > 0), which this test's raw add_entity
%% deliberately has none of, mirroring how prop_input_never_dropped joins
%% players with no live session. Without asobi_zone declining `reap` while
%% it still holds entities (the actual fix, in asobi_zone.erl's
%% handle_cast(reap, ...)), a zone that empties and is then re-occupied
%% before the next reap sweep gets torn down out from under its occupant.
%% This is the integration-level proof: a real manager, a real zone, and a
%% forced sweep that would have reaped it under the old unconditional stop.
occupied_zone_survives_reap() ->
    Ctx = #{mgr := Mgr} = start_manager(#{idle_timeout => 20}),
    {ok, ZonePid, created} = asobi_zone_manager:ensure_zone(Mgr, {0, 0}),
    ok = asobi_zone:add_entity(ZonePid, <<"p1">>, #{type => ~"player", x => 0, y => 0}),
    timer:sleep(5),
    ok = asobi_zone_manager:release_zone(Mgr, {0, 0}),
    force_reap_sweep(Mgr),
    ?assertEqual({ok, ZonePid}, asobi_zone_manager:get_zone(Mgr, {0, 0})),
    ?assert(is_process_alive(ZonePid)),
    stop_manager(Ctx).

%% Regression widgrensit/asobi#283 (follow-up to the zone-side fix above):
%% ensure_zone/2 hands out a pid without a lease on it, so a zone that is
%% genuinely empty when the sweep fires still stops while a join is already in
%% flight against it. The joiner cannot recover by calling ensure_zone/2 again
%% - the ETS slot still points at the corpse until the manager has processed
%% the DOWN. Suspending the manager here queues the revive_zone call ahead of
%% that DOWN, which is exactly the ordering the race produces.
revive_zone_replaces_reaped_zone() ->
    Ctx = #{mgr := Mgr} = start_manager(),
    {ok, ZonePid, created} = asobi_zone_manager:ensure_zone(Mgr, {0, 0}),
    Self = self(),
    ok = sys:suspend(Mgr),
    _ = spawn(fun() -> Self ! {revived, asobi_zone_manager:revive_zone(Mgr, {0, 0}, ZonePid)} end),
    timer:sleep(20),
    exit(ZonePid, kill),
    timer:sleep(20),
    ok = sys:resume(Mgr),
    receive
        {revived, Result} ->
            ?assertMatch({ok, P, created} when is_pid(P), Result),
            {ok, NewPid, created} = Result,
            ?assertNotEqual(ZonePid, NewPid),
            ?assert(is_process_alive(NewPid)),
            ?assertEqual({ok, NewPid}, asobi_zone_manager:get_zone(Mgr, {0, 0}))
    after 2000 ->
        ?assert(false, timeout_waiting_for_revive)
    end,
    stop_manager(Ctx).

revive_zone_returns_already_recreated_zone() ->
    Ctx = #{mgr := Mgr} = start_manager(),
    {ok, ZonePid, created} = asobi_zone_manager:ensure_zone(Mgr, {1, 0}),
    exit(ZonePid, kill),
    timer:sleep(50),
    {ok, NewPid, created} = asobi_zone_manager:ensure_zone(Mgr, {1, 0}),
    ?assertEqual(
        {ok, NewPid, existing}, asobi_zone_manager:revive_zone(Mgr, {1, 0}, ZonePid)
    ),
    stop_manager(Ctx).

%% Backstop: a caller that reports a zone dead while it is demonstrably still
%% running must not get a second zone started over the live one.
revive_zone_declines_live_zone() ->
    Ctx = #{mgr := Mgr} = start_manager(),
    {ok, ZonePid, created} = asobi_zone_manager:ensure_zone(Mgr, {2, 2}),
    ?assertEqual(
        {error, zone_stopping}, asobi_zone_manager:revive_zone(Mgr, {2, 2}, ZonePid)
    ),
    ?assertEqual({ok, ZonePid}, asobi_zone_manager:get_zone(Mgr, {2, 2})),
    stop_manager(Ctx).

%% Sends the manager's own {reap_idle, Ref} message directly instead of
%% waiting out the real ?REAP_INTERVAL (10s), so the sweep runs immediately.
force_reap_sweep(Mgr) ->
    #{reap_ref := ReapRef} = sys:get_state(Mgr),
    Mgr ! {reap_idle, ReapRef},
    timer:sleep(20).

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
    {ok, P00, created} = asobi_zone_manager:ensure_zone(Mgr, {0, 0}),
    {ok, P11, created} = asobi_zone_manager:ensure_zone(Mgr, {1, 1}),
    #{zone_state := ZS00} = sys:get_state(P00),
    #{zone_state := ZS11} = sys:get_state(P11),
    ?assertMatch(#{marker := zero_zero, lua_state := fake_lua_zero}, ZS00),
    ?assertMatch(#{marker := one_one, lua_state := fake_lua_one}, ZS11),
    stop_manager(Ctx).

initial_zone_states_default() ->
    Ctx = #{mgr := Mgr} = start_manager(),
    %% No set_initial_zone_states call — zone should still start with the
    %% default empty zone_state, not crash.
    {ok, P, created} = asobi_zone_manager:ensure_zone(Mgr, {0, 0}),
    #{zone_state := ZS} = sys:get_state(P),
    ?assertEqual(#{}, ZS),
    stop_manager(Ctx).
