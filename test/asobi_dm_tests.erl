-module(asobi_dm_tests).
-include_lib("eunit/include/eunit.hrl").

channel_id_deterministic_test() ->
    Id1 = asobi_dm:channel_id(~"alice", ~"bob"),
    Id2 = asobi_dm:channel_id(~"bob", ~"alice"),
    ?assertEqual(Id1, Id2).

channel_id_sorted_test() ->
    Id = asobi_dm:channel_id(~"zzz", ~"aaa"),
    ?assertEqual(~"dm:aaa:zzz", Id).

channel_id_same_order_test() ->
    Id = asobi_dm:channel_id(~"aaa", ~"zzz"),
    ?assertEqual(~"dm:aaa:zzz", Id).

channel_id_prefix_test() ->
    Id = asobi_dm:channel_id(~"p1", ~"p2"),
    ?assertMatch(<<"dm:", _/binary>>, Id).
