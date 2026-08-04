-module(asobi_world_ticker_tests).
-include_lib("eunit/include/eunit.hrl").

start_ticker() ->
    start_ticker(#{}).

start_ticker(Overrides) ->
    Config = maps:merge(#{tick_rate => 100}, Overrides),
    {ok, Pid} = asobi_world_ticker:start_link(Config),
    Pid.

-spec get_state_map(pid()) -> map().
get_state_map(Pid) ->
    case sys:get_state(Pid) of
        S when is_map(S) -> S
    end.

ticker_test_() ->
    {foreach, fun() -> ok end, fun(_) -> ok end, [
        {"get_tick starts at 0", fun get_tick_starts_at_zero/0},
        {"set_zones puts all zones in hot", fun set_zones_all_hot/0},
        {"promote_zone adds to hot", fun promote_zone_adds_to_hot/0},
        {"demote_zone moves to cold", fun demote_zone_moves_to_cold/0},
        {"remove_zone removes from both", fun remove_zone_removes/0},
        {"promote is idempotent", fun promote_idempotent/0},
        {"demote is idempotent", fun demote_idempotent/0},
        {"cold_tick_divisor defaults to 10", fun cold_divisor_default/0},
        {"cold_tick_divisor is configurable", fun cold_divisor_configurable/0},
        {"world tick emits telemetry", fun world_tick_emits_telemetry/0},
        {"world tick telemetry is sampled", fun world_tick_telemetry_is_sampled/0},
        {"sample interval defaults to ~1s", fun sample_every_defaults_to_one_second/0}
    ]}.

get_tick_starts_at_zero() ->
    Pid = start_ticker(),
    ?assertEqual(0, asobi_world_ticker:get_tick(Pid)).

set_zones_all_hot() ->
    Pid = start_ticker(),
    Z1 = spawn(fun() ->
        receive
            stop -> ok
        end
    end),
    Z2 = spawn(fun() ->
        receive
            stop -> ok
        end
    end),
    asobi_world_ticker:set_zones(Pid, [Z1, Z2], self()),
    timer:sleep(10),
    State = get_state_map(Pid),
    ?assertEqual([Z1, Z2], maps:get(hot_zones, State)),
    ?assertEqual([], maps:get(cold_zones, State)).

promote_zone_adds_to_hot() ->
    Pid = start_ticker(),
    Z1 = spawn(fun() ->
        receive
            stop -> ok
        end
    end),
    asobi_world_ticker:promote_zone(Pid, Z1),
    timer:sleep(10),
    State = get_state_map(Pid),
    ?assert(lists:member(Z1, maps:get(hot_zones, State))),
    ?assertNot(lists:member(Z1, maps:get(cold_zones, State))).

demote_zone_moves_to_cold() ->
    Pid = start_ticker(),
    Z1 = spawn(fun() ->
        receive
            stop -> ok
        end
    end),
    asobi_world_ticker:promote_zone(Pid, Z1),
    timer:sleep(10),
    asobi_world_ticker:demote_zone(Pid, Z1),
    timer:sleep(10),
    State = get_state_map(Pid),
    ?assertNot(lists:member(Z1, maps:get(hot_zones, State))),
    ?assert(lists:member(Z1, maps:get(cold_zones, State))).

remove_zone_removes() ->
    Pid = start_ticker(),
    Z1 = spawn(fun() ->
        receive
            stop -> ok
        end
    end),
    asobi_world_ticker:promote_zone(Pid, Z1),
    timer:sleep(10),
    asobi_world_ticker:remove_zone(Pid, Z1),
    timer:sleep(10),
    State = get_state_map(Pid),
    ?assertNot(lists:member(Z1, maps:get(hot_zones, State))),
    ?assertNot(lists:member(Z1, maps:get(cold_zones, State))).

promote_idempotent() ->
    Pid = start_ticker(),
    Z1 = spawn(fun() ->
        receive
            stop -> ok
        end
    end),
    asobi_world_ticker:promote_zone(Pid, Z1),
    timer:sleep(10),
    asobi_world_ticker:promote_zone(Pid, Z1),
    timer:sleep(10),
    State = get_state_map(Pid),
    Hot = maps:get(hot_zones, State),
    ?assertEqual(1, length([Z || Z <- Hot, Z =:= Z1])).

demote_idempotent() ->
    Pid = start_ticker(),
    Z1 = spawn(fun() ->
        receive
            stop -> ok
        end
    end),
    asobi_world_ticker:demote_zone(Pid, Z1),
    timer:sleep(10),
    asobi_world_ticker:demote_zone(Pid, Z1),
    timer:sleep(10),
    State = get_state_map(Pid),
    Cold = maps:get(cold_zones, State),
    ?assertEqual(1, length([Z || Z <- Cold, Z =:= Z1])).

cold_divisor_default() ->
    Pid = start_ticker(),
    State = get_state_map(Pid),
    ?assertEqual(10, maps:get(cold_tick_divisor, State)).

cold_divisor_configurable() ->
    Pid = start_ticker(#{cold_tick_divisor => 5}),
    State = get_state_map(Pid),
    ?assertEqual(5, maps:get(cold_tick_divisor, State)).

%% --- #313: world tick telemetry ---
%%
%% Before this, asobi_world_ticker emitted nothing at all, so there was no way
%% for an operator to see how long a world tick takes - the signal that
%% degrades first under entity load.

world_tick_emits_telemetry() ->
    Pid = start_ticker(#{
        tick_rate => 10, tick_sample_interval_ms => 10, world_id => ~"w-tick-1"
    }),
    Events = with_subscription([asobi, world, tick], ~"w-tick-1", fun(Ref) ->
        asobi_world_ticker:set_zones(Pid, [], self()),
        collect_for(Ref, 200)
    end),
    ?assert(length(Events) >= 1),
    [{Measurements, Metadata} | _] = Events,
    ?assertEqual(~"w-tick-1", maps:get(world_id, Metadata)),
    ?assertEqual(1, maps:get(count, Measurements)),
    ?assertEqual(0, maps:get(zone_count, Measurements)),
    ?assert(is_integer(maps:get(duration_ms, Measurements))),
    ?assert(maps:get(max_duration_ms, Measurements) >= maps:get(duration_ms, Measurements)).

%% One event per tick per world (20 Hz by default) is too hot for a raw sink,
%% so the ticker samples. Compare events against ticks actually taken in the
%% same window rather than against wall clock, which keeps this honest on a
%% loaded machine.
world_tick_telemetry_is_sampled() ->
    Pid = start_ticker(#{
        tick_rate => 10, tick_sample_interval_ms => 50, world_id => ~"w-tick-2"
    }),
    ?assertEqual(5, maps:get(sample_every, get_state_map(Pid))),
    {Events, Ticks} = with_subscription([asobi, world, tick], ~"w-tick-2", fun(Ref) ->
        asobi_world_ticker:set_zones(Pid, [], self()),
        Before = asobi_world_ticker:get_tick(Pid),
        Collected = collect_for(Ref, 300),
        {Collected, asobi_world_ticker:get_tick(Pid) - Before}
    end),
    ?assert(Ticks >= 5),
    ?assert(length(Events) >= 1),
    ?assert(length(Events) * 2 =< Ticks).

sample_every_defaults_to_one_second() ->
    ?assertEqual(20, maps:get(sample_every, get_state_map(start_ticker(#{tick_rate => 50})))),
    ?assertEqual(10, maps:get(sample_every, get_state_map(start_ticker(#{tick_rate => 100})))),
    %% A tick slower than the sample interval still samples every tick.
    ?assertEqual(1, maps:get(sample_every, get_state_map(start_ticker(#{tick_rate => 5000})))).

%% Filter on world_id: a ticker start_link'ed by an earlier test outlives that
%% test's process (a non-trapping process ignores a `normal` exit signal from
%% its link) and keeps emitting, so an unfiltered subscription counts events
%% from tickers this test never started.
with_subscription(Event, WorldId, Fun) ->
    {ok, _} = application:ensure_all_started(telemetry),
    Self = self(),
    Ref = make_ref(),
    telemetry:attach(
        Ref,
        Event,
        fun
            (_E, M, #{world_id := W} = Meta, _) when W =:= WorldId -> Self ! {Ref, M, Meta};
            (_E, _M, _Meta, _) -> ok
        end,
        []
    ),
    try
        Fun(Ref)
    after
        telemetry:detach(Ref)
    end.

collect_for(Ref, WindowMs) ->
    collect_until(Ref, erlang:monotonic_time(millisecond) + WindowMs, []).

collect_until(Ref, Deadline, Acc) ->
    Wait = max(0, Deadline - erlang:monotonic_time(millisecond)),
    receive
        {Ref, M, Meta} -> collect_until(Ref, Deadline, [{M, Meta} | Acc])
    after Wait -> lists:reverse(Acc)
    end.
