-module(asobi_zone_lifecycle_hooks_tests).
-include_lib("eunit/include/eunit.hrl").

%% widgrensit/asobi#574: on_zone_loaded/2 and on_zone_unloaded/2 were declared,
%% bridged and documented, and never dispatched. These drive a real lazy zone
%% load through asobi_world_instance and assert the hook ran AND that what it
%% returned reached the zone's zone_state - the two things a behaviour_info/1
%% membership assertion cannot tell apart from a dead callback.

-define(GAME, asobi_zone_seed_game).
-define(PROBE, asobi_zone_seed_probe).
-define(BASE_CONFIG, #{
    game_module => ?GAME,
    grid_size => 3,
    zone_size => 100,
    tick_rate => 50,
    max_players => 10,
    view_radius => 0
}).

setup() ->
    case whereis(nova_scope) of
        undefined -> pg:start_link(nova_scope);
        _ -> ok
    end,
    meck:new(asobi_repo, [no_link]),
    meck:expect(asobi_repo, insert, fun(_CS) -> {ok, #{}} end),
    meck:expect(asobi_repo, insert, fun(_CS, _Opts) -> {ok, #{}} end),
    meck:new(asobi_presence, [non_strict, no_link]),
    meck:expect(asobi_presence, send, fun(_PlayerId, _Msg) -> ok end),
    ok.

cleanup(_) ->
    meck:unload(asobi_presence),
    meck:unload(asobi_repo),
    ok.

start_world(Overrides) ->
    unregister_probe(),
    true = register(?PROBE, self()),
    Config = maps:merge(?BASE_CONFIG, Overrides),
    {ok, InstancePid} = asobi_world_instance:start_link(Config),
    unlink(InstancePid),
    timer:sleep(50),
    #{
        instance_pid => InstancePid,
        world_pid => asobi_world_instance:get_child(InstancePid, asobi_world_server),
        zone_mgr => asobi_world_instance:get_child(InstancePid, asobi_zone_manager)
    }.

stop_world(#{instance_pid := InstancePid}) ->
    exit(InstancePid, shutdown),
    timer:sleep(20),
    unregister_probe(),
    flush(),
    ok.

unregister_probe() ->
    case whereis(?PROBE) of
        undefined -> ok;
        _ -> unregister(?PROBE)
    end,
    ok.

flush() ->
    receive
        _ -> flush()
    after 0 -> ok
    end.

await(Msg, Timeout) ->
    receive
        Msg -> ok
    after Timeout -> timeout
    end.

zone_lifecycle_hooks_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        {"a lazily-created zone runs on_zone_loaded/2", fun lazy_zone_runs_on_zone_loaded/0},
        {"what on_zone_loaded/2 returns is the zone's zone_state",
            fun seed_reaches_the_zone_state/0},
        {"a pre-warmed zone does not run on_zone_loaded/2", fun prewarmed_zone_is_not_seeded/0},
        {"a stopped zone runs on_zone_unloaded/2", fun stopped_zone_runs_on_zone_unloaded/0},
        {"a re-created zone is seeded again", fun recreated_zone_is_seeded_again/0}
    ]}.

lazy_zone_runs_on_zone_loaded() ->
    Ctx = start_world(#{lazy_zones => true}),
    #{world_pid := Pid} = Ctx,
    ?assertEqual(ok, asobi_world_server:join(Pid, ~"p1")),
    ?assertEqual(ok, await({on_zone_loaded, {1, 1}}, 1000)),
    stop_world(Ctx).

seed_reaches_the_zone_state() ->
    Ctx = start_world(#{lazy_zones => true}),
    #{world_pid := Pid, zone_mgr := Mgr} = Ctx,
    ?assertEqual(ok, asobi_world_server:join(Pid, ~"p1")),
    ?assertEqual(ok, await({on_zone_loaded, {1, 1}}, 1000)),
    {ok, ZonePid} = asobi_zone_manager:get_zone(Mgr, {1, 1}),
    ZoneState = zone_state(ZonePid),
    ?assertEqual(~"plains", maps:get(biome, ZoneState)),
    ?assertEqual({1, 1}, {maps:get(cx, ZoneState), maps:get(cy, ZoneState)}),
    stop_world(Ctx).

zone_state(ZonePid) ->
    case sys:get_state(ZonePid) of
        #{zone_state := ZS} when is_map(ZS) -> ZS
    end.

prewarmed_zone_is_not_seeded() ->
    Ctx = start_world(#{lazy_zones => false}),
    #{world_pid := Pid} = Ctx,
    ?assertEqual(ok, asobi_world_server:join(Pid, ~"p1")),
    ?assertEqual(timeout, await({on_zone_loaded, {1, 1}}, 300)),
    stop_world(Ctx).

stopped_zone_runs_on_zone_unloaded() ->
    Ctx = start_world(#{lazy_zones => true}),
    #{world_pid := Pid, zone_mgr := Mgr} = Ctx,
    ?assertEqual(ok, asobi_world_server:join(Pid, ~"p1")),
    ?assertEqual(ok, await({on_zone_loaded, {1, 1}}, 1000)),
    {ok, ZonePid} = asobi_zone_manager:get_zone(Mgr, {1, 1}),
    exit(ZonePid, kill),
    ?assertEqual(ok, await({on_zone_unloaded, {1, 1}}, 1000)),
    stop_world(Ctx).

%% The manager marks every zone it starts on demand, not just the first, so a
%% zone that was reaped and comes back is seeded rather than starting blank -
%% which is the case #574 was actually about.
recreated_zone_is_seeded_again() ->
    Ctx = start_world(#{lazy_zones => true}),
    #{world_pid := Pid, zone_mgr := Mgr} = Ctx,
    ?assertEqual(ok, asobi_world_server:join(Pid, ~"p1")),
    ?assertEqual(ok, await({on_zone_loaded, {1, 1}}, 1000)),
    {ok, ZonePid} = asobi_zone_manager:get_zone(Mgr, {1, 1}),
    exit(ZonePid, kill),
    ?assertEqual(ok, await({on_zone_unloaded, {1, 1}}, 1000)),
    ?assertMatch({ok, _, _}, asobi_zone_manager:ensure_zone(Mgr, {2, 2})),
    ?assertEqual(ok, await({on_zone_loaded, {2, 2}}, 1000)),
    stop_world(Ctx).
