-module(asobi_entity_timer_tests).
-include_lib("eunit/include/eunit.hrl").

new_empty_test() ->
    S = asobi_entity_timer:new(),
    ?assertEqual(0, asobi_entity_timer:active_count(S)),
    ?assertEqual([], asobi_entity_timer:get_timers(~"e1", S)).

start_and_query_test() ->
    S0 = asobi_entity_timer:new(),
    S1 = asobi_entity_timer:start_timer(
        #{
            entity_id => ~"furnace_1",
            timer_id => ~"smelt",
            duration => 5000,
            on_complete => {craft_complete, ~"iron_ingot", 10},
            category => crafting
        },
        S0
    ),
    ?assertEqual(1, asobi_entity_timer:active_count(S1)),
    Timers = asobi_entity_timer:get_timers(~"furnace_1", S1),
    ?assertEqual(1, length(Timers)).

tick_no_expire_test() ->
    S0 = asobi_entity_timer:new(),
    S1 = asobi_entity_timer:start_timer(
        #{
            entity_id => ~"e1",
            timer_id => ~"t1",
            duration => 10000,
            on_complete => done
        },
        S0
    ),
    Now = erlang:system_time(millisecond) + 5000,
    {Events, S2} = asobi_entity_timer:tick(Now, S1),
    ?assertEqual([], Events),
    ?assertEqual(1, asobi_entity_timer:active_count(S2)).

tick_expire_test() ->
    S0 = asobi_entity_timer:new(),
    S1 = asobi_entity_timer:start_timer(
        #{
            entity_id => ~"e1",
            timer_id => ~"t1",
            duration => 100,
            on_complete => {done, ~"item_a"}
        },
        S0
    ),
    Now = erlang:system_time(millisecond) + 200,
    {Events, S2} = asobi_entity_timer:tick(Now, S1),
    ?assertMatch([{entity_timer_expired, ~"e1", ~"t1", {done, ~"item_a"}}], Events),
    ?assertEqual(0, asobi_entity_timer:active_count(S2)).

cancel_timer_test() ->
    S0 = asobi_entity_timer:new(),
    S1 = asobi_entity_timer:start_timer(
        #{
            entity_id => ~"e1",
            timer_id => ~"t1",
            duration => 10000,
            on_complete => done
        },
        S0
    ),
    S2 = asobi_entity_timer:cancel_timer(~"e1", ~"t1", S1),
    ?assertEqual(0, asobi_entity_timer:active_count(S2)).

multiple_entities_test() ->
    S0 = asobi_entity_timer:new(),
    S1 = asobi_entity_timer:start_timer(
        #{
            entity_id => ~"e1",
            timer_id => ~"t1",
            duration => 100,
            on_complete => a
        },
        S0
    ),
    S2 = asobi_entity_timer:start_timer(
        #{
            entity_id => ~"e2",
            timer_id => ~"t1",
            duration => 200,
            on_complete => b
        },
        S1
    ),
    S3 = asobi_entity_timer:start_timer(
        #{
            entity_id => ~"e1",
            timer_id => ~"t2",
            duration => 300,
            on_complete => c
        },
        S2
    ),
    ?assertEqual(3, asobi_entity_timer:active_count(S3)),

    Now = erlang:system_time(millisecond) + 150,
    {Events, S4} = asobi_entity_timer:tick(Now, S3),
    ?assertEqual(1, length(Events)),
    ?assertEqual(2, asobi_entity_timer:active_count(S4)).

info_test() ->
    S0 = asobi_entity_timer:new(),
    S1 = asobi_entity_timer:start_timer(
        #{
            entity_id => ~"e1",
            timer_id => ~"t1",
            duration => 100,
            on_complete => done
        },
        S0
    ),
    Info = asobi_entity_timer:info(S1),
    ?assertEqual(1, maps:get(active_timers, Info)).
