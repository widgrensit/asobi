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
    application:ensure_all_started(seki),
    %% Deliberately not registering asobi_rehome_limiter here: every crossing
    %% test below exercises asobi_rehome_limiter:allow/1 with the limiter
    %% unregistered (this harness never starts asobi_sup), which is exactly
    %% the fail-open path that matters - a bare seki:check/2 here used to
    %% crash the zone, and via asobi_zone_sup/asobi_world_instance's
    %% supervision, the whole world. rehome_denied_by_rate_limit_survives/0
    %% registers its own tight limiter locally to exercise the deny path.
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
        {"broadcast_interval override reaches the zone process (#463)",
            fun broadcast_interval_reaches_the_zone/0},
        {"broadcast_interval defaults to 3 when unset (#463)",
            fun broadcast_interval_defaults_to_three/0},
        {"world.input crossing a zone boundary rehomes the player",
            fun world_input_rehomes_across_boundary/0},
        {"a binary-keyed (Lua-shaped) player entity rehomes across a boundary",
            fun binary_keyed_player_rehomes_across_boundary/0},
        {"world.input past the world's far edge does not crash the world server",
            fun world_input_past_far_edge_survives/0},
        {"a script-owned player-typed entity the world server never joined survives crossing",
            fun script_owned_player_entity_survives_crossing/0},
        {"a crossing only touches the interest-ring zones that actually changed",
            fun world_input_crossing_touches_only_ring_delta/0},
        {"a crossing into a lazily-created zone backfills a stationary neighbour",
            fun crossing_into_a_lazily_created_zone_backfills_stationary_neighbours/0},
        {"a script-driven spawn into a lazily-created zone backfills neighbours",
            fun script_spawn_into_a_lazily_created_zone_backfills_neighbours/0},
        {"an NPC crossing into an unloaded zone creates it and backfills neighbours",
            fun npc_crossing_into_an_unloaded_zone_creates_it_and_backfills/0},
        {"a position within the boundary margin does not rehome the player",
            fun world_input_within_margin_does_not_rehome/0},
        {"a rate-limited crossing leaves the entity in place instead of destroying it",
            fun rehome_denied_by_rate_limit_survives/0},
        {"the global rehome limit denies a crossing even with per-player budget to spare",
            fun rehome_denied_by_global_limit/0},
        {"a crossing that drops a zone from the ring removes its stationary occupants",
            fun crossing_out_of_ring_removes_stationary_neighbour/0},
        {"a join whose zone is reaped right after the lookup still lands the player",
            fun join_survives_zone_reaped_after_lookup/0},
        {"a crossing whose destination is reaped right after the lookup still lands the player",
            fun crossing_survives_zone_reaped_after_lookup/0}
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

%% asobi#463: a mode-set broadcast_interval must reach the zone PROCESS, not just
%% world_config/1. This is the hop that was missing - the value was read by
%% asobi_zone but never placed into BaseZoneConfig.
broadcast_interval_reaches_the_zone() ->
    Ctx = #{zone_mgr := Mgr} = start_world(#{broadcast_interval => 1}),
    {ok, ZonePid} = asobi_zone_manager:get_zone(Mgr, {0, 0}),
    ?assertEqual(1, maps:get(broadcast_interval, zone_state(ZonePid))),
    stop_world(Ctx).

%% The default is unchanged: a world that sets nothing runs on 3.
broadcast_interval_defaults_to_three() ->
    Ctx = #{zone_mgr := Mgr} = start_world(),
    {ok, ZonePid} = asobi_zone_manager:get_zone(Mgr, {0, 0}),
    ?assertEqual(3, maps:get(broadcast_interval, zone_state(ZonePid))),
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
    {ok, ZonePid2, existing} = asobi_zone_manager:ensure_zone(Mgr, {1, 1}),
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

%% Regression for widgrensit/asobi#248 (security review): without a margin,
%% pos_to_zone/3 disagreeing with the zone's own Coords by even a fraction of
%% a unit is treated as a crossing - a player parked on (or jittering across)
%% a boundary re-homes every tick. asobi_zone's past_zone_margin/4 requires
%% clearing the zone's own rectangle by rehome_margin (default 15% of
%% zone_size) first; this proves
%% that suppression end to end, not just the margin math in isolation
%% (past_zone_margin_test/0 in asobi_zone_tests.erl covers that).
world_input_within_margin_does_not_rehome() ->
    Ctx = #{world_pid := Pid, zone_mgr := Mgr} = start_world(#{lazy_zones => true}),
    ?assertEqual(ok, asobi_world_server:join(Pid, ~"p1")),
    timer:sleep(20),
    %% Spawns at {100.0, 100.0} => zone {1,1}, bounds x/y in [100, 200).
    {ok, ZonePid1} = asobi_zone_manager:get_zone(Mgr, {1, 1}),

    %% x=205 is past the raw edge (200) but within the 15-unit margin
    %% (200 + 100*0.15 = 215) - pos_to_zone/3 alone would call this zone {2,1}.
    asobi_zone:player_input(ZonePid1, ~"p1", #{
        ~"action" => ~"move", ~"x" => 205.0, ~"y" => 100.0
    }),
    timer:sleep(150),

    ?assertEqual(not_loaded, asobi_zone_manager:get_zone(Mgr, {2, 1})),
    ?assert(maps:is_key(~"p1", asobi_zone:get_entities(ZonePid1))),
    stop_world(Ctx).

%% Regression for widgrensit/asobi#248 (security review): move_player/4 is a
%% cast, so a rate-limited crossing must be decided BEFORE that cast - once
%% resolve_zone_crossings/1 fires it, there is no undoing the hand-off. This
%% exercises asobi_rehome_limiter denying a crossing outright and asserts the
%% entity survives exactly where it was, the same guarantee
%% script_owned_player_entity_survives_crossing/0 proves for an unclaimed
%% hand-off - a rate-limited one must not destroy the entity either.
%%
%% It also asserts the denied entity's position was clamped back inside its
%% owning zone: denying the hand-off without correcting x/y left the entity's
%% true position outside the zone that still claims to own it - invisible to
%% query_radius/3 and query_rect/3 at its real location, and re-detected (and
%% re-denied) as a fresh crossing on every subsequent tick.
rehome_denied_by_rate_limit_survives() ->
    %% Not registered in setup/0 (see its comment) - one allowed crossing,
    %% then every other crossing in the 60s window is denied.
    %% seki:new_limiter/2 returns {error, already_registered} rather than
    %% raising if the name is already registered (e.g. by another test in
    %% this run with different options) - catch alone does not guard against
    %% that, since it is a return value, not an exception. Delete first so
    %% this test's own limit actually takes effect regardless of what ran
    %% before it.
    catch seki:delete_limiter(asobi_rehome_limiter),
    ok = seki:new_limiter(asobi_rehome_limiter, #{
        algorithm => sliding_window, limit => 1, window => 60000
    }),
    Self = self(),
    Ref = make_ref(),
    {ok, _} = application:ensure_all_started(telemetry),
    telemetry:attach(
        Ref, [asobi, rehome, rate_limited], fun(_E, _M, Meta, _) -> Self ! {denied, Meta} end, []
    ),
    Ctx = #{world_pid := Pid, zone_mgr := Mgr} = start_world(#{lazy_zones => true}),
    try
        ?assertEqual(ok, asobi_world_server:join(Pid, ~"p1")),
        timer:sleep(20),
        %% Spawns at {100.0, 100.0} => zone {1,1}.
        {ok, ZonePid1} = asobi_zone_manager:get_zone(Mgr, {1, 1}),

        %% First crossing: clears the margin, consumes the one allowed token.
        asobi_zone:player_input(ZonePid1, ~"p1", #{
            ~"action" => ~"move", ~"x" => 220.0, ~"y" => 100.0
        }),
        timer:sleep(150),
        ?assertMatch({ok, _}, asobi_zone_manager:get_zone(Mgr, {2, 1})),
        {ok, ZonePid2} = asobi_zone_manager:get_zone(Mgr, {2, 1}),
        ?assert(maps:is_key(~"p1", asobi_zone:get_entities(ZonePid2))),

        %% Second crossing: also clears its zone's margin, but the limiter is
        %% now exhausted - must be denied, not applied.
        asobi_zone:player_input(ZonePid2, ~"p1", #{
            ~"action" => ~"move", ~"x" => 220.0, ~"y" => 220.0
        }),
        timer:sleep(150),

        ?assertEqual(not_loaded, asobi_zone_manager:get_zone(Mgr, {2, 2})),
        Entities = asobi_zone:get_entities(ZonePid2),
        ?assert(maps:is_key(~"p1", Entities)),
        %% Zone {2,1} spans x in [200,300), y in [100,200): the attempted
        %% y=220 is clamped back just inside the top edge, x=220 is untouched
        %% (already inside the zone on that axis).
        #{x := DeniedX, y := DeniedY} = maps:get(~"p1", Entities),
        ?assertEqual(220.0, DeniedX),
        ?assert(DeniedY < 200.0),
        ?assert(DeniedY > 199.0),
        receive
            {denied, #{player_id := ~"p1"}} -> ok
        after 1000 -> ?assert(false, timeout_waiting_for_rehome_rate_limited_event)
        end
    after
        telemetry:detach(Ref),
        catch seki:reset(asobi_rehome_limiter, ~"p1"),
        stop_world(Ctx)
    end.

%% Regression for widgrensit/asobi#248 (security review): per-player limiting
%% alone doesn't bound the aggregate - every crossing's resubscribe makes a
%% blocking asobi_terrain_store call into the one store a whole world shares,
%% so N attackers each within their own per-player budget scale that load
%% linearly with attacker count. asobi_rehome_global_limiter is the ceiling.
%% Registered generously per-player and tightly globally, so only the global
%% limiter can be what denies this crossing.
rehome_denied_by_global_limit() ->
    %% Delete before create: see rehome_denied_by_rate_limit_survives/0's
    %% comment on why catch alone does not guarantee this test's own limits
    %% take effect over whatever another test in this run already registered.
    catch seki:delete_limiter(asobi_rehome_limiter),
    ok = seki:new_limiter(asobi_rehome_limiter, #{
        algorithm => sliding_window, limit => 1000, window => 60000
    }),
    catch seki:delete_limiter(asobi_rehome_global_limiter),
    ok = seki:new_limiter(asobi_rehome_global_limiter, #{
        algorithm => sliding_window, limit => 1, window => 60000
    }),
    %% Pre-spend the one global token so the very first crossing below is
    %% denied by it, not by coincidentally being the window's first check.
    seki:check(asobi_rehome_global_limiter, ~"global"),
    Self = self(),
    Ref = make_ref(),
    {ok, _} = application:ensure_all_started(telemetry),
    telemetry:attach(
        Ref, [asobi, rehome, rate_limited], fun(_E, _M, Meta, _) -> Self ! {denied, Meta} end, []
    ),
    Ctx = #{world_pid := Pid, zone_mgr := Mgr} = start_world(#{lazy_zones => true}),
    try
        ?assertEqual(ok, asobi_world_server:join(Pid, ~"p1")),
        timer:sleep(20),
        {ok, ZonePid1} = asobi_zone_manager:get_zone(Mgr, {1, 1}),
        asobi_zone:player_input(ZonePid1, ~"p1", #{
            ~"action" => ~"move", ~"x" => 220.0, ~"y" => 100.0
        }),
        timer:sleep(150),
        %% The player's own budget (1000) is untouched - only the global cap
        %% can have denied this, so the hand-off must not have happened.
        ?assertEqual(not_loaded, asobi_zone_manager:get_zone(Mgr, {2, 1})),
        ?assert(maps:is_key(~"p1", asobi_zone:get_entities(ZonePid1))),
        receive
            {denied, #{player_id := ~"p1"}} -> ok
        after 1000 -> ?assert(false, timeout_waiting_for_global_rehome_denial)
        end
    after
        telemetry:detach(Ref),
        catch seki:reset(asobi_rehome_limiter, ~"p1"),
        catch seki:reset(asobi_rehome_global_limiter, ~"global"),
        stop_world(Ctx)
    end.

%% Regression for widgrensit/asobi#248 (security review): a game script can
%% type a non-session entity "player" (a bot, a decoy) without it ever
%% joining, so the world server holds no player_zones entry for it.
%% resolve_zone_crossings/1 must not delete such an entity just because it
%% attempted a hand-off nothing claimed - it must stay exactly where it was.
script_owned_player_entity_survives_crossing() ->
    Ctx = #{world_pid := Pid, zone_mgr := Mgr} = start_world(#{lazy_zones => true}),
    {ok, ZonePid1, created} = asobi_zone_manager:ensure_zone(Mgr, {1, 1}),
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

%% Regression for widgrensit/asobi#248 (security review): a crossing used to
%% unsubscribe the whole old ring and resubscribe the whole new ring, even
%% though most zones are common to both - each resubscribe resends a full
%% zone snapshot. On a grid_size=5, view_radius=1 world, moving from zone
%% {1,1} to {2,1} keeps {1,0}..{2,2} in the ring the whole time: only the
%% x=0 column should be dropped and only the x=3 column newly picked up.
%%
%% Retroactive coverage: the ring diff itself shipped in #259, not in the
%% commit this test was added by. It lives here because that is where it
%% was originally (mis-)attributed.
world_input_crossing_touches_only_ring_delta() ->
    %% subscribe_interest_zones/4 only subscribes zones that already exist
    %% (it uses get_zone, not ensure_zone, so it never spins up an empty zone
    %% just because it's in view) - lazy_zones=false pre-spawns the whole
    %% grid so every ring zone is subscribable at join time.
    Ctx = #{world_pid := Pid, zone_mgr := Mgr} = start_world(#{grid_size => 5}),
    %% A pg-registered session, like every other test in this module that
    %% asserts on subscriptions. `subscribe_interest_zones/4` resolves the
    %% player through `find_player_pid/1`, which reads
    %% `pg:get_members(nova_scope, {player, PlayerId})` - with no member the
    %% pid is `undefined` and asobi_world_server skips the subscribe
    %% entirely, so every count below is 0.
    %%
    %% Without this the test passed only in a full eunit run, by finding a
    %% live process ANOTHER module had left registered under `{player,
    %% <<"p1">>}` in the shared scope - so it was green for a reason that had
    %% nothing to do with the ring diff it exists to prove, and red whenever
    %% the module was run on its own. Hence the distinctive id: `p1` is what
    %% made it borrowable.
    Player = ~"ring275_p1",
    SessionPid = asobi_test_helpers:fake_session(Player, self()),
    %% The session and the world are released by the outer `after`, so it has
    %% to open BEFORE the join and the asserts below - the first of which is
    %% the one this test used to fail on. Releasing them only from a block the
    %% failure jumps over would leak a pg-registered session and a ticking
    %% world into the rest of the run, which is the class of contamination
    %% this commit exists to remove.
    try
        ?assertEqual(ok, asobi_world_server:join(Pid, Player)),
        timer:sleep(20),
        %% Spawns at {100.0, 100.0} => zone {1,1}.
        {ok, Z11} = asobi_zone_manager:get_zone(Mgr, {1, 1}),
        ?assertEqual(1, asobi_zone:get_subscriber_count(Z11)),
        {ok, Z00} = asobi_zone_manager:get_zone(Mgr, {0, 0}),
        ?assertEqual(1, asobi_zone:get_subscriber_count(Z00)),
        {ok, Z30} = asobi_zone_manager:get_zone(Mgr, {3, 0}),
        ?assertEqual(0, asobi_zone:get_subscriber_count(Z30)),
        ring_delta_crossing(Mgr, Player, Z11, Z00, Z30)
    after
        asobi_test_helpers:release_session(Player, SessionPid),
        stop_world(Ctx)
    end.

%% Reaching the same end state doesn't prove the ring diff ran instead of
%% a full unsubscribe-everything/resubscribe-everything pass - both reach
%% identical final counts. Count the actual subscribe/unsubscribe calls:
%% only 3 zones left the ring and 3 entered it (not all 9), plus one more
%% unconditional subscribe to the destination zone itself (asobi#275: the
%% crossing player is always (re-)subscribed to the zone they land in,
%% even though it stayed in the ring and so is never in the ring diff).
ring_delta_crossing(Mgr, Player, Z11, Z00, Z30) ->
    Self = self(),
    meck:new(asobi_zone, [passthrough]),
    try
        meck:expect(asobi_zone, subscribe, fun(ZPid, Sub) ->
            Self ! subscribed,
            meck:passthrough([ZPid, Sub])
        end),
        meck:expect(asobi_zone, unsubscribe, fun(ZPid, PId) ->
            Self ! unsubscribed,
            meck:passthrough([ZPid, PId])
        end),

        %% x=225 clears zone {1,1}'s margin (edge at 200 + 15% of 100), landing
        %% in zone {2,1}.
        asobi_zone:player_input(Z11, Player, #{
            ~"action" => ~"move", ~"x" => 225.0, ~"y" => 100.0
        }),
        timer:sleep(150),

        SubscribeCalls = count_messages(subscribed),
        UnsubscribeCalls = count_messages(unsubscribed),

        ?assertEqual(4, SubscribeCalls),
        ?assertEqual(3, UnsubscribeCalls),
        %% {1,1} is in both rings - never unsubscribed, so it's never re-touched.
        ?assertEqual(1, asobi_zone:get_subscriber_count(Z11)),
        %% {0,0} left the ring (x=0 column no longer in range) - unsubscribed.
        ?assertEqual(0, asobi_zone:get_subscriber_count(Z00)),
        %% {3,0} entered the ring (x=3 column, new only) - freshly subscribed.
        ?assertEqual(1, asobi_zone:get_subscriber_count(Z30)),
        %% {2,1} is the destination zone itself - subscribed unconditionally.
        {ok, Z21} = asobi_zone_manager:get_zone(Mgr, {2, 1}),
        ?assertEqual(1, asobi_zone:get_subscriber_count(Z21))
    after
        meck:unload(asobi_zone)
    end.

count_messages(Tag) ->
    receive
        Tag -> 1 + count_messages(Tag)
    after 0 -> 0
    end.

%% Blocks until PlayerId's forwarded messages mention EntityId in ANY of the
%% three world.tick carriers, or the timeout elapses.
%%
%% All three are needed since the join keyframe stopped being a snapshot of
%% `entities`. A backfilled entity now reaches an existing subscriber through the
%% shared broadcast, which is pre-encoded JSON precisely so one encode serves
%% every subscriber (ADR 0001), so a helper that only reads the tuple carriers
%% would sit blind through the frame that actually delivers it.
received_entity(PlayerId, EntityId) ->
    receive
        {PlayerId, {asobi_message, Msg}} ->
            case tick_ops(Msg) of
                skip ->
                    received_entity(PlayerId, EntityId);
                Ops ->
                    case lists:any(fun(Op) -> op_id(Op) =:= EntityId end, Ops) of
                        true -> true;
                        false -> received_entity(PlayerId, EntityId)
                    end
            end
    after 500 -> false
    end.

%% The op list out of whichever world.tick carrier this is, or `skip` for a
%% message that is not one.
tick_ops({zone_keyframe, _Meta, Ops}) -> Ops;
tick_ops({zone_removals, _Coords, Ops}) -> Ops;
tick_ops({zone_delta_raw, PreEncoded}) -> decoded_ops(PreEncoded);
tick_ops(_Other) -> skip.

decoded_ops(PreEncoded) ->
    case json:decode(PreEncoded) of
        #{~"type" := ~"world.tick", ~"payload" := #{~"updates" := Ops}} -> Ops;
        _ -> skip
    end.

op_id(#{~"id" := Id}) -> Id;
op_id(_) -> undefined.

%% Regression for widgrensit/asobi#275: a zone that a crossing brings into
%% existence for the first time must pick up every already-connected player
%% whose interest ring already covered it, not just the crossing player.
%% Before the fix, a stationary neighbour's earlier subscribe attempt (made
%% back when the zone was still not_loaded) was silently skipped, and the
%% ring-diff on the crossing player's own move never re-touched a zone that
%% stayed in their ring - so nothing ever subscribed the neighbour to it.
%%
%% Player ids are namespaced (bf275_*) and each has a real pg-registered
%% session killed at the end - a stale {player, <<"p1">>} registration
%% leaking from an unrelated suite must not be able to satisfy this test the
%% way a bare ~"p1"/~"p2" id previously could.
crossing_into_a_lazily_created_zone_backfills_stationary_neighbours() ->
    Ctx =
        #{world_pid := Pid, zone_mgr := Mgr} = start_world(#{
            lazy_zones => true, grid_size => 5
        }),
    Ada = ~"bf275_ada",
    Bob = ~"bf275_bob",
    AdaPid = asobi_test_helpers:fake_session(Ada, self()),
    BobPid = asobi_test_helpers:fake_session(Bob, self()),
    try
        %% Ada joins and stays put. Spawns at {100.0,100.0} => zone {1,1};
        %% with view_radius=1 that ring already covers {2,1} - but {2,1} is
        %% not_loaded at join, so the ring-subscribe attempt to it silently
        %% no-ops (subscribe_interest_zones/4 uses get_zone, never
        %% ensure_zone).
        ?assertEqual(ok, asobi_world_server:join(Pid, Ada)),
        timer:sleep(20),
        ?assertEqual(not_loaded, asobi_zone_manager:get_zone(Mgr, {2, 1})),

        %% Bob joins (also spawns in {1,1}) and then crosses one zone east
        %% into {2,1} - the same crossing that lazily creates the zone for
        %% the first time.
        ?assertEqual(ok, asobi_world_server:join(Pid, Bob)),
        timer:sleep(20),
        {ok, Z11} = asobi_zone_manager:get_zone(Mgr, {1, 1}),
        %% x=225 clears zone {1,1}'s margin (edge at 200 + 15% of 100),
        %% landing in zone {2,1}.
        asobi_zone:player_input(Z11, Bob, #{
            ~"action" => ~"move", ~"x" => 225.0, ~"y" => 100.0
        }),
        timer:sleep(150),

        {ok, Z21} = asobi_zone_manager:get_zone(Mgr, {2, 1}),
        %% The right pids, not just the right keys.
        ?assertMatch(
            #{subscribers := #{Ada := {AdaPid, _}, Bob := {BobPid, _}}}, sys:get_state(Z21)
        ),
        %% And the thing #275 actually reports: the stationary neighbour
        %% receives the crossing player's entity.
        ?assert(received_entity(Ada, Bob))
    after
        asobi_test_helpers:release_session(Ada, AdaPid),
        asobi_test_helpers:release_session(Bob, BobPid),
        stop_world(Ctx)
    end.

%% Regression for widgrensit/asobi#271: under lazy_zones an unloaded
%% neighbour is the normal state, and an NPC crossing into one used to be
%% deleted outright while a player crossing the same boundary got the zone
%% created for them. The NPC must arrive in a zone created for it, and the
%% stationary neighbour whose ring already covered those coords must be
%% backfilled onto it exactly as #275 requires for a player-created zone.
npc_crossing_into_an_unloaded_zone_creates_it_and_backfills() ->
    Ctx =
        #{world_pid := Pid, zone_mgr := Mgr} = start_world(#{
            lazy_zones => true, grid_size => 5
        }),
    Ada = ~"npc271_ada",
    AdaPid = asobi_test_helpers:fake_session(Ada, self()),
    try
        %% Ada joins at {100.0,100.0} => zone {1,1}; {2,1} is in her ring but
        %% not loaded, so her ring-subscribe to it no-ops.
        ?assertEqual(ok, asobi_world_server:join(Pid, Ada)),
        timer:sleep(20),
        ?assertEqual(not_loaded, asobi_zone_manager:get_zone(Mgr, {2, 1})),

        {ok, Z11} = asobi_zone_manager:get_zone(Mgr, {1, 1}),
        %% x=225 clears zone {1,1}'s margin (edge at 200 + 15% of 100).
        asobi_zone:add_entity(Z11, ~"npc271", #{type => ~"npc", x => 225.0, y => 100.0}),
        timer:sleep(150),

        {ok, Z21} = asobi_zone_manager:get_zone(Mgr, {2, 1}),
        ?assertNot(maps:is_key(~"npc271", asobi_zone:get_entities(Z11))),
        ?assert(maps:is_key(~"npc271", asobi_zone:get_entities(Z21))),
        ?assertMatch(#{subscribers := #{Ada := {AdaPid, _}}}, sys:get_state(Z21)),
        ?assert(received_entity(Ada, ~"npc271"))
    after
        asobi_test_helpers:release_session(Ada, AdaPid),
        stop_world(Ctx)
    end.

%% Regression for widgrensit/asobi#275, spawn_at variant: a script-driven
%% game.spawn call can lazily create a zone just as a player crossing can -
%% same backfill applies, just with no acting player of its own to exclude
%% (ExcludePlayerId = undefined at that call site). The template_id is
%% deliberately unresolvable - spawn_at's backfill runs off ensure_zone's
%% created/existing status, not off whether the spawn itself succeeds, so
%% this doesn't need a real template registered in the test game module.
script_spawn_into_a_lazily_created_zone_backfills_neighbours() ->
    Ctx =
        #{world_pid := Pid, zone_mgr := Mgr} = start_world(#{
            lazy_zones => true, grid_size => 5
        }),
    Ada = ~"bf275_spawn_ada",
    AdaPid = asobi_test_helpers:fake_session(Ada, self()),
    try
        ?assertEqual(ok, asobi_world_server:join(Pid, Ada)),
        timer:sleep(20),
        ?assertEqual(not_loaded, asobi_zone_manager:get_zone(Mgr, {2, 1})),

        %% {225.0, 100.0} is zone {2,1} - already in Ada's interest ring
        %% (view_radius=1 from {1,1}), but not yet loaded.
        ok = asobi_world_server:spawn_at(Pid, ~"unresolvable_template", {225.0, 100.0}),
        timer:sleep(150),

        {ok, Z21} = asobi_zone_manager:get_zone(Mgr, {2, 1}),
        ?assertMatch(#{subscribers := #{Ada := {AdaPid, _}}}, sys:get_state(Z21))
    after
        asobi_test_helpers:release_session(Ada, AdaPid),
        stop_world(Ctx)
    end.

%% Blocks until PlayerId's forwarded messages include a zone_delta removal
%% (op "r") for EntityId, or the timeout elapses.
received_removal(PlayerId, EntityId) ->
    receive
        {PlayerId, {asobi_message, Msg}} when
            element(1, Msg) =:= zone_removals;
            element(1, Msg) =:= zone_delta_raw;
            element(1, Msg) =:= zone_keyframe
        ->
            Ops =
                case tick_ops(Msg) of
                    skip -> [];
                    L -> L
                end,
            HasRemoval = lists:any(
                fun
                    (#{~"op" := ~"r", ~"id" := Id}) -> Id =:= EntityId;
                    (_) -> false
                end,
                Ops
            ),
            case HasRemoval of
                true -> true;
                false -> received_removal(PlayerId, EntityId)
            end
    after 500 -> false
    end.

%% Regression for widgrensit/asobi#293: leaving a zone's interest ring must
%% mirror joining it - subscribe_new/3 already sends a full "add" snapshot to
%% a fresh subscriber, but unsubscribing previously sent nothing, so a
%% stationary occupant of a zone a player has ridden out of the ring stayed
%% frozen on that departing player's client forever. Ada spawns and stays put
%% in zone {1,1}; Bob spawns alongside her (so he holds her entity via the
%% shared zone's snapshot) then crosses far enough east that {1,1} falls
%% entirely outside his new interest ring - not just a one-zone crossing,
%% which #248/#275 already covered via the entity's own removal, but the
%% ring-only drop of a zone whose *other* occupants never moved at all.
crossing_out_of_ring_removes_stationary_neighbour() ->
    Ctx =
        #{world_pid := Pid, zone_mgr := Mgr} = start_world(#{
            lazy_zones => true, grid_size => 6
        }),
    Ada = ~"leave_ring_ada",
    Bob = ~"leave_ring_bob",
    AdaPid = asobi_test_helpers:fake_session(Ada, self()),
    BobPid = asobi_test_helpers:fake_session(Bob, self()),
    try
        %% Both spawn at {100.0, 100.0} => zone {1,1}.
        ?assertEqual(ok, asobi_world_server:join(Pid, Ada)),
        ?assertEqual(ok, asobi_world_server:join(Pid, Bob)),
        timer:sleep(20),
        {ok, Z11} = asobi_zone_manager:get_zone(Mgr, {1, 1}),
        ?assert(received_entity(Bob, Ada)),

        %% Bob crosses three zones east - view_radius=1 keeps {0,0}..{2,2}
        %% around his old zone {1,1}, but his new ring around {4,1} is
        %% {3,0}..{5,2}, nowhere near it, so {1,1} must be dropped entirely.
        asobi_zone:player_input(Z11, Bob, #{
            ~"action" => ~"move", ~"x" => 430.0, ~"y" => 100.0
        }),
        timer:sleep(150),

        %% Ada never moved, so she's still subscribed - only Bob left.
        ?assertEqual(1, asobi_zone:get_subscriber_count(Z11)),
        ?assert(received_removal(Bob, Ada))
    after
        asobi_test_helpers:release_session(Ada, AdaPid),
        asobi_test_helpers:release_session(Bob, BobPid),
        stop_world(Ctx)
    end.

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

%% Regression for widgrensit/asobi#269: the crossing check matched entity
%% fields by atom key only, but every entity map a Lua world produces comes
%% back from Luerl binary-keyed - so no player in a Lua world ever crossed a
%% boundary, and their interest ring stayed frozen at the spawn zone for the
%% whole session. asobi_lua_shaped_world_game reproduces that key shape
%% without pulling Lua into this repo.
binary_keyed_player_rehomes_across_boundary() ->
    Ctx =
        #{world_pid := Pid, zone_mgr := Mgr} = start_world(#{
            lazy_zones => true, game_module => asobi_lua_shaped_world_game
        }),
    ?assertEqual(ok, asobi_world_server:join(Pid, ~"p1")),
    timer:sleep(20),
    %% Spawns at {100.0, 100.0} => zone {1,1}.
    {ok, ZonePid1} = asobi_zone_manager:get_zone(Mgr, {1, 1}),
    ?assert(maps:is_key(~"p1", asobi_zone:get_entities(ZonePid1))),

    asobi_zone:player_input(ZonePid1, ~"p1", #{
        ~"action" => ~"move", ~"x" => 250.0, ~"y" => 250.0
    }),
    timer:sleep(150),

    ?assertMatch({ok, _}, asobi_zone_manager:get_zone(Mgr, {2, 2})),
    {ok, ZonePid2} = asobi_zone_manager:get_zone(Mgr, {2, 2}),
    Entity = maps:get(~"p1", asobi_zone:get_entities(ZonePid2)),
    ?assertEqual(250.0, maps:get(~"x", Entity)),
    ?assertNot(maps:is_key(~"p1", asobi_zone:get_entities(ZonePid1))),
    stop_world(Ctx).

%% Regression widgrensit/asobi#283 (join half): ensure_zone/2 hands out a pid
%% without a lease on it, so a zone that is genuinely empty when the manager's
%% reap sweep fires stops while a placement is already in flight against it.
%% The add_entity cast was dropped on the floor and the drain call that
%% followed exited the whole world gen_statem with `normal` - every player in
%% the world lost, over one join. Stopping the zone from inside ensure_zone/2
%% reproduces exactly that ordering, deterministically.
join_survives_zone_reaped_after_lookup() ->
    Ctr = counters:new(1, []),
    meck:new(asobi_zone_manager, [passthrough, no_link]),
    meck:expect(asobi_zone_manager, ensure_zone, fun(Ref, Coords) ->
        Result = meck:passthrough([Ref, Coords]),
        reap_first_zone_at({1, 1}, Coords, Result, Ctr)
    end),
    Ctx = #{world_pid := Pid, zone_mgr := Mgr} = start_world(#{lazy_zones => true}),
    try
        ?assertEqual(ok, asobi_world_server:join(Pid, ~"p1")),
        ?assert(is_process_alive(Pid)),
        {ok, ZonePid} = asobi_zone_manager:get_zone(Mgr, {1, 1}),
        ?assert(is_process_alive(ZonePid)),
        ?assert(maps:is_key(~"p1", asobi_zone:get_entities(ZonePid)))
    after
        stop_world(Ctx),
        meck:unload(asobi_zone_manager)
    end.

%% Same race on the crossing half: the destination zone a crossing just
%% resolved can be reaped before the entity reaches it.
crossing_survives_zone_reaped_after_lookup() ->
    Ctr = counters:new(1, []),
    Ctx = #{world_pid := Pid, zone_mgr := Mgr} = start_world(#{lazy_zones => true}),
    try
        ?assertEqual(ok, asobi_world_server:join(Pid, ~"p1")),
        timer:sleep(20),
        meck:new(asobi_zone_manager, [passthrough, no_link]),
        meck:expect(asobi_zone_manager, ensure_zone, fun(Ref, Coords) ->
            Result = meck:passthrough([Ref, Coords]),
            reap_first_zone_at({2, 2}, Coords, Result, Ctr)
        end),
        %% Player starts at {100.0, 100.0} => zone {1,1}; move into {2,2}.
        asobi_world_server:move_player(Pid, ~"p1", {250.0, 250.0}),
        timer:sleep(50),
        ?assert(is_process_alive(Pid)),
        {ok, ZonePid} = asobi_zone_manager:get_zone(Mgr, {2, 2}),
        ?assert(is_process_alive(ZonePid)),
        ?assert(maps:is_key(~"p1", asobi_zone:get_entities(ZonePid)))
    after
        stop_world(Ctx),
        meck:unload(asobi_zone_manager)
    end.

%% Stops the zone the caller just resolved, once, mimicking a reap sweep
%% landing in the gap between the lookup and the caller using the pid.
reap_first_zone_at(Target, Coords, {ok, ZonePid, _Status} = Result, Ctr) when Coords =:= Target ->
    case counters:get(Ctr, 1) of
        0 ->
            counters:add(Ctr, 1, 1),
            ok = gen_server:stop(ZonePid, normal, 1000),
            Result;
        _ ->
            Result
    end;
reap_first_zone_at(_Target, _Coords, Result, _Ctr) ->
    Result.

%% sys:get_state/1 is term(); a test reading a field out of a zone's state
%% narrows first rather than indexing an unknown shape.
-spec zone_state(pid()) -> map().
zone_state(ZonePid) ->
    case sys:get_state(ZonePid) of
        State when is_map(State) -> State
    end.
