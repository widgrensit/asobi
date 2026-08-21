-module(asobi_zone_lifecycle_tests).
-include_lib("eunit/include/eunit.hrl").

%% The zone builds its runtime zone_state in its own process via the optional
%% init_zone_state/2 callback (handle_continue), for every creation path. Game
%% modules that don't export it are unaffected.

setup() ->
    case whereis(nova_scope) of
        undefined -> pg:start_link(nova_scope);
        _ -> ok
    end,
    ok.

cleanup(_) ->
    ok.

start_zone(GameMod, Overrides) ->
    Config = maps:merge(
        #{
            world_id => ~"lifecycle_world",
            coords => {2, 3},
            ticker_pid => self(),
            game_module => GameMod,
            zone_state => #{}
        },
        Overrides
    ),
    {ok, Pid} = asobi_zone:start_link(Config),
    Pid.

%% sys:get_state/1 returns term() generically - narrow it to the map shape
%% asobi_zone's gen_server state actually is.
-spec gen_server_state(pid()) -> map().
gen_server_state(Pid) ->
    case sys:get_state(Pid) of
        State when is_map(State) -> State
    end.

zone_lifecycle_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        {"init_zone_state runs via handle_continue", fun init_zone_state_runs/0},
        {"game module without the callback is unaffected", fun no_callback_unaffected/0},
        {"dump_zone_state strips the runtime before snapshot",
            fun dump_zone_state_strips_runtime/0},
        {"terminating a zone clears its pending script-log drop count",
            fun terminate_clears_script_log_drop_row/0}
    ]}.

init_zone_state_runs() ->
    Pid = start_zone(asobi_zone_ctx_test_game, #{}),
    ZoneState = maps:get(zone_state, gen_server_state(Pid)),
    ?assertEqual(init_zone_state, maps:get(built_by, ZoneState)),
    ?assertEqual({2, 3}, maps:get(coords, ZoneState)),
    ?assert(is_reference(maps:get(runtime, ZoneState))),
    gen_server:stop(Pid).

no_callback_unaffected() ->
    %% asobi_test_world_game exports no init_zone_state; zone_state stays as given.
    Pid = start_zone(asobi_test_world_game, #{zone_state => #{seeded => true}}),
    ?assertEqual(#{seeded => true}, maps:get(zone_state, gen_server_state(Pid))),
    gen_server:stop(Pid).

dump_zone_state_strips_runtime() ->
    %% The motivating bug: a live runtime in zone_state cannot survive jsonb.
    %% Snapshots must route through dump_zone_state, which drops it. Drive the
    %% real terminate snapshot path; no DB needed.
    meck:new(asobi_zone_snapshotter, [passthrough]),
    Self = self(),
    meck:expect(asobi_zone_snapshotter, load_snapshot, fun(_, _) -> {error, not_found} end),
    meck:expect(asobi_zone_snapshotter, snapshot_sync, fun(Data) ->
        Self ! {snapshot, Data},
        ok
    end),
    try
        Pid = start_zone(asobi_zone_ctx_test_game, #{persistence => true}),
        gen_server:stop(Pid),
        receive
            {snapshot, Data} ->
                ZoneState = maps:get(zone_state, Data),
                ?assertNot(maps:is_key(runtime, ZoneState)),
                ?assertEqual(init_zone_state, maps:get(built_by, ZoneState))
        after 1000 ->
            ?assert(false)
        end
    after
        meck:unload(asobi_zone_snapshotter)
    end.

%% asobi#252 code review: asobi_script_log_limiter:forget/1 is called from
%% all three terminate/2 clauses, but nothing proved it - deleting the call
%% left the full suite green. Seed a drop-count row directly (bypassing
%% seki/rate-limiting entirely) and drive the normal-termination path to
%% confirm the row is actually gone afterward, not just that forget/1 works
%% in isolation (already covered by asobi_script_log_limiter_tests). Only
%% the `normal` reason is exercised here: start_zone/2 links the zone to
%% this test process (via start_link/1, never unlinked in this file), and
%% the other two terminate/2 clauses ({shutdown, _} and any other reason)
%% both propagate as a fatal EXIT signal to a non-trapping linked process -
%% stopping via either would kill the test process itself, not just the
%% zone. All three clauses call forget/1 identically (same call, same
%% position, before pg:leave), so this single case already protects the
%% wiring a refactor could plausibly break.
%% Every bucket a zone can mint, not just the base one: forget/1 deletes an exact
%% key, so a derived bucket that terminate/2 does not name is a permanent ETS row
%% per zone. Seeding only {WorldId, Coords} is what let the derived buckets go
%% uncovered - deleting their forget/1 call left the whole suite green.
terminate_clears_script_log_drop_row() ->
    ok = asobi_script_log_limiter:init_table(),
    WorldId = ~"lc_normal",
    Coords = {9, 1},
    Keys = [
        {WorldId, Coords},
        {WorldId, Coords, invalid_consumed_seq},
        {WorldId, Coords, input_rejected},
        {WorldId, Coords, batch_contract},
        {WorldId, Coords, unknown_outcome},
        {WorldId, Coords, no_input_handler}
    ],
    [true = ets:insert(asobi_script_log_limiter_drops, {K, 3}) || K <- Keys],
    Pid = start_zone(asobi_test_world_game, #{world_id => WorldId, coords => Coords}),
    gen_server:stop(Pid),
    [?assertEqual({K, []}, {K, ets:lookup(asobi_script_log_limiter_drops, K)}) || K <- Keys].
