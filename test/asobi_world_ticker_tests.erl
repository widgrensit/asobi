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
    {foreach,
        fun() ->
            {ok, _} = application:ensure_all_started(telemetry),
            ok
        end,
        fun(_) -> ok end, [
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
            {"sample interval defaults to ~1s", fun sample_every_defaults_to_one_second/0},
            {"a busy zone is skipped, not queued", fun busy_zone_is_skipped/0},
            {"a skipped zone resumes once it replies", fun skipped_zone_resumes/0},
            {"a late reply frees the zone", fun late_reply_frees_zone/0},
            {"a fast zone keeps ticking past a slow one", fun fast_zone_unaffected_by_slow/0},
            {"pending drops zones that went away", fun pending_drops_departed_zones/0},
            {"skipping emits telemetry", fun skipped_emits_telemetry/0},
            {"a healthy world emits no skip events", fun healthy_world_emits_no_skips/0},
            {"post_tick never runs backwards", fun post_tick_is_monotonic/0},
            {"the world keeps posting while saturated", fun post_tick_survives_saturation/0},
            {"set_zones twice arms one timer", fun set_zones_twice_arms_one_timer/0},
            {"a demoted zone stays cold under a zone manager", fun manager_honours_cold_zones/0},
            {"a cold zone is skipped on an off-divisor tick", fun cold_zone_skipped/0},
            {"a reaped cold zone drops out of the cold set", fun cold_set_prunes_dead_zones/0}
        ]}.

%% widgrensit/asobi#543: with a zone manager the ticker used to overwrite its
%% own hot/cold split with "every active zone is hot", which made
%% cold_tick_divisor inert for every world running lazy zones.
manager_honours_cold_zones() ->
    Z1 = idle_proc(),
    Z2 = idle_proc(),
    Manager = fake_manager([Z1, Z2]),
    Pid = start_ticker(#{tick_rate => 20}),
    asobi_world_ticker:set_zone_manager(Pid, Manager, self()),
    asobi_world_ticker:demote_zone(Pid, Z1),
    timer:sleep(80),
    State = get_state_map(Pid),
    ?assertEqual([Z1], maps:get(cold_zones, State)),
    ?assertEqual([Z2], maps:get(hot_zones, State)).

cold_zone_skipped() ->
    Z1 = counting_proc(),
    Z2 = counting_proc(),
    Manager = fake_manager([Z1, Z2]),
    Pid = start_ticker(#{tick_rate => 10, cold_tick_divisor => 100}),
    %% Each stand-in must retire its tick, or the ticker's saturation guard
    %% skips it from the second tick onwards and both counts stay at 1.
    Z1 ! {ticker, Pid},
    Z2 ! {ticker, Pid},
    asobi_world_ticker:set_zone_manager(Pid, Manager, self()),
    asobi_world_ticker:demote_zone(Pid, Z1),
    timer:sleep(150),
    Hot = tick_count(Z2),
    %% Exact rather than "fewer": with a divisor of 100 and at most ~15 world
    %% ticks in the window, the cold zone should not have been reached once.
    ?assertEqual(0, tick_count(Z1)),
    %% Deliberately loose: this box runs eunit modules in parallel, so a 10ms
    %% ticker's dispatch count over 150ms is not something to assert tightly.
    ?assert(Hot >= 3).

cold_set_prunes_dead_zones() ->
    Z1 = idle_proc(),
    Manager = fake_manager([Z1]),
    Pid = start_ticker(#{tick_rate => 20}),
    asobi_world_ticker:set_zone_manager(Pid, Manager, self()),
    asobi_world_ticker:demote_zone(Pid, Z1),
    timer:sleep(60),
    ?assertEqual([Z1], maps:get(cold_zones, get_state_map(Pid))),
    %% The manager stops listing it (the zone was reaped). Nothing sends
    %% remove_zone, so the cold set has to prune itself or it grows for the
    %% life of the world.
    set_manager_zones(Manager, []),
    timer:sleep(80),
    ?assertEqual([], maps:get(cold_zones, get_state_map(Pid))).

idle_proc() ->
    spawn(fun() ->
        receive
            stop -> ok
        end
    end).

%% Answers get_active_zones and counts nothing else; the zone list is
%% swappable so a test can simulate a reap.
fake_manager(Zones) ->
    spawn(fun() -> manager_loop(Zones) end).

manager_loop(Zones) ->
    receive
        {'$gen_call', {From, Tag}, get_active_zones} ->
            From ! {Tag, Zones},
            manager_loop(Zones);
        {set_zones, New} ->
            manager_loop(New);
        stop ->
            ok
    end.

set_manager_zones(Manager, Zones) ->
    Manager ! {set_zones, Zones},
    ok.

%% A zone stand-in that counts the ticks it is sent.
counting_proc() ->
    spawn(fun() -> counting_loop(0, undefined) end).

counting_loop(N, Ticker) ->
    receive
        {ticker, Pid} ->
            counting_loop(N, Pid);
        {'$gen_cast', {tick, T}} ->
            case Ticker of
                undefined -> ok;
                _ -> asobi_world_ticker:tick_done(Ticker, self(), T)
            end,
            counting_loop(N + 1, Ticker);
        {count, From} ->
            From ! {count, N},
            counting_loop(N, Ticker);
        stop ->
            ok
    end.

tick_count(Pid) ->
    Pid ! {count, self()},
    receive
        {count, N} -> N
    after 1000 -> error(no_count)
    end.

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

%% --- #426: fan-out back-pressure ---
%%
%% Before this, the fan-out never consulted `pending`: a zone whose `zone_tick`
%% outran `tick_rate` was sent a tick every tick_rate ms regardless, so its
%% mailbox grew without bound until the node died. These drive the tick by hand
%% (`tick_rate` is parked at 60s so the ticker's own timer never fires inside a
%% test) and assert on what each zone actually received.

busy_zone_is_skipped() ->
    Pid = start_ticker(#{tick_rate => 60000}),
    Z = fake_zone(),
    asobi_world_ticker:set_zones(Pid, [Z], self()),
    drive_tick(Pid),
    ?assertEqual([1], zone_ticks(Z)),
    %% Z has not replied, so the second fan-out must not reach it.
    drive_tick(Pid),
    ?assertEqual([1], zone_ticks(Z)),
    ?assertEqual(2, asobi_world_ticker:get_tick(Pid)),
    ?assertEqual(#{Z => 1}, maps:get(pending, get_state_map(Pid))).

skipped_zone_resumes() ->
    Pid = start_ticker(#{tick_rate => 60000}),
    Z = fake_zone(),
    asobi_world_ticker:set_zones(Pid, [Z], self()),
    drive_tick(Pid),
    drive_tick(Pid),
    asobi_world_ticker:tick_done(Pid, Z, 1),
    drive_tick(Pid),
    %% Tick 2 was dropped while Z was busy; tick 3 carries the same upkeep.
    ?assertEqual([1, 3], zone_ticks(Z)).

%% The reply that arrives after the ticker has moved on is the case the
%% obvious one-line version of this fix gets wrong: gating the `pending`
%% removal on the reply matching the ticker's current tick strands the zone in
%% `pending` and it is never ticked again. A ticker restart under a running
%% zone produces the extreme form - a reply for a tick this ticker never
%% dispatched.
late_reply_frees_zone() ->
    Pid = start_ticker(#{tick_rate => 60000}),
    Z = fake_zone(),
    asobi_world_ticker:set_zones(Pid, [Z], self()),
    drive_tick(Pid),
    drive_tick(Pid),
    drive_tick(Pid),
    asobi_world_ticker:tick_done(Pid, Z, 9999),
    ?assertEqual(#{}, maps:get(pending, get_state_map(Pid))),
    drive_tick(Pid),
    ?assertEqual([1, 4], zone_ticks(Z)).

fast_zone_unaffected_by_slow() ->
    Pid = start_ticker(#{tick_rate => 60000}),
    Slow = fake_zone(),
    Fast = fake_zone(),
    asobi_world_ticker:set_zones(Pid, [Slow, Fast], self()),
    drive_tick(Pid),
    asobi_world_ticker:tick_done(Pid, Fast, 1),
    drive_tick(Pid),
    asobi_world_ticker:tick_done(Pid, Fast, 2),
    drive_tick(Pid),
    ?assertEqual([1, 2, 3], zone_ticks(Fast)),
    ?assertEqual([1], zone_ticks(Slow)).

%% A zone that goes away while still pending must not hold its slot: nothing
%% will ever reply for it, and `pending` is consulted on every fan-out.
pending_drops_departed_zones() ->
    Pid = start_ticker(#{tick_rate => 60000}),
    Z1 = fake_zone(),
    Z2 = fake_zone(),
    asobi_world_ticker:set_zones(Pid, [Z1, Z2], self()),
    drive_tick(Pid),
    ?assertEqual([Z1, Z2], lists:sort(maps:keys(maps:get(pending, get_state_map(Pid))))),
    asobi_world_ticker:remove_zone(Pid, Z2),
    drive_tick(Pid),
    ?assertEqual([Z1], maps:keys(maps:get(pending, get_state_map(Pid)))).

skipped_emits_telemetry() ->
    Pid = start_ticker(#{tick_rate => 60000, world_id => ~"w-skip-1"}),
    Z = fake_zone(),
    Events = with_subscription([asobi, zone, tick_skipped], ~"w-skip-1", fun(Ref) ->
        asobi_world_ticker:set_zones(Pid, [Z], self()),
        drive_tick(Pid),
        drive_tick(Pid),
        collect_for(Ref, 50)
    end),
    ?assertMatch([{#{count := 1}, #{world_id := ~"w-skip-1"}}], Events).

healthy_world_emits_no_skips() ->
    Pid = start_ticker(#{tick_rate => 60000, world_id => ~"w-skip-2"}),
    Z = fake_zone(),
    Events = with_subscription([asobi, zone, tick_skipped], ~"w-skip-2", fun(Ref) ->
        asobi_world_ticker:set_zones(Pid, [Z], self()),
        drive_tick(Pid),
        asobi_world_ticker:tick_done(Pid, Z, 1),
        drive_tick(Pid),
        asobi_world_ticker:tick_done(Pid, Z, 2),
        collect_for(Ref, 50)
    end),
    ?assertEqual([], Events).

%% `post_tick` drives phase timers and reconnect deadlines in the world server,
%% so a tick completing out of order must not replay it backwards.
post_tick_is_monotonic() ->
    Pid = start_ticker(#{tick_rate => 60000}),
    Z = fake_zone(),
    asobi_world_ticker:set_zones(Pid, [Z], self()),
    flush_post_ticks(),
    drive_tick(Pid),
    asobi_world_ticker:tick_done(Pid, Z, 1),
    drive_tick(Pid),
    drive_tick(Pid),
    %% Tick 2's reply lands after tick 3 already posted, so it is dropped.
    asobi_world_ticker:tick_done(Pid, Z, 2),
    _ = get_state_map(Pid),
    ?assertEqual([1, 3], collect_post_ticks()).

%% Before #426 the world stopped posting entirely once any zone fell behind -
%% phases and reconnect deadlines froze, and the sampled tick telemetry (which
%% only fires on a completed tick) went silent at the exact moment it mattered.
post_tick_survives_saturation() ->
    Pid = start_ticker(#{tick_rate => 60000}),
    Z = fake_zone(),
    asobi_world_ticker:set_zones(Pid, [Z], self()),
    flush_post_ticks(),
    lists:foreach(fun(_) -> drive_tick(Pid) end, lists:seq(1, 5)),
    ?assertEqual([2, 3, 4, 5], collect_post_ticks()).

%% Both entry points armed a timer unconditionally, so a world that called
%% either one twice ran two tick loops against one ticker - double the fan-out
%% rate into the same zones.
set_zones_twice_arms_one_timer() ->
    Pid = start_ticker(#{tick_rate => 20}),
    asobi_world_ticker:set_zones(Pid, [], self()),
    asobi_world_ticker:set_zones(Pid, [], self()),
    timer:sleep(300),
    Ticks = asobi_world_ticker:get_tick(Pid),
    ?assert(Ticks >= 5),
    ?assert(Ticks =< 22).

%% Drive one fan-out and wait for the ticker to finish handling it. The
%% `sys:get_state/1` call is the barrier: it cannot be served until the `tick`
%% ahead of it in the mailbox has been processed.
drive_tick(Pid) ->
    Pid ! tick,
    _ = get_state_map(Pid),
    ok.

fake_zone() ->
    spawn(fun() -> fake_zone_loop([]) end).

fake_zone_loop(Ticks) ->
    receive
        {'$gen_cast', {tick, N}} ->
            fake_zone_loop([N | Ticks]);
        {ticks, From} ->
            From ! {ticks, self(), lists:reverse(Ticks)},
            fake_zone_loop(Ticks)
    end.

zone_ticks(Zone) ->
    Zone ! {ticks, self()},
    receive
        {ticks, Zone, Ticks} -> Ticks
    after 1000 -> error(zone_did_not_answer)
    end.

flush_post_ticks() ->
    receive
        {'$gen_cast', {post_tick, _}} -> flush_post_ticks()
    after 0 -> ok
    end.

collect_post_ticks() ->
    lists:reverse(collect_post_ticks([])).

collect_post_ticks(Acc) ->
    receive
        {'$gen_cast', {post_tick, N}} -> collect_post_ticks([N | Acc])
    after 0 -> Acc
    end.

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
