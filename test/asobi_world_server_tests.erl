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
    meck:expect(asobi_presence, track, fun(_PlayerId, _Pid) -> ok end),
    meck:expect(asobi_presence, untrack, fun(_PlayerId) -> ok end),
    meck:expect(asobi_presence, update, fun(_PlayerId, _Status) -> ok end),
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
        {"join returns error, not crash, when the zone is unavailable",
            fun join_zone_unavailable_returns_error/0},
        {"a zone-crossing move survives the destination zone being unavailable",
            fun move_zone_unavailable_is_a_noop/0},
        {"a zone-crossing move survives ensure_zone failing after the player was removed",
            fun move_zone_unavailable_after_removal_is_defensive/0},
        {"world boot survives a zone being unavailable during snapshot recovery",
            fun restore_entities_skips_unavailable_zone/0},
        {"leave removes player", fun leave_player/0},
        {timeout, 15, {"leave last player finishes world", fun leave_last_finishes/0}},
        {"get_info returns world metadata", fun get_info/0},
        {"get_info(Pid, listing) omits the roster but keeps filter/listing fields",
            fun get_info_listing/0},
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
                fun player_ttl_grace_starts_grace/0}},
        {"join/3 sets zone_pid in player_session synchronously", fun join_three_sets_zone_pid/0},
        {"join with no live session does not crash",
            fun join_with_no_live_session_does_not_crash/0},
        {"reconnect with no live session returns an error, not a crash",
            fun reconnect_with_no_live_session_returns_error/0},
        {"a failed reconnect leaves the disconnected grace entry intact",
            fun failed_reconnect_leaves_grace_intact/0},
        {"#304: oversized game.broadcast payload is not fanned out to players",
            fun broadcast_oversized_payload_is_rejected/0},
        {"#304: normal-size game.broadcast payload is still delivered",
            fun broadcast_normal_payload_is_delivered/0},
        {timeout, 15,
            {"#462: vote calls into a finished world error rather than hang",
                fun vote_calls_into_finished_world_error/0}},
        {"#462: cast_vote with a non-binary option does not crash the world",
            fun cast_vote_non_binary_option_does_not_crash_world/0},
        {timeout, 15,
            {"#462: cast_vote with a list option (approval/ranked) reaches the vote server",
                fun cast_vote_list_option_reaches_vote_server/0}}
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

%% asobi#258: a bare {ok, ZonePid} = ensure_zone(...) used to crash the whole
%% world gen_statem - every player in it - on e.g. max_zones_reached. join/2
%% must reject cleanly instead.
join_zone_unavailable_returns_error() ->
    Ctx = start_world(),
    Pid = maps:get(world_pid, Ctx),
    meck:new(asobi_zone_manager, [passthrough]),
    meck:expect(asobi_zone_manager, ensure_zone, fun(_Ref, _Coords) ->
        {error, max_zones_reached}
    end),
    try
        ?assertEqual({error, zone_unavailable}, asobi_world_server:join(Pid, ~"p1")),
        ?assert(is_process_alive(Pid)),
        ?assertEqual(0, maps:get(player_count, asobi_world_server:get_info(Pid)))
    after
        meck:unload(asobi_zone_manager)
    end,
    stop_world(Ctx).

%% asobi#258: same crash, reached via a zone-crossing move instead of a join.
%% The fix checks the destination zone before removing the player from their
%% current one, so a failed crossing is a pure no-op rather than a crash (and
%% rather than a crash-free version that still strands the player zoneless).
move_zone_unavailable_is_a_noop() ->
    Ctx = start_world(),
    Pid = maps:get(world_pid, Ctx),
    %% asobi_test_world_game:spawn_position/2 always returns {100.0, 100.0},
    %% which is zone {1,1} at zone_size=100 (see ?BASE_CONFIG).
    ok = asobi_world_server:join(Pid, ~"p1"),
    timer:sleep(20),
    meck:new(asobi_zone_manager, [passthrough]),
    meck:expect(asobi_zone_manager, ensure_zone, fun
        (_Ref, {0, 0}) -> {error, max_zones_reached};
        (Ref, Coords) -> meck:passthrough([Ref, Coords])
    end),
    try
        %% {0.0, 0.0} is zone {0,0} - a real zone-crossing, mocked to fail.
        asobi_world_server:move_player(Pid, ~"p1", {0.0, 0.0}),
        timer:sleep(20),
        ?assert(is_process_alive(Pid)),
        ?assertEqual(1, maps:get(player_count, asobi_world_server:get_info(Pid)))
    after
        meck:unload(asobi_zone_manager)
    end,
    stop_world(Ctx).

%% asobi#258 code review (architecture-guardian pass on #260): the
%% zone-crossing branch's precheck and place_player/4's own internal
%% ensure_zone call target the same coords - a failure at the SECOND call,
%% after the player was already removed from their old zone, was left as a
%% bare match. Not reachable under current asobi_zone_manager timing
%% invariants (no yield point between the two calls for the zone to be
%% reaped), but defended anyway rather than trusted to hold forever. Force
%% it here by making ensure_zone succeed once then fail for the same coords.
move_zone_unavailable_after_removal_is_defensive() ->
    Ctx = start_world(),
    Pid = maps:get(world_pid, Ctx),
    ok = asobi_world_server:join(Pid, ~"p1"),
    timer:sleep(20),
    Counter = counters:new(1, []),
    meck:new(asobi_zone_manager, [passthrough]),
    meck:expect(asobi_zone_manager, ensure_zone, fun
        (Ref, {0, 0} = Coords) ->
            case counters:get(Counter, 1) of
                0 ->
                    counters:add(Counter, 1, 1),
                    meck:passthrough([Ref, Coords]);
                _ ->
                    {error, max_zones_reached}
            end;
        (Ref, Coords) ->
            meck:passthrough([Ref, Coords])
    end),
    try
        asobi_world_server:move_player(Pid, ~"p1", {0.0, 0.0}),
        timer:sleep(20),
        ?assert(is_process_alive(Pid))
    after
        meck:unload(asobi_zone_manager)
    end,
    stop_world(Ctx).

%% asobi#258: restore_entities/4 (world-boot snapshot recovery) must skip a
%% zone that fails ensure_zone rather than crashing the whole world's boot.
restore_entities_skips_unavailable_zone() ->
    Snapshot = #{
        {0, 0} => #{
            zone_state => #{}, entities => #{~"e1" => #{x => 0.0, y => 0.0}}, spawner_state => #{}
        }
    },
    meck:new(asobi_zone_snapshotter, [passthrough]),
    meck:expect(asobi_zone_snapshotter, load_snapshots, fun(_WorldId) -> {ok, Snapshot} end),
    meck:new(asobi_zone_manager, [passthrough]),
    meck:expect(asobi_zone_manager, ensure_zone, fun
        (_Ref, {0, 0}) -> {error, max_zones_reached};
        (Ref, Coords) -> meck:passthrough([Ref, Coords])
    end),
    try
        Ctx = start_world(#{persistence => true}),
        Pid = maps:get(world_pid, Ctx),
        ?assert(is_process_alive(Pid)),
        Info = asobi_world_server:get_info(Pid),
        ?assertEqual(running, maps:get(status, Info)),
        stop_world(Ctx)
    after
        meck:unload(asobi_zone_manager),
        meck:unload(asobi_zone_snapshotter)
    end.

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
    ?assert(maps:is_key(players, Info)),
    stop_world(Ctx).

%% asobi#194: the listing variant must not carry the roster at all - not
%% just omit it from the eventual listing_info/1 projection, since the
%% whole point is to never copy it across the process boundary - but must
%% keep every field asobi_world_lobby:matches_filters/2 and listing_info/1
%% read (player_count, max_players, mode, status, listed, quick_play).
get_info_listing() ->
    Ctx = start_world(),
    Pid = maps:get(world_pid, Ctx),
    ok = asobi_world_server:join(Pid, ~"p1"),
    Full = asobi_world_server:get_info(Pid),
    Listing = asobi_world_server:get_info(Pid, listing),
    ?assertNot(maps:is_key(players, Listing)),
    [
        ?assertEqual(maps:get(K, Full), maps:get(K, Listing))
     || K <- [world_id, status, player_count, max_players, mode, grid_size, listed, quick_play]
    ],
    ?assertEqual(
        asobi_world_server:listing_info(Full), asobi_world_server:listing_info(Listing)
    ),
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

join_three_sets_zone_pid() ->
    %% Regression: world.input sent immediately after world.joined was silently
    %% dropped because asobi_player_session.zone_pid was set via an async
    %% {world_joined,...} message that hadn't been processed yet. join/3 sets
    %% zone_pid synchronously in the player_session before returning.
    Ctx = #{world_pid := Pid} = start_world(),
    PlayerId = <<"sync_zone_pid">>,
    {ok, SessionPid} = asobi_player_session:start_link(PlayerId, self()),
    unlink(SessionPid),
    ok = pg:join(nova_scope, {player, PlayerId}, SessionPid),
    %% Pre-condition: zone_pid is undefined before join.
    State0 = asobi_player_session:get_state(SessionPid),
    ?assertEqual(undefined, maps:get(zone_pid, State0, undefined)),
    %% join/3 must bind zone_pid + world_pid into the session synchronously.
    ?assertEqual(ok, asobi_world_server:join(Pid, PlayerId, SessionPid)),
    State1 = asobi_player_session:get_state(SessionPid),
    ?assert(is_pid(maps:get(zone_pid, State1))),
    ?assertEqual(Pid, maps:get(world_pid, State1)),
    asobi_player_session:stop(SessionPid),
    stop_world(Ctx).

%% Regression for widgrensit/asobi#277: find_player_pid/1 used to fall back
%% to self() when a player had no live pg registration, which would have
%% recorded the world server's own pid as that player's session and
%% subscribed it to the player's zone - not a crash, but silently wrong.
%% join/2 (test-only, no session registered) is exactly that case.
join_with_no_live_session_does_not_crash() ->
    Ctx = #{world_pid := Pid, instance_pid := InstancePid} = start_world(),
    PlayerId = ~"no_session",
    ?assertEqual(ok, asobi_world_server:join(Pid, PlayerId)),
    ?assert(is_process_alive(Pid)),
    ?assertEqual(1, maps:get(player_count, asobi_world_server:get_info(Pid))),
    %% The actual defect: under the old self() fallback, this player's
    %% session_pid/monitor_ref would be the world server itself, and the
    %% world server would show up as a subscriber of the player's own zone.
    {_StateName, #{
        players := #{PlayerId := #{session_pid := SessionPid, monitor_ref := MonRef}}
    }} = sys:get_state(Pid),
    ?assertEqual(undefined, SessionPid),
    ?assertEqual(undefined, MonRef),
    ZMPid = asobi_world_instance:get_child(InstancePid, asobi_zone_manager),
    %% asobi_test_world_game:spawn_position/2 always returns {100.0, 100.0},
    %% zone {1,1} at zone_size=100 (?BASE_CONFIG).
    {ok, ZonePid} = asobi_zone_manager:get_zone(ZMPid, {1, 1}),
    ?assertEqual(0, asobi_zone:get_subscriber_count(ZonePid)),
    stop_world(Ctx).

%% Regression for widgrensit/asobi#277: a reconnect attempt with no live
%% pg-registered session for the player must fail cleanly (the caller
%% invoking reconnect/2 IS supposed to be that live session) rather than
%% crash on monitor(process, undefined) or silently monitor the world
%% server's own pid.
reconnect_with_no_live_session_returns_error() ->
    Ctx = #{world_pid := Pid} = start_world(#{player_ttl_ms => 5_000}),
    PlayerId = ~"reconnect_no_session",
    SessionPid = fake_session(PlayerId),
    ?assertEqual(ok, asobi_world_server:join(Pid, PlayerId)),
    ?assertEqual(1, maps:get(player_count, asobi_world_server:get_info(Pid))),
    exit(SessionPid, kill),
    timer:sleep(100),
    %% No new session registered before reconnecting.
    ?assertEqual({error, no_live_session}, asobi_world_server:reconnect(Pid, PlayerId)),
    ?assert(is_process_alive(Pid)),
    stop_world(Ctx).

%% Regression for widgrensit/asobi#277: the no-live-session check runs before
%% asobi_reconnect:reconnect/2, so a rejected reconnect must not consume the
%% player's disconnected/grace entry - a real session arriving afterwards
%% still gets to reconnect normally.
failed_reconnect_leaves_grace_intact() ->
    Ctx = #{world_pid := Pid} = start_world(#{player_ttl_ms => 5_000}),
    PlayerId = ~"retry_after_no_session",
    S1 = fake_session(PlayerId),
    ?assertEqual(ok, asobi_world_server:join(Pid, PlayerId)),
    exit(S1, kill),
    timer:sleep(100),
    ?assertEqual({error, no_live_session}, asobi_world_server:reconnect(Pid, PlayerId)),
    {_StateName, #{reconnect_state := #{disconnected := #{PlayerId := _}}}} = sys:get_state(Pid),
    _S2 = fake_session(PlayerId),
    ?assertEqual(ok, asobi_world_server:reconnect(Pid, PlayerId)),
    ?assertEqual(1, maps:get(player_count, asobi_world_server:get_info(Pid))),
    stop_world(Ctx).

%% --- listing_info/1 (pure projection, no world needed) ---

listing_info_drops_roster_test() ->
    Info = #{
        world_id => ~"w1",
        status => running,
        player_count => 2,
        max_players => 4,
        players => [~"p1", ~"p2"],
        mode => ~"hub",
        grid_size => 1,
        started_at => 123
    },
    Listing = asobi_world_server:listing_info(Info),
    ?assertEqual(
        lists:sort([world_id, status, player_count, max_players, mode, grid_size, started_at]),
        lists:sort(maps:keys(Listing))
    ),
    ?assertEqual(2, maps:get(player_count, Listing)).

listing_info_drops_unknown_fields_test() ->
    Listing = asobi_world_server:listing_info(#{
        world_id => ~"w1", owner_id => ~"p1", spectators => [~"p2"]
    }),
    ?assertEqual([world_id], maps:keys(Listing)).

listing_info_projects_nested_phase_test() ->
    %% asobi_phase:info/1 evolves independently; the projection must not
    %% pass through whatever it grows next.
    Listing = asobi_world_server:listing_info(#{
        world_id => ~"w1",
        phase => #{
            status => active,
            phase => ~"combat",
            remaining_ms => 500,
            config => #{answer_key => ~"secret"},
            timers => [a, b],
            winner => ~"p1"
        }
    }),
    ?assertEqual(
        lists:sort([status, phase, remaining_ms]),
        lists:sort(maps:keys(maps:get(phase, Listing)))
    ).

listing_info_handles_missing_phase_test() ->
    ?assertNot(maps:is_key(phase, asobi_world_server:listing_info(#{world_id => ~"w1"}))),
    ?assertEqual(#{}, asobi_world_server:listing_info(#{})).

listing_info_omits_visibility_flags_test() ->
    %% `listed`/`quick_play` are server-side discovery filters. They ride in
    %% world_info/2 so matches_filters/2 can read them, and must not reach a
    %% browsing client - an unlisted world never appears, so the flag is
    %% redundant on the wire.
    Listing = asobi_world_server:listing_info(#{
        world_id => ~"w1", listed => false, quick_play => false
    }),
    ?assertEqual([world_id], maps:keys(Listing)).

%% asobi_lua binds the world server pid as `match_pid` in world and zone
%% contexts (asobi_lua_world.erl:739,747), so `game.broadcast` from any world
%% or zone script casts {broadcast_event, ...} at asobi_world_server. It had
%% no clause in any state except `finished`, so the cast was a function_clause
%% and killed the world. Unconditional, unlike the match-side variant.
broadcast_in_running_does_not_kill_the_world_test() ->
    Ctx = #{world_pid := Pid} = start_world(),
    ok = asobi_world_server:join(Pid, ~"p1"),
    gen_statem:cast(Pid, {broadcast_event, world_notice, #{msg => ~"hello"}}),
    timer:sleep(30),
    ?assert(is_process_alive(Pid)),
    ?assertEqual(running, maps:get(status, asobi_world_server:get_info(Pid))),
    stop_world(Ctx).

%% pos_to_zone/2 only clamps the low end; a position past the world's far
%% edge fed an out-of-grid coordinate to interest_zones/3 and
%% asobi_world_chat:proximity_zones/3, both of which crashed on it
%% (widgrensit/asobi#248). pos_to_zone/3 is what closes that.
pos_to_zone_clamps_both_ends_test() ->
    ?assertEqual({0, 0}, asobi_world_server:pos_to_zone({-500.0, -1.0}, 100, 3)),
    ?assertEqual({1, 1}, asobi_world_server:pos_to_zone({150.0, 150.0}, 100, 3)),
    ?assertEqual({2, 2}, asobi_world_server:pos_to_zone({299.0, 299.0}, 100, 3)),
    ?assertEqual({2, 2}, asobi_world_server:pos_to_zone({1.0e9, 1.0e9}, 100, 3)),
    ?assertEqual({0, 0}, asobi_world_server:pos_to_zone({999.0, 999.0}, 100, 1)).

%% #304: ?WS_MAX_PAYLOAD_BYTES caps inbound frames but nothing capped what
%% game.broadcast fanned out to every player in the world - a large payload
%% multiplied egress bandwidth and per-socket buffer memory by player count.
%% broadcast_world_event/3 must reject an oversized payload instead of
%% fanning it out.
broadcast_oversized_payload_is_rejected() ->
    Ctx = #{world_pid := Pid} = start_world(),
    ok = asobi_world_server:join(Pid, ~"p1"),
    Self = self(),
    meck:expect(asobi_presence, send, fun(PlayerId, Msg) ->
        Self ! {sent, PlayerId, Msg},
        ok
    end),
    HugePayload = #{data => binary:copy(~"a", 70000)},
    gen_statem:cast(Pid, {broadcast_event, ~"huge", HugePayload}),
    timer:sleep(50),
    Received = flush_sent(),
    ?assertEqual([], [M || {sent, _, {world_event, ~"huge", _}} = M <- Received]),
    meck:expect(asobi_presence, send, fun(_PlayerId, _Msg) -> ok end),
    stop_world(Ctx).

broadcast_normal_payload_is_delivered() ->
    Ctx = #{world_pid := Pid} = start_world(),
    ok = asobi_world_server:join(Pid, ~"p1"),
    Self = self(),
    meck:expect(asobi_presence, send, fun(PlayerId, Msg) ->
        Self ! {sent, PlayerId, Msg},
        ok
    end),
    gen_statem:cast(Pid, {broadcast_event, ~"small", #{msg => ~"hi"}}),
    timer:sleep(50),
    Received = flush_sent(),
    ?assert(length([M || {sent, _, {world_event, ~"small", _}} = M <- Received]) >= 1),
    meck:expect(asobi_presence, send, fun(_PlayerId, _Msg) -> ok end),
    stop_world(Ctx).

flush_sent() ->
    receive
        {sent, _, _} = M -> [M | flush_sent()]
    after 0 -> []
    end.

%% asobi#462: a vote.cast/vote.veto into a finished world landed on
%% finished/3's catch-all, which swallowed the {call, From} with no reply, so
%% the caller (an infinity gen_statem:call) blocked until the ~5s cleanup
%% timeout. The finished-state vote clauses now reply immediately with
%% not_in_match - the same registered code the dead-fabric path returns.
vote_calls_into_finished_world_error() ->
    Ctx = #{world_pid := Pid} = start_world(),
    asobi_world_server:cancel(Pid),
    wait_for_world_status(Pid, finished, 60),
    ?assertEqual(
        {error, not_in_match},
        gen_statem:call(Pid, {cast_vote, ~"pf1", ~"v1", ~"o1"}, 2000)
    ),
    ?assertEqual(
        {error, not_in_match},
        gen_statem:call(Pid, {use_veto, ~"pf1", ~"v1"}, 2000)
    ),
    ?assert(is_process_alive(Pid)),
    stop_world(Ctx).

%% asobi#462: the world cast_vote path was guard-free and forwarded an
%% unvalidated non-binary option straight to asobi_vote_server. A vote.cast
%% carrying a non-binary option_id (a JSON number/null) now degrades to
%% {error, invalid_option} and the world survives, never forwarding the junk.
cast_vote_non_binary_option_does_not_crash_world() ->
    Ctx = #{world_pid := Pid} = start_world(),
    ?assertEqual(
        {error, invalid_option},
        gen_statem:call(Pid, {cast_vote, ~"pnb1", ~"v1", 12345}, 2000)
    ),
    ?assert(is_process_alive(Pid)),
    ?assertEqual(running, maps:get(status, asobi_world_server:get_info(Pid))),
    stop_world(Ctx).

wait_for_world_status(_Pid, _Status, 0) ->
    error(timeout_waiting_for_status);
wait_for_world_status(Pid, Status, N) ->
    case maps:get(status, asobi_world_server:get_info(Pid), undefined) of
        Status ->
            ok;
        _ ->
            timer:sleep(20),
            wait_for_world_status(Pid, Status, N - 1)
    end.

%% asobi#462 regression guard: the world cast_vote path was guard-free and
%% forwarded any option straight to asobi_vote_server; the fix guards it with
%% is_binary(OptionId) orelse is_list(OptionId). This proves a valid list
%% option (approval/ranked) still reaches handle_cast_vote and is accepted,
%% while a list carrying a non-binary and a bare non-binary scalar both degrade
%% to invalid_option with no crash.
cast_vote_list_option_reaches_vote_server() ->
    ensure_vote_sup(),
    Ctx = #{world_pid := Pid} = start_world(),
    ok = asobi_world_server:join(Pid, ~"pl1"),
    {ok, VotePid} = asobi_world_server:start_vote(Pid, #{
        vote_id => ~"v1",
        method => approval,
        options => [#{id => ~"a", label => ~"A"}, #{id => ~"b", label => ~"B"}],
        window_ms => 60000
    }),
    ?assertEqual(ok, gen_statem:call(Pid, {cast_vote, ~"pl1", ~"v1", [~"a", ~"b"]}, 2000)),
    ?assertEqual(
        {error, invalid_option},
        gen_statem:call(Pid, {cast_vote, ~"pl1", ~"v1", [~"a", 123]}, 2000)
    ),
    ?assertEqual(
        {error, invalid_option},
        gen_statem:call(Pid, {cast_vote, ~"pl1", ~"v1", 123}, 2000)
    ),
    ?assert(is_process_alive(Pid)),
    gen_statem:stop(VotePid),
    stop_world(Ctx).

ensure_vote_sup() ->
    case whereis(asobi_vote_sup) of
        undefined ->
            {ok, _} = asobi_vote_sup:start_link(),
            ok;
        _ ->
            ok
    end.
