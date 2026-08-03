-module(asobi_match_record_tests).
-include_lib("eunit/include/eunit.hrl").
-include_lib("kura/include/kura.hrl").

%% asobi#329: the match servers keep their clocks in
%% erlang:system_time(millisecond), and feeding those integers straight into
%% the utc_datetime columns made kura_changeset:cast/4 invalid - so every
%% finished match failed to persist, silently.

to_timestamp_produces_a_castable_datetime_test() ->
    Millis = 1785791629064,
    Datetime = asobi_match_record:to_timestamp(Millis),
    ?assertEqual({{2026, 8, 3}, {21, 13, 49}}, Datetime),
    CS = kura_changeset:cast(
        asobi_match_record,
        #{},
        #{status => ~"finished", started_at => Datetime, finished_at => Datetime},
        [status, started_at, finished_at]
    ),
    ?assertMatch(#kura_changeset{valid = true, errors = []}, CS).

millisecond_integers_are_not_castable_test() ->
    CS = kura_changeset:cast(
        asobi_match_record,
        #{},
        #{status => ~"finished", finished_at => 1785791629064},
        [status, finished_at]
    ),
    ?assertMatch(#kura_changeset{valid = false, errors = [{finished_at, _} | _]}, CS).

to_timestamp_passes_undefined_through_test() ->
    ?assertEqual(undefined, asobi_match_record:to_timestamp(undefined)).
