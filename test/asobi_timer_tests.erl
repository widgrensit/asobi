-module(asobi_timer_tests).
-include_lib("eunit/include/eunit.hrl").

%% -------------------------------------------------------------------
%% Countdown
%% -------------------------------------------------------------------

countdown_expires_test() ->
    T = asobi_timer:countdown(#{id => ~"t1", duration => 1000}),
    ?assertNot(asobi_timer:is_expired(T)),
    ?assertEqual(1000, asobi_timer:remaining(T)),

    {Events1, T1} = asobi_timer:tick(500, T),
    ?assertEqual([], Events1),
    ?assertEqual(500, asobi_timer:remaining(T1)),

    {Events2, T2} = asobi_timer:tick(600, T1),
    ?assertEqual([{timer_expired, ~"t1"}], Events2),
    ?assert(asobi_timer:is_expired(T2)),
    ?assertEqual(0, asobi_timer:remaining(T2)).

countdown_warnings_test() ->
    T = asobi_timer:countdown(#{id => ~"t1", duration => 10000, warnings => [5000, 1000]}),
    {[], T1} = asobi_timer:tick(4000, T),
    {Events, T2} = asobi_timer:tick(2000, T1),
    ?assertEqual([{timer_warning, ~"t1", 5000}], Events),

    {Events2, _T3} = asobi_timer:tick(4000, T2),
    ?assertMatch([{timer_warning, ~"t1", 1000}, {timer_expired, ~"t1"}], Events2).

countdown_pause_test() ->
    T = asobi_timer:countdown(#{id => ~"t1", duration => 1000}),
    T1 = asobi_timer:pause(T),
    ?assert(asobi_timer:is_paused(T1)),
    {[], T2} = asobi_timer:tick(500, T1),
    ?assertEqual(1000, asobi_timer:remaining(T2)),

    T3 = asobi_timer:resume(T2),
    {[], T4} = asobi_timer:tick(500, T3),
    ?assertEqual(500, asobi_timer:remaining(T4)).

countdown_no_events_after_expired_test() ->
    T = asobi_timer:countdown(#{id => ~"t1", duration => 100}),
    {_, T1} = asobi_timer:tick(200, T),
    ?assert(asobi_timer:is_expired(T1)),
    {Events, _} = asobi_timer:tick(100, T1),
    ?assertEqual([], Events).

%% -------------------------------------------------------------------
%% Conditional
%% -------------------------------------------------------------------

conditional_waits_for_condition_test() ->
    T = asobi_timer:conditional(#{
        id => ~"t1",
        duration => 5000,
        start_condition => {players, 4},
        fallback_timeout => infinity
    }),
    ?assertNot(asobi_timer:is_started(T)),
    ?assertEqual(infinity, asobi_timer:remaining(T)),

    {[], T1} = asobi_timer:tick(1000, T),
    ?assertNot(asobi_timer:is_started(T1)),

    {Events, T2} = asobi_timer:notify(player_joined, 4, T1),
    ?assertEqual([{timer_started, ~"t1"}], Events),
    ?assert(asobi_timer:is_started(T2)),

    {[], T3} = asobi_timer:tick(4000, T2),
    ?assertEqual(1000, asobi_timer:remaining(T3)),

    {Events2, T4} = asobi_timer:tick(1500, T3),
    ?assertEqual([{timer_expired, ~"t1"}], Events2),
    ?assert(asobi_timer:is_expired(T4)).

conditional_fallback_timeout_test() ->
    T = asobi_timer:conditional(#{
        id => ~"t1",
        duration => 2000,
        start_condition => {players, 10},
        fallback_timeout => 3000
    }),
    {[], T1} = asobi_timer:tick(2000, T),
    ?assertNot(asobi_timer:is_started(T1)),

    {Events, T2} = asobi_timer:tick(1500, T1),
    ?assertEqual([{timer_started, ~"t1"}], Events),
    ?assert(asobi_timer:is_started(T2)).

conditional_event_trigger_test() ->
    T = asobi_timer:conditional(#{
        id => ~"t1",
        duration => 1000,
        start_condition => {event, bomb_planted},
        fallback_timeout => infinity
    }),
    {[], T1} = asobi_timer:notify(player_joined, 5, T),
    ?assertNot(asobi_timer:is_started(T1)),

    {Events, T2} = asobi_timer:notify(bomb_planted, undefined, T1),
    ?assertEqual([{timer_started, ~"t1"}], Events),
    ?assert(asobi_timer:is_started(T2)).

conditional_ignores_notify_after_started_test() ->
    T = asobi_timer:conditional(#{
        id => ~"t1",
        duration => 1000,
        start_condition => {players, 2},
        fallback_timeout => infinity
    }),
    {_, T1} = asobi_timer:notify(player_joined, 2, T),
    ?assert(asobi_timer:is_started(T1)),
    {Events, _} = asobi_timer:notify(player_joined, 5, T1),
    ?assertEqual([], Events).

%% -------------------------------------------------------------------
%% Cycle
%% -------------------------------------------------------------------

cycle_rotates_phases_test() ->
    T = asobi_timer:cycle(#{
        id => ~"daynight",
        phases => [
            #{name => ~"day", duration => 100},
            #{name => ~"night", duration => 200}
        ],
        repeat => true
    }),
    ?assertEqual(~"day", asobi_timer:current_phase(T)),

    {[], T1} = asobi_timer:tick(50, T),
    ?assertEqual(~"day", asobi_timer:current_phase(T1)),

    {Events, T2} = asobi_timer:tick(60, T1),
    ?assertEqual([{phase_changed, ~"daynight", ~"night"}], Events),
    ?assertEqual(~"night", asobi_timer:current_phase(T2)),

    {[], T3} = asobi_timer:tick(100, T2),
    ?assertEqual(~"night", asobi_timer:current_phase(T3)),

    {Events2, T4} = asobi_timer:tick(110, T3),
    ?assertEqual([{phase_changed, ~"daynight", ~"day"}], Events2),
    ?assertEqual(~"day", asobi_timer:current_phase(T4)).

cycle_no_repeat_expires_test() ->
    T = asobi_timer:cycle(#{
        id => ~"storm",
        phases => [
            #{name => ~"safe", duration => 100},
            #{name => ~"shrink", duration => 100}
        ],
        repeat => false
    }),
    {_, T1} = asobi_timer:tick(110, T),
    ?assertEqual(~"shrink", asobi_timer:current_phase(T1)),

    {Events, T2} = asobi_timer:tick(100, T1),
    ?assertMatch([{timer_expired, ~"storm"}], Events),
    ?assert(asobi_timer:is_expired(T2)).

cycle_pause_test() ->
    T = asobi_timer:cycle(#{
        id => ~"c1",
        phases => [#{name => ~"a", duration => 100}],
        repeat => true
    }),
    T1 = asobi_timer:pause(T),
    {[], T2} = asobi_timer:tick(200, T1),
    ?assertEqual(100, asobi_timer:remaining(T2)).

cycle_modifiers_in_info_test() ->
    T = asobi_timer:cycle(#{
        id => ~"c1",
        phases => [
            #{name => ~"day", duration => 100, modifiers => #{sun => true}},
            #{name => ~"night", duration => 100, modifiers => #{sun => false}}
        ],
        repeat => true
    }),
    Info = asobi_timer:info(T),
    ?assertEqual(#{sun => true}, maps:get(modifiers, Info)).

%% -------------------------------------------------------------------
%% Info
%% -------------------------------------------------------------------

info_countdown_test() ->
    T = asobi_timer:countdown(#{id => ~"t1", duration => 5000}),
    Info = asobi_timer:info(T),
    ?assertEqual(countdown, maps:get(type, Info)),
    ?assertEqual(~"t1", maps:get(id, Info)),
    ?assertEqual(5000, maps:get(remaining_ms, Info)),
    ?assertNot(maps:get(paused, Info)).

info_conditional_not_started_test() ->
    T = asobi_timer:conditional(#{
        id => ~"t1",
        duration => 1000,
        start_condition => {players, 5},
        fallback_timeout => infinity
    }),
    Info = asobi_timer:info(T),
    ?assertEqual(conditional, maps:get(type, Info)),
    ?assertNot(maps:get(started, Info)),
    ?assertEqual(infinity, maps:get(remaining_ms, Info)).

info_cycle_test() ->
    T = asobi_timer:cycle(#{
        id => ~"c1",
        phases => [#{name => ~"a", duration => 100}, #{name => ~"b", duration => 200}],
        repeat => true
    }),
    Info = asobi_timer:info(T),
    ?assertEqual(cycle, maps:get(type, Info)),
    ?assertEqual(~"a", maps:get(current_phase, Info)),
    ?assertEqual(2, maps:get(total_phases, Info)).

%% -------------------------------------------------------------------
%% Scheduled
%% -------------------------------------------------------------------

scheduled_window_open_close_test() ->
    {{Y, M, D}, _} = calendar:universal_time(),
    DayOfWeek = calendar:day_of_the_week({Y, M, D}),
    Key =
        case DayOfWeek >= 6 of
            true -> weekend;
            false -> weekday
        end,
    T = asobi_timer:scheduled(#{
        id => ~"pvp",
        schedule => {window, #{Key => {0, 0, 23, 59}}}
    }),
    ?assertNot(asobi_timer:is_expired(T)),
    {Events, T1} = asobi_timer:tick(0, T),
    ?assertMatch([{window_open, ~"pvp"}], Events),
    Info = asobi_timer:info(T1),
    ?assertEqual(scheduled, maps:get(type, Info)),
    ?assert(maps:get(window_active, Info)).

scheduled_window_closed_test() ->
    T = asobi_timer:scheduled(#{
        id => ~"pvp",
        schedule => {window, #{weekday => {25, 0, 25, 1}}}
    }),
    {Events, _} = asobi_timer:tick(0, T),
    ?assertEqual([], Events).

scheduled_once_test() ->
    Past = {{2020, 1, 1}, {0, 0, 0}},
    T = asobi_timer:scheduled(#{
        id => ~"event",
        schedule => {once, Past}
    }),
    {Events, T1} = asobi_timer:tick(0, T),
    ?assertMatch([{window_open, ~"event"}], Events),
    {[], _} = asobi_timer:tick(0, T1).

scheduled_info_test() ->
    T = asobi_timer:scheduled(#{
        id => ~"s1",
        schedule => {window, #{}}
    }),
    Info = asobi_timer:info(T),
    ?assertEqual(scheduled, maps:get(type, Info)),
    ?assertNot(maps:get(window_active, Info)).
