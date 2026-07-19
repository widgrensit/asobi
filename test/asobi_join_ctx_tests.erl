-module(asobi_join_ctx_tests).
-include_lib("eunit/include/eunit.hrl").

absent_ctx_is_empty_test() ->
    ?assertEqual({ok, #{}}, asobi_join_ctx:parse(#{})),
    ?assertEqual({ok, #{}}, asobi_join_ctx:parse(#{~"world_id" => ~"w1"})).

not_a_map_payload_is_empty_test() ->
    ?assertEqual({ok, #{}}, asobi_join_ctx:parse(not_a_map)).

accepts_flat_scalars_test() ->
    Ctx = #{~"code" => ~"ABCD", ~"party" => 7, ~"spectator" => true},
    ?assertEqual({ok, Ctx}, asobi_join_ctx:parse(#{~"ctx" => Ctx})).

rejects_non_map_ctx_test() ->
    ?assertEqual({error, ~"invalid_join_ctx"}, asobi_join_ctx:parse(#{~"ctx" => ~"nope"})),
    ?assertEqual({error, ~"invalid_join_ctx"}, asobi_join_ctx:parse(#{~"ctx" => [1, 2]})).

rejects_nesting_test() ->
    %% Nesting is the shape that would let a client hand game code an
    %% unbounded term through an "opaque" field.
    ?assertEqual(
        {error, ~"invalid_join_ctx_value"},
        asobi_join_ctx:parse(#{~"ctx" => #{~"a" => #{~"b" => ~"c"}}})
    ),
    ?assertEqual(
        {error, ~"invalid_join_ctx_value"},
        asobi_join_ctx:parse(#{~"ctx" => #{~"a" => [~"b"]}})
    ).

rejects_too_many_keys_test() ->
    Big = maps:from_list([{integer_to_binary(N), ~"v"} || N <- lists:seq(1, 9)]),
    ?assertEqual({error, ~"join_ctx_too_many_keys"}, asobi_join_ctx:parse(#{~"ctx" => Big})),
    Ok = maps:from_list([{integer_to_binary(N), ~"v"} || N <- lists:seq(1, 8)]),
    ?assertMatch({ok, _}, asobi_join_ctx:parse(#{~"ctx" => Ok})).

rejects_oversized_key_test() ->
    Key = binary:copy(~"k", 65),
    ?assertEqual(
        {error, ~"join_ctx_key_too_long"},
        asobi_join_ctx:parse(#{~"ctx" => #{Key => ~"v"}})
    ),
    ?assertMatch({ok, _}, asobi_join_ctx:parse(#{~"ctx" => #{binary:copy(~"k", 64) => ~"v"}})).

rejects_oversized_value_test() ->
    Val = binary:copy(~"v", 257),
    ?assertEqual(
        {error, ~"join_ctx_value_too_long"},
        asobi_join_ctx:parse(#{~"ctx" => #{~"k" => Val}})
    ),
    ?assertMatch(
        {ok, _}, asobi_join_ctx:parse(#{~"ctx" => #{~"k" => binary:copy(~"v", 256)}})
    ).

rejects_non_binary_key_test() ->
    ?assertEqual(
        {error, ~"invalid_join_ctx_key"},
        asobi_join_ctx:parse(#{~"ctx" => #{atom_key => ~"v"}})
    ).
