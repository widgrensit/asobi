-module(asobi_world_server_tests).
-include_lib("eunit/include/eunit.hrl").

-define(GAME, asobi_test_world_game).
-define(BASE_CONFIG, #{
    game_module => ?GAME,
    grid_size => 2,
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
    case ets:info(asobi_player_worlds) of
        undefined ->
            ets:new(asobi_player_worlds, [
                named_table, public, set, {read_concurrency, true}
            ]);
        _ ->
            ets:delete_all_objects(asobi_player_worlds)
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
    %% Give time for loading -> running transition
    timer:sleep(50),
    ServerPid = asobi_world_instance:get_child(InstancePid, asobi_world_server),
    #{instance_pid => InstancePid, world_pid => ServerPid}.

stop_world(#{instance_pid := InstancePid}) ->
    catch exit(InstancePid, shutdown),
    timer:sleep(10),
    ok.

world_server_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        {"starts and transitions to running", fun starts_running/0},
        {"spawns correct number of zones", fun spawns_zones/0},
        {"join adds player to world", fun join_player/0},
        {"join rejects when full", fun join_rejects_full/0},
        {"leave removes player", fun leave_player/0},
        {timeout, 15, {"leave last player finishes world", fun leave_last_finishes/0}},
        {"get_info returns world metadata", fun get_info/0},
        {timeout, 15, {"cancel finishes world", fun cancel_world/0}},
        {"whereis finds world by id", fun whereis_world/0},
        {"join records player in ETS, leave clears it", fun ets_tracks_player_world/0},
        {timeout, 15, {"empty grace keeps world alive briefly", fun empty_grace_keeps_alive/0}},
        {timeout, 15, {"empty grace lapses when no one rejoins", fun empty_grace_lapses/0}},
        {timeout, 15,
            {"empty phases() list does not auto-finish", fun empty_phases_does_not_finish/0}},
        {timeout, 15,
            {"player_ttl_ms=0 (default): DOWN immediately removes player",
                fun player_ttl_zero_removes_on_down/0}},
        {timeout, 15,
            {"player_ttl_ms=-1: DOWN keeps player (persistent world opt-in)",
                fun player_ttl_minus_one_keeps_on_down/0}},
        {timeout, 15,
            {"player_ttl_ms>0: DOWN starts grace, fires reconnect events",
                fun player_ttl_grace_starts_grace/0}}
    ]}.

starts_running() ->
    Ctx = start_world(),
    Info = asobi_world_server:get_info(maps:get(world_pid, Ctx)),
    ?assertEqual(running, maps:get(status, Info)),
    stop_world(Ctx).

spawns_zones() ->
    Ctx = start_world(#{grid_size => 3}),
    %% 3x3 grid = 9 zones
    Info = asobi_world_server:get_info(maps:get(world_pid, Ctx)),
    ?assertEqual(3, maps:get(grid_size, Info)),
    stop_world(Ctx).

join_player() ->
    Ctx = start_world(),
    Pid = maps:get(world_pid, Ctx),
    ?assertEqual(ok, asobi_world_server:join(Pid, <<"p1">>)),
    Info = asobi_world_server:get_info(Pid),
    ?assertEqual(1, maps:get(player_count, Info)),
    ?assert(lists:member(<<"p1">>, maps:get(players, Info))),
    stop_world(Ctx).

join_rejects_full() ->
    Ctx = start_world(#{max_players => 1}),
    Pid = maps:get(world_pid, Ctx),
    ?assertEqual(ok, asobi_world_server:join(Pid, <<"p1">>)),
    ?assertEqual({error, world_full}, asobi_world_server:join(Pid, <<"p2">>)),
    stop_world(Ctx).

leave_player() ->
    Ctx = start_world(),
    Pid = maps:get(world_pid, Ctx),
    asobi_world_server:join(Pid, <<"p1">>),
    asobi_world_server:join(Pid, <<"p2">>),
    asobi_world_server:leave(Pid, <<"p1">>),
    timer:sleep(20),
    Info = asobi_world_server:get_info(Pid),
    ?assertEqual(1, maps:get(player_count, Info)),
    stop_world(Ctx).

leave_last_finishes() ->
    Ctx = #{world_pid := Pid} = start_world(),
    MonRef = monitor(process, Pid),
    asobi_world_server:join(Pid, <<"p1">>),
    asobi_world_server:leave(Pid, <<"p1">>),
    receive
        {'DOWN', MonRef, process, Pid, _} -> ok
    after 10000 ->
        stop_world(Ctx),
        ?assert(false)
    end.

get_info() ->
    Ctx = start_world(),
    Pid = maps:get(world_pid, Ctx),
    Info = asobi_world_server:get_info(Pid),
    ?assert(maps:is_key(world_id, Info)),
    ?assert(maps:is_key(status, Info)),
    ?assert(maps:is_key(player_count, Info)),
    ?assert(maps:is_key(grid_size, Info)),
    stop_world(Ctx).

cancel_world() ->
    Ctx = start_world(),
    Pid = maps:get(world_pid, Ctx),
    MonRef = monitor(process, Pid),
    asobi_world_server:cancel(Pid),
    receive
        {'DOWN', MonRef, process, Pid, _} -> ok
    after 10000 ->
        ?assert(false)
    end.

whereis_world() ->
    Ctx = start_world(),
    Pid = maps:get(world_pid, Ctx),
    Info = asobi_world_server:get_info(Pid),
    WorldId = maps:get(world_id, Info),
    ?assertEqual({ok, Pid}, asobi_world_server:whereis(WorldId)),
    stop_world(Ctx).

ets_tracks_player_world() ->
    Ctx = #{world_pid := Pid} = start_world(),
    asobi_world_server:join(Pid, <<"p_ets">>),
    ?assertEqual([{<<"p_ets">>, Pid}], ets:lookup(asobi_player_worlds, <<"p_ets">>)),
    asobi_world_server:join(Pid, <<"p_ets2">>),
    asobi_world_server:leave(Pid, <<"p_ets">>),
    timer:sleep(20),
    ?assertEqual([], ets:lookup(asobi_player_worlds, <<"p_ets">>)),
    %% Force a graceful gen_statem stop so terminate runs and cleans up the
    %% remaining player's ETS entry. (Supervisor-shutdown does NOT call terminate
    %% on processes that don't trap_exit, so we use gen_statem:stop directly.)
    ok = gen_statem:stop(Pid),
    ?assertEqual([], ets:lookup(asobi_player_worlds, <<"p_ets2">>)),
    stop_world(Ctx).

empty_grace_keeps_alive() ->
    Ctx = #{world_pid := Pid} = start_world(#{empty_grace_ms => 500}),
    MonRef = monitor(process, Pid),
    asobi_world_server:join(Pid, <<"g1">>),
    asobi_world_server:leave(Pid, <<"g1">>),
    %% Grace window is 500ms; rejoin within 200ms must keep world alive.
    timer:sleep(200),
    ?assertEqual(ok, asobi_world_server:join(Pid, <<"g2">>)),
    %% Sleep past the original grace window — world must still be alive because grace was cancelled.
    timer:sleep(500),
    ?assertEqual(running, maps:get(status, asobi_world_server:get_info(Pid))),
    demonitor(MonRef, [flush]),
    stop_world(Ctx).

empty_grace_lapses() ->
    Ctx = #{world_pid := Pid} = start_world(#{empty_grace_ms => 200}),
    MonRef = monitor(process, Pid),
    asobi_world_server:join(Pid, <<"g3">>),
    asobi_world_server:leave(Pid, <<"g3">>),
    %% No rejoin: grace fires after 200ms and the world finishes.
    receive
        {'DOWN', MonRef, process, Pid, _} -> ok
    after 10000 ->
        stop_world(Ctx),
        ?assert(false)
    end.

empty_phases_does_not_finish() ->
    %% Inject phases/1 that returns []. Before the fix, the world would
    %% transition to `finished` on the first post_tick because asobi_phase:init([])
    %% returns a state with status=complete.
    meck:new(asobi_test_world_game, [passthrough, non_strict]),
    meck:expect(asobi_test_world_game, phases, fun(_GameConfig) -> [] end),
    try
        Ctx = #{world_pid := Pid} = start_world(),
        asobi_world_server:join(Pid, <<"ph1">>),
        %% Wait several ticks; if the bug is present, world transitions to finished.
        timer:sleep(300),
        ?assertEqual(running, maps:get(status, asobi_world_server:get_info(Pid))),
        stop_world(Ctx)
    after
        meck:unload(asobi_test_world_game)
    end.

%% --- player_ttl_ms ---

%% Spawn a fake player session and register it in the pg group the world
%% server monitors via find_player_pid/1. Killing this pid triggers the
%% world_server's 'DOWN' handler.
fake_session(PlayerId) ->
    Pid = spawn(fun Loop() ->
        receive
            stop -> ok;
            _ -> Loop()
        end
    end),
    ok = pg:join(nova_scope, {player, PlayerId}, Pid),
    Pid.

player_ttl_zero_removes_on_down() ->
    %% Default behavior: WS drop with no reconnect policy should fully clean
    %% up the player. Without this, the zone accumulates zombie entities.
    Ctx = #{world_pid := Pid} = start_world(),
    PlayerId = <<"ttl0">>,
    SessionPid = fake_session(PlayerId),
    asobi_world_server:join(Pid, PlayerId),
    ?assertEqual(1, maps:get(player_count, asobi_world_server:get_info(Pid))),
    exit(SessionPid, kill),
    timer:sleep(50),
    ?assertEqual(0, maps:get(player_count, asobi_world_server:get_info(Pid))),
    stop_world(Ctx).

player_ttl_minus_one_keeps_on_down() ->
    %% Persistent-world opt-in: -1 means never auto-remove on disconnect.
    %% The game module manages reconnection state itself.
    Ctx = #{world_pid := Pid} = start_world(#{player_ttl_ms => -1}),
    PlayerId = <<"ttlneg">>,
    SessionPid = fake_session(PlayerId),
    asobi_world_server:join(Pid, PlayerId),
    ?assertEqual(1, maps:get(player_count, asobi_world_server:get_info(Pid))),
    exit(SessionPid, kill),
    timer:sleep(50),
    ?assertEqual(1, maps:get(player_count, asobi_world_server:get_info(Pid))),
    stop_world(Ctx).

player_ttl_grace_starts_grace() ->
    %% Positive ttl synthesizes a reconnect_state. DOWN must trigger the
    %% grace flow; player count stays at 1 during the grace window.
    Ctx = #{world_pid := Pid} = start_world(#{player_ttl_ms => 5_000}),
    PlayerId = <<"ttlgrace">>,
    SessionPid = fake_session(PlayerId),
    asobi_world_server:join(Pid, PlayerId),
    ?assertEqual(1, maps:get(player_count, asobi_world_server:get_info(Pid))),
    exit(SessionPid, kill),
    timer:sleep(100),
    %% Player remains in the world during grace (entity may be hidden by
    %% during_grace=removed but the player record is preserved for reconnect).
    ?assertEqual(1, maps:get(player_count, asobi_world_server:get_info(Pid))),
    stop_world(Ctx).
