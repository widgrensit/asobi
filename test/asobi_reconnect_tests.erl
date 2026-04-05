-module(asobi_reconnect_tests).
-include_lib("eunit/include/eunit.hrl").

default_policy() ->
    #{
        grace_period => 5000,
        during_grace => idle,
        on_reconnect => resume,
        on_expire => remove,
        pause_match => false,
        max_offline_total => infinity
    }.

disconnect_starts_grace_test() ->
    S = asobi_reconnect:new(default_policy()),
    Now = erlang:system_time(millisecond),
    {Events, S1} = asobi_reconnect:disconnect(~"p1", Now, S),
    ?assertMatch([{grace_started, ~"p1"}], Events),
    ?assert(asobi_reconnect:is_disconnected(~"p1", S1)).

reconnect_before_expire_test() ->
    S = asobi_reconnect:new(default_policy()),
    Now = erlang:system_time(millisecond),
    {_, S1} = asobi_reconnect:disconnect(~"p1", Now, S),
    {Events, S2} = asobi_reconnect:reconnect(~"p1", S1),
    ?assertMatch([{player_reconnected, ~"p1", resume}], Events),
    ?assertNot(asobi_reconnect:is_disconnected(~"p1", S2)).

grace_expires_test() ->
    S = asobi_reconnect:new(default_policy()),
    Now = erlang:system_time(millisecond),
    {_, S1} = asobi_reconnect:disconnect(~"p1", Now, S),
    {Events, S2} = asobi_reconnect:tick(6000, S1),
    ?assertMatch([{grace_expired, ~"p1", remove}], Events),
    ?assertNot(asobi_reconnect:is_disconnected(~"p1", S2)).

grace_not_expired_yet_test() ->
    S = asobi_reconnect:new(default_policy()),
    Now = erlang:system_time(millisecond),
    {_, S1} = asobi_reconnect:disconnect(~"p1", Now, S),
    {Events, S2} = asobi_reconnect:tick(3000, S1),
    ?assertEqual([], Events),
    ?assert(asobi_reconnect:is_disconnected(~"p1", S2)).

max_offline_total_test() ->
    Policy = (default_policy())#{grace_period => 10000, max_offline_total => 8000},
    S = asobi_reconnect:new(Policy),
    Now = erlang:system_time(millisecond),
    {_, S1} = asobi_reconnect:disconnect(~"p1", Now, S),
    {[], S2} = asobi_reconnect:tick(5000, S1),
    {_, S3} = asobi_reconnect:reconnect(~"p1", S2),
    {_, S4} = asobi_reconnect:disconnect(~"p1", Now + 10000, S3),
    {Events, _S5} = asobi_reconnect:tick(4000, S4),
    ?assertMatch([{grace_expired, ~"p1", remove}], Events).

multiple_disconnects_test() ->
    S = asobi_reconnect:new(default_policy()),
    Now = erlang:system_time(millisecond),
    {_, S1} = asobi_reconnect:disconnect(~"p1", Now, S),
    {_, S2} = asobi_reconnect:disconnect(~"p2", Now, S1),
    ?assertEqual([~"p1", ~"p2"], lists:sort(asobi_reconnect:disconnected_players(S2))).

reconnect_unknown_player_test() ->
    S = asobi_reconnect:new(default_policy()),
    {Events, _} = asobi_reconnect:reconnect(~"nobody", S),
    ?assertEqual([], Events).

forfeit_policy_test() ->
    Policy = (default_policy())#{on_expire => forfeit},
    S = asobi_reconnect:new(Policy),
    Now = erlang:system_time(millisecond),
    {_, S1} = asobi_reconnect:disconnect(~"p1", Now, S),
    {Events, _} = asobi_reconnect:tick(6000, S1),
    ?assertMatch([{grace_expired, ~"p1", forfeit}], Events).

info_test() ->
    S = asobi_reconnect:new(default_policy()),
    Now = erlang:system_time(millisecond),
    {_, S1} = asobi_reconnect:disconnect(~"p1", Now, S),
    Info = asobi_reconnect:info(S1),
    ?assertEqual(1, maps:get(disconnected_count, Info)).
