-module(rebar3_asobi_check_tests).

-include_lib("eunit/include/eunit.hrl").

%% The parse the plugin runs over a host's release sys_config to give the
%% build gate the same `nova_apps` the boot path sees. Pure, so it is pinned
%% without standing up a rebar state.

reads_bootstrap_and_nova_apps_test() ->
    Config = [
        {nova, [{bootstrap_application, my_game}]},
        {my_game, [{nova_apps, [nova_resilience]}]}
    ],
    ?assertEqual(
        {ok, my_game, [nova_resilience]},
        rebar3_asobi_check:co_mounted_from_config(Config)
    ).

no_bootstrap_application_is_none_test() ->
    ?assertEqual(
        none,
        rebar3_asobi_check:co_mounted_from_config([{my_game, [{nova_apps, [nova_resilience]}]}])
    ).

empty_nova_apps_is_none_test() ->
    Config = [
        {nova, [{bootstrap_application, my_game}]},
        {my_game, [{nova_apps, []}]}
    ],
    ?assertEqual(none, rebar3_asobi_check:co_mounted_from_config(Config)).

%% A project that simply declares no nova_apps reserves nothing extra, which
%% is the correct answer rather than a failure.
no_nova_apps_key_is_none_test() ->
    Config = [{nova, [{bootstrap_application, my_game}]}, {my_game, []}],
    ?assertEqual(none, rebar3_asobi_check:co_mounted_from_config(Config)).
