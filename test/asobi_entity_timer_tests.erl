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

serialise_round_trip_test() ->
    S0 = asobi_entity_timer:new(),
    S1 = asobi_entity_timer:start_timer(
        #{
            entity_id => ~"furnace_1",
            timer_id => ~"smelt",
            duration => 5000,
            owner => ~"player_1",
            on_complete => #{~"type" => ~"craft", ~"item" => ~"iron_ingot"},
            category => crafting,
            pause_when_offline => true
        },
        S0
    ),
    Restored = round_trip(S1),
    ?assertEqual(1, asobi_entity_timer:active_count(Restored)),
    [Timer] = asobi_entity_timer:get_timers(~"furnace_1", Restored),
    ?assertEqual(~"smelt", maps:get(timer_id, Timer)),
    ?assertEqual(~"player_1", maps:get(owner, Timer)),
    ?assertEqual(crafting, maps:get(category, Timer)),
    ?assertEqual(true, maps:get(pause_when_offline, Timer)),
    ?assertEqual(#{~"type" => ~"craft", ~"item" => ~"iron_ingot"}, maps:get(on_complete, Timer)).

serialise_undefined_owner_test() ->
    S0 = asobi_entity_timer:new(),
    S1 = asobi_entity_timer:start_timer(
        #{entity_id => ~"e1", timer_id => ~"t1", duration => 5000, on_complete => ~"x"},
        S0
    ),
    [Timer] = asobi_entity_timer:get_timers(~"e1", round_trip(S1)),
    ?assertEqual(undefined, maps:get(owner, Timer)).

deserialise_legacy_count_is_empty_test() ->
    %% Pre-persistence snapshots stored #{active_timers => N}; deserialise must
    %% treat that (no "timers" key) as empty rather than crash.
    Restored = asobi_entity_timer:deserialise(#{~"active_timers" => 3}),
    ?assertEqual(0, asobi_entity_timer:active_count(Restored)).

serialise_preserves_expiry_test() ->
    %% end_at is absolute, so a timer that lapsed during downtime fires on the
    %% first tick after restore.
    S0 = asobi_entity_timer:new(),
    S1 = asobi_entity_timer:start_timer(
        #{entity_id => ~"e1", timer_id => ~"t1", duration => 1, on_complete => ~"ping"},
        S0
    ),
    Restored = round_trip(S1),
    {Events, _} = asobi_entity_timer:tick(erlang:system_time(millisecond) + 1000, Restored),
    ?assertMatch([{entity_timer_expired, ~"e1", ~"t1", ~"ping"}], Events).

serialise_tuple_on_complete_is_json_safe_test() ->
    %% A tuple on_complete cannot survive jsonb. serialise must drop it to null
    %% rather than emit a term json:encode/1 rejects, which would crash the
    %% snapshot write and take down the whole flush batch.
    S0 = asobi_entity_timer:new(),
    S1 = asobi_entity_timer:start_timer(
        #{
            entity_id => ~"furnace_1",
            timer_id => ~"smelt",
            duration => 5000,
            on_complete => {craft_complete, ~"iron_ingot", 10}
        },
        S0
    ),
    Serialised = asobi_entity_timer:serialise(S1),
    ?assertMatch(Bin when is_binary(Bin), iolist_to_binary(json:encode(Serialised))),
    [Timer] = asobi_entity_timer:get_timers(~"furnace_1", round_trip(S1)),
    ?assertEqual(null, maps:get(on_complete, Timer)).

deserialise_malformed_entry_is_skipped_test() ->
    %% A truncated/corrupt entry (no end_at) must be skipped, not abort the whole
    %% zone's restore.
    Snapshot = #{
        ~"timers" => #{
            ~"furnace_1" => #{
                ~"good" => #{
                    ~"timer_id" => ~"good",
                    ~"entity_id" => ~"furnace_1",
                    ~"end_at" => erlang:system_time(millisecond) + 5000
                },
                ~"bad" => #{~"timer_id" => ~"bad", ~"entity_id" => ~"furnace_1"}
            }
        }
    },
    Restored = asobi_entity_timer:deserialise(Snapshot),
    ?assertEqual(1, asobi_entity_timer:active_count(Restored)),
    [Timer] = asobi_entity_timer:get_timers(~"furnace_1", Restored),
    ?assertEqual(~"good", maps:get(timer_id, Timer)).

round_trip(State) ->
    asobi_entity_timer:deserialise(
        json:decode(iolist_to_binary(json:encode(asobi_entity_timer:serialise(State))))
    ).
