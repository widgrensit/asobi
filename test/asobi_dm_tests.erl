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

%% F-11: DM content must be capped at 2000 bytes; oversized payloads must
%% return {error, content_too_large} rather than being silently relayed.
send_rejects_oversized_content_test() ->
    Big = binary:copy(<<"x">>, 2001),
    ?assertEqual(
        {error, content_too_large},
        asobi_dm:send(~"alice", ~"bob", Big)
    ).

send_rejects_empty_content_test() ->
    ?assertEqual(
        {error, content_empty},
        asobi_dm:send(~"alice", ~"bob", <<>>)
    ).

%% Note: non-binary content is rejected by the eqWAlizer-checked
%% function head; we don't dispatch through there in tests because
%% eqWAlizer would refuse the bad call. The runtime guard remains as
%% defense-in-depth and is exercised via the HTTP/WS layer where
%% input types are dynamic.
