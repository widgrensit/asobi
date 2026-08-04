-module(asobi_qs_tests).

-include_lib("eunit/include/eunit.hrl").

%% asobi_qs exists so a hostile query string cannot reach
%% binary_to_integer/1 (500 + log flood) or pull unbounded rows. Both
%% guarantees are boundary behaviour that nothing else asserts, so they
%% are pinned here rather than left to a controller suite that only ever
%% sends well-formed input.

missing_key_yields_the_default_test() ->
    ?assertEqual(20, asobi_qs:integer(~"limit", [], 20)).

wrong_typed_value_yields_the_default_test() ->
    ?assertEqual(20, asobi_qs:integer(~"limit", [{~"limit", true}], 20)).

valid_value_is_parsed_test() ->
    ?assertEqual(7, asobi_qs:integer(~"limit", [{~"limit", ~"7"}], 20)).

negative_value_is_parsed_test() ->
    ?assertEqual(-7, asobi_qs:integer(~"offset", [{~"offset", ~"-7"}], 0)).

unparsable_value_yields_the_default_test() ->
    Bad = [~"abc", ~"", ~"1.5", ~"7x", ~" 7", ~"0x10"],
    [
        ?assertEqual(20, asobi_qs:integer(~"limit", [{~"limit", V}], 20))
     || V <- Bad
    ].

clamp_holds_the_upper_bound_test() ->
    ?assertEqual(100, asobi_qs:integer(~"limit", [{~"limit", ~"10000000"}], 20, 1, 100)).

clamp_holds_the_lower_bound_test() ->
    ?assertEqual(1, asobi_qs:integer(~"limit", [{~"limit", ~"-5"}], 20, 1, 100)).

clamp_leaves_in_range_values_alone_test() ->
    [
        ?assertEqual(N, asobi_qs:integer(~"limit", [{~"limit", integer_to_binary(N)}], 20, 1, 100))
     || N <- [1, 50, 100]
    ].

%% The default is clamped too: a controller declaring a default outside
%% its own bounds must not be able to smuggle it past the limit.
out_of_range_default_is_clamped_test() ->
    ?assertEqual(100, asobi_qs:integer(~"limit", [], 500, 1, 100)),
    ?assertEqual(1, asobi_qs:integer(~"limit", [], 0, 1, 100)).

unparsable_value_is_clamped_to_the_default_test() ->
    ?assertEqual(20, asobi_qs:integer(~"limit", [{~"limit", ~"abc"}], 20, 1, 100)).

%% A single-point range is the degenerate case of Min =< Max and must
%% still be accepted rather than failing the guard.
single_point_range_test() ->
    ?assertEqual(5, asobi_qs:integer(~"limit", [{~"limit", ~"99"}], 5, 5, 5)).

inverted_range_is_rejected_test() ->
    ?assertError(function_clause, asobi_qs:integer(~"limit", [], 20, 100, 1)).

non_integer_default_is_rejected_test() ->
    ?assertError(function_clause, asobi_qs:integer(~"limit", [], not_an_integer)).
