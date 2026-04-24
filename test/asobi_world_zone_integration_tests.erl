-module(asobi_world_zone_integration_tests).
-include_lib("eunit/include/eunit.hrl").

-define(GAME, asobi_test_world_game).
-define(BASE_CONFIG, #{
    game_module => ?GAME,
    grid_size => 3,
    zone_size => 100,
    tick_rate => 50,
    max_players => 10,
    view_radius => 1
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

start_world() ->
    start_world(#{}).

start_world(Overrides) ->
    Config = maps:merge(?BASE_CONFIG, Overrides),
    {ok, InstancePid} = asobi_world_instance:start_link(Config),
    unlink(InstancePid),
    timer:sleep(50),
    ServerPid = asobi_world_instance:get_child(InstancePid, asobi_world_server),
    ZoneManagerPid = asobi_world_instance:get_child(InstancePid, asobi_zone_manager),
    #{instance_pid => InstancePid, world_pid => ServerPid, zone_mgr => ZoneManagerPid}.

stop_world(#{instance_pid := InstancePid}) ->
    catch exit(InstancePid, shutdown),
    timer:sleep(10),
    ok.

world_zone_integration_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        {"default config pre-spawns all zones", fun default_prespawns_all/0},
        {"lazy_zones=true starts with no zones", fun lazy_starts_empty/0},
        {"player join on lazy world creates zone", fun lazy_join_creates_zone/0},
        {"player move across boundary creates new zone", fun lazy_move_creates_zone/0},
        {"multiple players share same zone process", fun shared_zone_process/0},
        {"get_active_zones correct after lazy joins", fun active_zones_after_joins/0},
        {"small grid backward compat", fun small_grid_backward_compat/0}
    ]}.

%% Default (lazy_zones=false, grid_size=3) pre-spawns all 9 zones
default_prespawns_all() ->
    Ctx = #{zone_mgr := Mgr} = start_world(),
    Active = asobi_zone_manager:get_active_zones(Mgr),
    ?assertEqual(9, length(Active)),
    lists:foreach(
        fun({CX, CY} = Coords) when is_integer(CX), is_integer(CY) ->
            ?assertMatch({ok, _}, asobi_zone_manager:get_zone(Mgr, Coords))
        end,
        [{X, Y} || X <- lists:seq(0, 2), Y <- lists:seq(0, 2)]
    ),
    stop_world(Ctx).

%% lazy_zones=true means no zones spawned at startup
lazy_starts_empty() ->
    Ctx = #{zone_mgr := Mgr} = start_world(#{lazy_zones => true}),
    Active = asobi_zone_manager:get_active_zones(Mgr),
    ?assertEqual(0, length(Active)),
    stop_world(Ctx).

%% Joining a lazy world triggers zone creation via ensure_zone
lazy_join_creates_zone() ->
    Ctx = #{world_pid := Pid, zone_mgr := Mgr} = start_world(#{lazy_zones => true}),
    ?assertEqual(ok, asobi_world_server:join(Pid, ~"p1")),
    timer:sleep(20),
    Active = asobi_zone_manager:get_active_zones(Mgr),
    ?assert(length(Active) > 0),
    %% spawn_position returns {100.0, 100.0}, zone_size=100 => zone {1,1}
    ?assertMatch({ok, _}, asobi_zone_manager:get_zone(Mgr, {1, 1})),
    stop_world(Ctx).

%% Moving to a different zone on a lazy world creates the new zone
lazy_move_creates_zone() ->
    Ctx = #{world_pid := Pid, zone_mgr := Mgr} = start_world(#{lazy_zones => true}),
    ?assertEqual(ok, asobi_world_server:join(Pid, ~"p1")),
    timer:sleep(20),
    %% Player starts at {100.0, 100.0} => zone {1,1}
    %% Move to {250.0, 250.0} => zone {2,2}
    asobi_world_server:move_player(Pid, ~"p1", {250.0, 250.0}),
    timer:sleep(20),
    ?assertMatch({ok, _}, asobi_zone_manager:get_zone(Mgr, {2, 2})),
    stop_world(Ctx).

%% Two players in same zone get the same zone pid
shared_zone_process() ->
    Ctx = #{world_pid := Pid, zone_mgr := Mgr} = start_world(#{lazy_zones => true}),
    ?assertEqual(ok, asobi_world_server:join(Pid, ~"p1")),
    ?assertEqual(ok, asobi_world_server:join(Pid, ~"p2")),
    timer:sleep(20),
    %% Both spawn at {100.0, 100.0} => zone {1,1}
    {ok, ZonePid1} = asobi_zone_manager:get_zone(Mgr, {1, 1}),
    {ok, ZonePid2} = asobi_zone_manager:ensure_zone(Mgr, {1, 1}),
    ?assertEqual(ZonePid1, ZonePid2),
    ?assert(is_process_alive(ZonePid1)),
    stop_world(Ctx).

%% Active zone count reflects zones created by player joins
active_zones_after_joins() ->
    Ctx = #{world_pid := Pid, zone_mgr := Mgr} = start_world(#{lazy_zones => true}),
    ?assertEqual(0, length(asobi_zone_manager:get_active_zones(Mgr))),
    ?assertEqual(ok, asobi_world_server:join(Pid, ~"p1")),
    timer:sleep(20),
    Count1 = length(asobi_zone_manager:get_active_zones(Mgr)),
    ?assert(Count1 > 0),
    %% Move to a new zone to bump the count
    asobi_world_server:move_player(Pid, ~"p1", {250.0, 250.0}),
    timer:sleep(20),
    Count2 = length(asobi_zone_manager:get_active_zones(Mgr)),
    ?assert(Count2 > Count1),
    stop_world(Ctx).

%% Small grid (grid_size=3) without explicit lazy_zones works like before
small_grid_backward_compat() ->
    Ctx = #{world_pid := Pid, zone_mgr := Mgr} = start_world(#{grid_size => 3}),
    %% All 9 zones pre-spawned
    ?assertEqual(9, length(asobi_zone_manager:get_active_zones(Mgr))),
    %% Join still works
    ?assertEqual(ok, asobi_world_server:join(Pid, ~"p1")),
    Info = asobi_world_server:get_info(Pid),
    ?assertEqual(1, maps:get(player_count, Info)),
    ?assertEqual(running, maps:get(status, Info)),
    stop_world(Ctx).
