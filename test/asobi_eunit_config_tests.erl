-module(asobi_eunit_config_tests).
-include_lib("eunit/include/eunit.hrl").

%% asobi #279: without a scale factor, EUnit's 5s default per-test timeout kills
%% the enclosing group's runner on a slow CI machine, cancelling every test after
%% it and turning a green suite red at random.
scale_timeouts_configured_test() ->
    {ok, Terms} = file:consult("rebar.config"),
    {profiles, Profiles} = lists:keyfind(profiles, 1, Terms),
    {test, TestProfile} = lists:keyfind(test, 1, Profiles),
    {eunit_opts, EunitOpts} = lists:keyfind(eunit_opts, 1, TestProfile),
    ?assert(proplists:get_value(scale_timeouts, EunitOpts, 1) >= 2).
