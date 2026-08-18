-module(asobi_zone_wire_refusal_tests).
-include_lib("eunit/include/eunit.hrl").

%% The throttle on the binary-wire refusal warning, and the attribution the line
%% carries. A zone holding one entity the encoder cannot take refuses every frame,
%% so this is what decides between a log an operator can read and five lines a
%% second for the life of the zone.

-define(DELTAS, [
    {added, ~"e1", #{~"x" => 1.0, ~"y" => 2.0}},
    {updated, ~"e2", #{~"x" => 1.0, ~"y" => 2.0, ~"hp" => 3}}
]).

-define(STATE(Log), #{wire_log => Log}).

first_refusal_logs_immediately_test() ->
    State = asobi_zone:log_refusal(
        dict_too_large,
        ~"refused",
        {0, 0},
        1,
        ?DELTAS,
        ?STATE(#{
            logged_at => undefined, suppressed => 0
        })
    ),
    #{wire_log := Log} = State,
    ?assertEqual(0, maps:get(suppressed, Log)),
    ?assertNotEqual(undefined, maps:get(logged_at, Log)).

%% The number an operator actually needs is how much the quiet minute hid.
subsequent_refusals_count_rather_than_log_test() ->
    Now = erlang:monotonic_time(millisecond),
    S1 = asobi_zone:log_refusal(
        dict_too_large, ~"refused", {0, 0}, 2, ?DELTAS, ?STATE(#{logged_at => Now, suppressed => 0})
    ),
    S2 = asobi_zone:log_refusal(dict_too_large, ~"refused", {0, 0}, 3, ?DELTAS, S1),
    #{wire_log := Log} = S2,
    ?assertEqual(2, maps:get(suppressed, Log)),
    ?assertEqual(Now, maps:get(logged_at, Log)).

window_expiry_logs_and_resets_the_counter_test() ->
    Stale = erlang:monotonic_time(millisecond) - 61_000,
    State = asobi_zone:log_refusal(
        dict_too_large,
        ~"refused",
        {0, 0},
        4,
        ?DELTAS,
        ?STATE(#{
            logged_at => Stale, suppressed => 41
        })
    ),
    #{wire_log := Log} = State,
    ?assertEqual(0, maps:get(suppressed, Log)),
    ?assert(maps:get(logged_at, Log) > Stale).

%% Monotonic rather than wall-clock: an NTP step backwards must not buy a zone a
%% silent window the size of the correction.
a_backward_clock_does_not_suppress_the_line_test() ->
    Future = erlang:monotonic_time(millisecond) + 3_600_000,
    State = asobi_zone:log_refusal(
        dict_too_large,
        ~"refused",
        {0, 0},
        5,
        ?DELTAS,
        ?STATE(#{
            logged_at => Future, suppressed => 0
        })
    ),
    #{wire_log := Log} = State,
    ?assertEqual(1, maps:get(suppressed, Log)).

%% The two numbers the line is worth reading for: the dictionary is capped at 32
%% names, and one entity is usually the reason.
attribution_names_the_widest_entity_test() ->
    ?assertEqual(3, asobi_zone:distinct_field_names(?DELTAS)),
    ?assertEqual(#{entity => ~"e2", fields => 3}, asobi_zone:widest_entity(?DELTAS)),
    %% A frame of removals has no fields and nothing to blame.
    ?assertEqual(0, asobi_zone:distinct_field_names([{removed, ~"e1"}])),
    ?assertEqual(
        #{entity => undefined, fields => 0}, asobi_zone:widest_entity([{removed, ~"e1"}])
    ).
