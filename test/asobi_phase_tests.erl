-module(asobi_phase_tests).
-include_lib("eunit/include/eunit.hrl").

%% -------------------------------------------------------------------
%% Basic phase progression
%% -------------------------------------------------------------------

simple_phases_test() ->
    Phases = [
        #{name => ~"warmup", duration => 1000},
        #{name => ~"active", duration => 2000},
        #{name => ~"results", duration => 500}
    ],
    {_InitEvents, PS} = asobi_phase:init(Phases),
    ?assertEqual(~"warmup", asobi_phase:current(PS)),

    {Events1, PS1} = asobi_phase:tick(1100, PS),
    ?assertMatch([{phase_ended, ~"warmup"}, {phase_started, ~"active"}], Events1),
    ?assertEqual(~"active", asobi_phase:current(PS1)),

    {[], PS2} = asobi_phase:tick(1000, PS1),
    ?assertEqual(~"active", asobi_phase:current(PS2)),

    {Events2, PS3} = asobi_phase:tick(1100, PS2),
    ?assertMatch([{phase_ended, ~"active"}, {phase_started, ~"results"}], Events2),
    ?assertEqual(~"results", asobi_phase:current(PS3)),

    {Events3, PS4} = asobi_phase:tick(600, PS3),
    ?assertMatch([{phase_ended, ~"results"}, {all_phases_complete}], Events3),
    ?assertEqual(undefined, asobi_phase:current(PS4)).

%% -------------------------------------------------------------------
%% Conditional start
%% -------------------------------------------------------------------

conditional_player_start_test() ->
    Phases = [
        #{name => ~"gathering", start => {players, 5}, duration => 1000},
        #{name => ~"active", duration => 2000}
    ],
    {_InitEvents, PS} = asobi_phase:init(Phases),
    Info = asobi_phase:info(PS),
    ?assertEqual(waiting, maps:get(status, Info)),

    {[], PS1} = asobi_phase:tick(500, PS),
    ?assertEqual(waiting, maps:get(status, asobi_phase:info(PS1))),

    {[], PS2} = asobi_phase:notify({player_joined, 3}, PS1),
    ?assertEqual(waiting, maps:get(status, asobi_phase:info(PS2))),

    {Events, PS3} = asobi_phase:notify({player_joined, 5}, PS2),
    ?assertMatch([{phase_started, ~"gathering"}], Events),
    ?assertEqual(active, maps:get(status, asobi_phase:info(PS3))),
    ?assertEqual(~"gathering", asobi_phase:current(PS3)).

conditional_timer_fallback_test() ->
    Phases = [
        #{name => ~"waiting", start => {timer, 2000}, duration => 1000}
    ],
    {_InitEvents, PS} = asobi_phase:init(Phases),
    {[], PS1} = asobi_phase:tick(1000, PS),
    ?assertEqual(waiting, maps:get(status, asobi_phase:info(PS1))),

    {Events, PS2} = asobi_phase:tick(1500, PS1),
    ?assertMatch([{phase_started, ~"waiting"}], Events),
    ?assertEqual(~"waiting", asobi_phase:current(PS2)).

%% -------------------------------------------------------------------
%% Infinity duration
%% -------------------------------------------------------------------

infinity_duration_test() ->
    Phases = [
        #{name => ~"persistent", duration => infinity}
    ],
    {_InitEvents, PS} = asobi_phase:init(Phases),
    ?assertEqual(infinity, asobi_phase:remaining(PS)),

    {[], PS1} = asobi_phase:tick(999999, PS),
    ?assertEqual(~"persistent", asobi_phase:current(PS1)),
    ?assertEqual(infinity, asobi_phase:remaining(PS1)).

%% -------------------------------------------------------------------
%% Phase with timers
%% -------------------------------------------------------------------

phase_with_cycle_timer_test() ->
    Phases = [
        #{
            name => ~"active",
            duration => 10000,
            timers => [
                #{
                    type => cycle,
                    id => ~"daynight",
                    phases => [
                        #{name => ~"day", duration => 100},
                        #{name => ~"night", duration => 200}
                    ],
                    repeat => true
                }
            ]
        }
    ],
    {_InitEvents, PS} = asobi_phase:init(Phases),
    TimersInfo = asobi_phase:timers_info(PS),
    ?assertMatch(#{~"daynight" := #{type := cycle}}, TimersInfo),

    {Events, _PS1} = asobi_phase:tick(110, PS),
    ?assertMatch([{phase_changed, ~"daynight", ~"night"}], Events).

%% -------------------------------------------------------------------
%% Pause / Resume
%% -------------------------------------------------------------------

pause_resume_test() ->
    Phases = [#{name => ~"active", duration => 1000}],
    {_InitEvents, PS} = asobi_phase:init(Phases),
    PS1 = asobi_phase:pause(PS),

    {[], PS2} = asobi_phase:tick(500, PS1),
    ?assertEqual(1000, asobi_phase:remaining(PS2)),

    PS3 = asobi_phase:resume(PS2),
    {[], PS4} = asobi_phase:tick(500, PS3),
    ?assertEqual(500, asobi_phase:remaining(PS4)).

%% -------------------------------------------------------------------
%% Config access
%% -------------------------------------------------------------------

config_test() ->
    Phases = [
        #{
            name => ~"phase1",
            duration => 1000,
            config => #{pvp => false, safe_zones => true}
        },
        #{
            name => ~"phase2",
            duration => 1000,
            config => #{pvp => true}
        }
    ],
    {_InitEvents, PS} = asobi_phase:init(Phases),
    ?assertEqual(#{pvp => false, safe_zones => true}, asobi_phase:config(PS)),

    {_, PS1} = asobi_phase:tick(1100, PS),
    ?assertEqual(#{pvp => true}, asobi_phase:config(PS1)).

%% -------------------------------------------------------------------
%% Empty phases
%% -------------------------------------------------------------------

empty_phases_test() ->
    {_InitEvents, PS} = asobi_phase:init([]),
    ?assertEqual(undefined, asobi_phase:current(PS)),
    ?assertEqual(0, asobi_phase:remaining(PS)),
    {[], PS1} = asobi_phase:tick(1000, PS),
    ?assertEqual(undefined, asobi_phase:current(PS1)).

%% -------------------------------------------------------------------
%% Event-triggered phase start
%% -------------------------------------------------------------------

event_start_test() ->
    Phases = [
        #{name => ~"idle", start => {event, game_ready}, duration => 1000}
    ],
    {_InitEvents, PS} = asobi_phase:init(Phases),
    ?assertEqual(waiting, maps:get(status, asobi_phase:info(PS))),

    {[], PS1} = asobi_phase:notify({player_joined, 3}, PS),
    ?assertEqual(waiting, maps:get(status, asobi_phase:info(PS1))),

    {Events, PS2} = asobi_phase:notify({event, game_ready}, PS1),
    ?assertMatch([{phase_started, ~"idle"}], Events),
    ?assertEqual(active, maps:get(status, asobi_phase:info(PS2))).

%% -------------------------------------------------------------------
%% Info output
%% -------------------------------------------------------------------

info_waiting_test() ->
    Phases = [#{name => ~"w", start => {players, 5}, duration => 1000}],
    {_InitEvents, PS} = asobi_phase:init(Phases),
    Info = asobi_phase:info(PS),
    ?assertEqual(waiting, maps:get(status, Info)),
    ?assertEqual(~"w", maps:get(phase, Info)).

info_active_test() ->
    Phases = [#{name => ~"a", duration => 5000, config => #{x => 1}}],
    {_InitEvents, PS} = asobi_phase:init(Phases),
    Info = asobi_phase:info(PS),
    ?assertEqual(active, maps:get(status, Info)),
    ?assertEqual(~"a", maps:get(phase, Info)),
    ?assertEqual(#{x => 1}, maps:get(config, Info)).

info_complete_test() ->
    {_InitEvents, PS} = asobi_phase:init([]),
    Info = asobi_phase:info(PS),
    ?assertEqual(complete, maps:get(status, Info)).
