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

zone_lifecycle_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        {"init_zone_state runs via handle_continue", fun init_zone_state_runs/0},
        {"game module without the callback is unaffected", fun no_callback_unaffected/0},
        {"dump_zone_state strips the runtime before snapshot", fun dump_zone_state_strips_runtime/0}
    ]}.

init_zone_state_runs() ->
    Pid = start_zone(asobi_zone_ctx_test_game, #{}),
    ZoneState = maps:get(zone_state, sys:get_state(Pid)),
    ?assertEqual(init_zone_state, maps:get(built_by, ZoneState)),
    ?assertEqual({2, 3}, maps:get(coords, ZoneState)),
    ?assert(is_reference(maps:get(runtime, ZoneState))),
    gen_server:stop(Pid).

no_callback_unaffected() ->
    %% asobi_test_world_game exports no init_zone_state; zone_state stays as given.
    Pid = start_zone(asobi_test_world_game, #{zone_state => #{seeded => true}}),
    ?assertEqual(#{seeded => true}, maps:get(zone_state, sys:get_state(Pid))),
    gen_server:stop(Pid).

dump_zone_state_strips_runtime() ->
    %% The motivating bug: a live runtime in zone_state cannot survive jsonb.
    %% Snapshots must route through dump_zone_state, which drops it. Drive the
    %% real terminate snapshot path; no DB needed.
    meck:new(asobi_zone_snapshotter, [passthrough]),
    Self = self(),
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
