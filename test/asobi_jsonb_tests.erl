-module(asobi_jsonb_tests).

-include_lib("eunit/include/eunit.hrl").

check_ok_under_limit_test() ->
    ?assertEqual(ok, asobi_jsonb:check(#{~"a" => 1}, 100)).

check_ok_at_limit_test() ->
    %% json:encode(#{}) is "{}"  (2 bytes).
    ?assertEqual(ok, asobi_jsonb:check(#{}, 2)).

check_too_large_test() ->
    Big = #{~"blob" => binary:copy(~"x", 100)},
    ?assertEqual(too_large, asobi_jsonb:check(Big, 10)).

check_not_encodable_test() ->
    ?assertEqual(not_encodable, asobi_jsonb:check(#{~"a" => {tuple}}, 100)).

within_limit_true_test() ->
    ?assert(asobi_jsonb:within_limit(#{~"a" => 1}, 100)).

within_limit_false_on_too_large_test() ->
    Big = #{~"blob" => binary:copy(~"x", 100)},
    ?assertNot(asobi_jsonb:within_limit(Big, 10)).

within_limit_false_on_not_encodable_test() ->
    ?assertNot(asobi_jsonb:within_limit(#{~"a" => {tuple}}, 100)).

default_metadata_bytes_test() ->
    ?assertEqual(16384, asobi_jsonb:default_metadata_bytes()).
