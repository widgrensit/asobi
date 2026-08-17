-module(asobi_guest_env_tests).

-include_lib("eunit/include/eunit.hrl").

-define(VAR, "ASOBI_GUEST_REAP_AFTER").

%% Every case here is about one question: can this module ever cause an
%% erasure nobody asked for? A wrong value must reach "keep everyone", never a
%% guessed default, because the reaper it feeds deletes accounts permanently
%% and writes no audit row.
%%
%% Moved here from asobi_engine along with the module. It lived in the private
%% wrapper, where a self-hoster running a release - the exact population that
%% cannot write a sys.config - could not use the mechanism at all.

retention_test_() ->
    {foreach, fun setup/0, fun cleanup/1, [
        fun a_positive_integer_is_applied/0,
        fun an_absent_variable_reaps_nothing/0,
        fun zero_reaps_nothing/0,
        fun a_negative_value_reaps_nothing/0,
        fun a_non_integer_reaps_nothing/0,
        fun an_empty_value_reaps_nothing/0,
        fun surrounding_whitespace_is_tolerated/0,
        fun turning_the_policy_off_clears_an_earlier_value/0
    ]}.

setup() ->
    Previous = application:get_env(asobi, guest_reap_after),
    os:unsetenv(?VAR),
    application:unset_env(asobi, guest_reap_after),
    Previous.

cleanup(Previous) ->
    os:unsetenv(?VAR),
    case Previous of
        {ok, Value} -> application:set_env(asobi, guest_reap_after, Value);
        undefined -> application:unset_env(asobi, guest_reap_after)
    end.

a_positive_integer_is_applied() ->
    os:putenv(?VAR, "2592000"),
    ok = asobi_guest_env:apply(),
    ?assertEqual({ok, 2592000}, application:get_env(asobi, guest_reap_after)).

%% The state every environment provisioned before this shipped is in, and the
%% state a self-hoster who never sets it is in. Both must keep their guests.
an_absent_variable_reaps_nothing() ->
    ok = asobi_guest_env:apply(),
    ?assertEqual(undefined, application:get_env(asobi, guest_reap_after)).

%% The explicit "off" the provisioner sends. It travels as a number so no
%% substitution can turn an empty string into something else on the way.
zero_reaps_nothing() ->
    os:putenv(?VAR, "0"),
    ok = asobi_guest_env:apply(),
    ?assertEqual(undefined, application:get_env(asobi, guest_reap_after)).

%% Not "reap everything older than a negative cutoff", which is every guest
%% that ever existed.
a_negative_value_reaps_nothing() ->
    os:putenv(?VAR, "-1"),
    ok = asobi_guest_env:apply(),
    ?assertEqual(undefined, application:get_env(asobi, guest_reap_after)).

a_non_integer_reaps_nothing() ->
    os:putenv(?VAR, "30 days"),
    ok = asobi_guest_env:apply(),
    ?assertEqual(undefined, application:get_env(asobi, guest_reap_after)),
    os:putenv(?VAR, "2592000.0"),
    ok = asobi_guest_env:apply(),
    ?assertEqual(undefined, application:get_env(asobi, guest_reap_after)).

an_empty_value_reaps_nothing() ->
    os:putenv(?VAR, ""),
    ok = asobi_guest_env:apply(),
    ?assertEqual(undefined, application:get_env(asobi, guest_reap_after)).

surrounding_whitespace_is_tolerated() ->
    os:putenv(?VAR, " 86400 "),
    ok = asobi_guest_env:apply(),
    ?assertEqual({ok, 86400}, application:get_env(asobi, guest_reap_after)).

%% A policy moved back to off must actually turn the sweeper off. Leaving the
%% previous number in place would keep deleting players after the studio said
%% stop, which is the worst failure this module has available to it.
turning_the_policy_off_clears_an_earlier_value() ->
    application:set_env(asobi, guest_reap_after, 604800),
    os:putenv(?VAR, "0"),
    ok = asobi_guest_env:apply(),
    ?assertEqual(undefined, application:get_env(asobi, guest_reap_after)).
