-module(asobi_merge_ops_tests).
-include_lib("eunit/include/eunit.hrl").

%% widgrensit/asobi#572. The property that matters is not that each operator
%% computes the right number - it is that applying two merges in either order
%% gives the same answer, because two zones holding one entity across a seam
%% tick on two schedulers with no ordering between them.

set_test() ->
    ?assertEqual({ok, #{~"n" => 3}}, asobi_merge_ops:apply_ops(#{}, #{~"n" => #{~"set" => 3}})).

set_if_absent_test() ->
    Ops = #{~"n" => #{~"set_if_absent" => 3}},
    ?assertEqual({ok, #{~"n" => 3}}, asobi_merge_ops:apply_ops(#{}, Ops)),
    ?assertEqual({ok, #{~"n" => 1}}, asobi_merge_ops:apply_ops(#{~"n" => 1}, Ops)).

incr_test() ->
    Ops = #{~"hull" => #{~"incr" => -40}},
    {ok, V1} = asobi_merge_ops:apply_ops(#{~"hull" => 100}, Ops),
    ?assertEqual(#{~"hull" => 60}, V1),
    ?assertEqual({ok, #{~"hull" => -40}}, asobi_merge_ops:apply_ops(#{}, Ops)).

min_max_test() ->
    ?assertEqual(
        {ok, #{~"hull" => 40}},
        asobi_merge_ops:apply_ops(#{~"hull" => 100}, #{~"hull" => #{~"min" => 40}})
    ),
    ?assertEqual(
        {ok, #{~"hull" => 100}},
        asobi_merge_ops:apply_ops(#{~"hull" => 100}, #{~"hull" => #{~"min" => 140}})
    ),
    ?assertEqual(
        {ok, #{~"shed" => 4}},
        asobi_merge_ops:apply_ops(#{~"shed" => 2}, #{~"shed" => #{~"max" => 4}})
    ),
    %% Absent field: the argument is the starting point, not 0.
    ?assertEqual(
        {ok, #{~"hull" => 40}}, asobi_merge_ops:apply_ops(#{}, #{~"hull" => #{~"min" => 40}})
    ).

latch_is_sticky_test() ->
    On = #{~"dead" => #{~"latch" => true}},
    Off = #{~"dead" => #{~"latch" => false}},
    {ok, V1} = asobi_merge_ops:apply_ops(#{}, Off),
    ?assertEqual(#{~"dead" => false}, V1),
    {ok, V2} = asobi_merge_ops:apply_ops(V1, On),
    ?assertEqual(#{~"dead" => true}, V2),
    ?assertEqual({ok, V2}, asobi_merge_ops:apply_ops(V2, Off)).

%% The whole point: order-independence for the commutative operators.
order_independent_test() ->
    A = #{~"hull" => #{~"min" => 60}, ~"shed" => #{~"max" => 2}, ~"kills" => #{~"incr" => 1}},
    B = #{~"hull" => #{~"min" => 40}, ~"shed" => #{~"max" => 4}, ~"kills" => #{~"incr" => 2}},
    Start = #{~"hull" => 100, ~"shed" => 0, ~"kills" => 0},
    {ok, AB0} = asobi_merge_ops:apply_ops(Start, A),
    {ok, AB} = asobi_merge_ops:apply_ops(AB0, B),
    {ok, BA0} = asobi_merge_ops:apply_ops(Start, B),
    {ok, BA} = asobi_merge_ops:apply_ops(BA0, A),
    ?assertEqual(AB, BA),
    ?assertEqual(#{~"hull" => 40, ~"shed" => 4, ~"kills" => 3}, AB).

unknown_operator_is_an_error_test() ->
    ?assertMatch(
        {error, _}, asobi_merge_ops:apply_ops(#{}, #{~"n" => #{~"increment" => 1}})
    ).

%% A bare value is NOT quietly treated as `set`: that reads exactly like a
%% working merge and loses writes.
bare_value_is_an_error_test() ->
    ?assertMatch({error, _}, asobi_merge_ops:apply_ops(#{}, #{~"n" => 3})).

two_operators_in_one_field_is_an_error_test() ->
    Ops = #{~"n" => #{~"min" => 1, ~"max" => 2}},
    ?assertMatch({error, _}, asobi_merge_ops:apply_ops(#{}, Ops)).

wrong_type_is_an_error_test() ->
    ?assertMatch(
        {error, _},
        asobi_merge_ops:apply_ops(#{~"n" => ~"text"}, #{~"n" => #{~"incr" => 1}})
    ),
    ?assertMatch({error, _}, asobi_merge_ops:apply_ops(#{}, #{~"n" => #{~"incr" => ~"one"}})),
    ?assertMatch({error, _}, asobi_merge_ops:apply_ops(#{}, #{~"n" => #{~"latch" => 1}})).
