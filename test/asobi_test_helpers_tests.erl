-module(asobi_test_helpers_tests).

-include_lib("eunit/include/eunit.hrl").

%% Shape only. The property that actually matters for asobi#357 - a fixture id
%% no *other run* will produce - cannot be asserted from inside one run, and a
%% test that spawns peer nodes to show erlang:unique_integer/1 colliding is
%% flaky in both directions (fresh instances usually, not always, hand out the
%% same counter values). The regression evidence is running a suite twice
%% against the same database.
unique_id_keeps_the_prefix_test() ->
    ?assertMatch(<<"txn_", _/binary>>, asobi_test_helpers:unique_id(~"txn")).

unique_id_draws_from_a_large_space_test() ->
    Ids = [asobi_test_helpers:unique_id(~"x") || _ <- lists:seq(1, 1000)],
    ?assertEqual(1000, length(lists:usort(Ids))),
    %% 8 random bytes, hex-encoded: the suffix has to be wide enough that two
    %% runs colliding is not a thing that happens.
    [Suffix] = tl(binary:split(hd(Ids), ~"_")),
    ?assertEqual(16, byte_size(Suffix)).
