-module(asobi_chat_acl_tests).
-include_lib("eunit/include/eunit.hrl").

%% H1 (2026-05-19): chat ACL must reject third parties on DMs. World and
%% group channels require live processes / DB and are exercised via
%% asobi_chat_SUITE; here we cover the deterministic dm path that the WS
%% handler now gates `chat.join` and `chat.send` through.

dm_member_authorized_test() ->
    ?assert(asobi_chat_acl:authorized(~"dm:alice:bob", ~"alice")),
    ?assert(asobi_chat_acl:authorized(~"dm:alice:bob", ~"bob")).

dm_third_party_rejected_test() ->
    ?assertNot(asobi_chat_acl:authorized(~"dm:alice:bob", ~"eve")),
    ?assertNot(asobi_chat_acl:authorized(~"dm:alice:bob", ~"")).

dm_substring_does_not_grant_access_test() ->
    ?assertNot(asobi_chat_acl:authorized(~"dm:alice:bob", ~"ali")),
    ?assertNot(asobi_chat_acl:authorized(~"dm:alice:bob", ~"alicee")).
