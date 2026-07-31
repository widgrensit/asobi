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
        {"small grid backward compat", fun small_grid_backward_compat/0},
        {"world.input crossing a zone boundary rehomes the player",
            fun world_input_rehomes_across_boundary/0},
        {"world.input past the world's far edge does not crash the world server",
            fun world_input_past_far_edge_survives/0},
        {"a script-owned player-typed entity the world server never joined survives crossing",
            fun script_owned_player_entity_survives_crossing/0}
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

%% Regression for widgrensit/asobi#248: a real world.input (asobi_zone:player_input,
%% what asobi_ws_handler actually calls - NOT asobi_world_server:move_player/3
%% directly, which lazy_move_creates_zone above already covered) has to rehome a
%% player across a zone boundary on its own, via resolve_zone_crossings/1.
world_input_rehomes_across_boundary() ->
    Ctx = #{world_pid := Pid, zone_mgr := Mgr} = start_world(#{lazy_zones => true}),
    ?assertEqual(ok, asobi_world_server:join(Pid, ~"p1")),
    timer:sleep(20),
    %% Spawns at {100.0, 100.0} => zone {1,1}
    {ok, ZonePid1} = asobi_zone_manager:get_zone(Mgr, {1, 1}),
    Entities0 = asobi_zone:get_entities(ZonePid1),
    ?assert(maps:is_key(~"p1", Entities0)),
    %% Simulate a game script that keeps state on the entity beyond x/y/type
    %% (hp, inventory, whatever) - regression for the move_player/3 path
    %% reconstructing a bare #{x, y, type} and silently dropping everything
    %% else on every crossing.
    asobi_zone:add_entity(ZonePid1, ~"p1", (maps:get(~"p1", Entities0))#{hp => 42}),

    %% The WS handler routes world.input straight to the zone the player
    %% joined - never to asobi_world_server - so drive the same entry point.
    asobi_zone:player_input(ZonePid1, ~"p1", #{
        ~"action" => ~"move", ~"x" => 250.0, ~"y" => 250.0
    }),
    timer:sleep(150),

    ?assertMatch({ok, _}, asobi_zone_manager:get_zone(Mgr, {2, 2})),
    {ok, ZonePid2} = asobi_zone_manager:get_zone(Mgr, {2, 2}),
    Entities2 = asobi_zone:get_entities(ZonePid2),
    ?assert(maps:is_key(~"p1", Entities2)),
    ?assertEqual(42, maps:get(hp, maps:get(~"p1", Entities2))),
    ?assertNot(maps:is_key(~"p1", asobi_zone:get_entities(ZonePid1))),
    stop_world(Ctx).

%% Regression for widgrensit/asobi#248 (security review of the fix): a
%% position past the world's far edge crossed pos_to_zone/2's missing upper
%% clamp into interest_zones/3 and asobi_world_chat:proximity_zones/3, both
%% of which called lists:seq(Lo, Hi) with Hi &lt; Lo and crashed - and via
%% asobi_world_instance's one_for_all supervisor, took the whole world down
%% with it. pos_to_zone/3 clamps to the grid before either is reached.
world_input_past_far_edge_survives() ->
    Ctx = #{world_pid := Pid, zone_mgr := Mgr} = start_world(#{lazy_zones => true}),
    ?assertEqual(ok, asobi_world_server:join(Pid, ~"p1")),
    timer:sleep(20),
    %% Spawns at {100.0, 100.0} => zone {1,1}
    {ok, ZonePid1} = asobi_zone_manager:get_zone(Mgr, {1, 1}),

    %% grid_size=3, zone_size=100: x=500 is zone column 5 unclamped, two past
    %% the last valid column (2) plus view_radius (1).
    asobi_zone:player_input(ZonePid1, ~"p1", #{
        ~"action" => ~"move", ~"x" => 500.0, ~"y" => 100.0
    }),
    timer:sleep(150),

    ?assert(is_process_alive(Pid)),
    Info = asobi_world_server:get_info(Pid),
    ?assertEqual(running, maps:get(status, Info)),
    %% Clamped to the grid's last column (2), not stuck in {1,1} nor crashed.
    ?assertMatch({ok, _}, asobi_zone_manager:get_zone(Mgr, {2, 1})),
    stop_world(Ctx).

%% Regression for widgrensit/asobi#248 (security review): a game script can
%% type a non-session entity "player" (a bot, a decoy) without it ever
%% joining, so the world server holds no player_zones entry for it.
%% resolve_zone_crossings/1 must not delete such an entity just because it
%% attempted a hand-off nothing claimed - it must stay exactly where it was.
script_owned_player_entity_survives_crossing() ->
    Ctx = #{world_pid := Pid, zone_mgr := Mgr} = start_world(#{lazy_zones => true}),
    {ok, ZonePid1} = asobi_zone_manager:ensure_zone(Mgr, {1, 1}),
    asobi_zone:add_entity(ZonePid1, ~"bot1", #{
        x => 100.0, y => 100.0, type => ~"player", hp => 7
    }),
    %% Give the zone a tick so it starts receiving ticks from the ticker.
    timer:sleep(20),
    ?assert(maps:is_key(~"bot1", asobi_zone:get_entities(ZonePid1))),

    %% Move it across a boundary the same way handle_input would.
    asobi_zone:player_input(ZonePid1, ~"bot1", #{
        ~"action" => ~"move", ~"x" => 250.0, ~"y" => 250.0
    }),
    timer:sleep(150),

    ?assert(is_process_alive(Pid)),
    Survived =
        maps:is_key(~"bot1", asobi_zone:get_entities(ZonePid1)) orelse
            case asobi_zone_manager:get_zone(Mgr, {2, 2}) of
                {ok, ZonePid2} -> maps:is_key(~"bot1", asobi_zone:get_entities(ZonePid2));
                not_loaded -> false
            end,
    ?assert(Survived),
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
