-module(asobi_id_tests).

-include_lib("eunit/include/eunit.hrl").

%% Every entity id in the system comes from here, and both properties the
%% moduledoc promises - RFC 9562 v7 layout (so Postgres gets time-ordered
%% keys) and real entropy in rand_suffix/1 - are silently losable behind a
%% dependency bump.

generate_is_a_hyphenated_lowercase_string_test() ->
    Id = asobi_id:generate(),
    ?assert(is_binary(Id)),
    ?assertEqual(36, byte_size(Id)),
    ?assertMatch(
        {match, _},
        re:run(Id, "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
    ).

%% Version nibble 7 and RFC 4122 variant bits. Falling back to v4 would
%% keep every test above green while destroying the index locality that
%% is the entire reason for choosing v7.
generate_sets_the_v7_version_and_variant_test() ->
    <<_:14/binary, Version:8, _/binary>> = asobi_id:generate(),
    ?assertEqual($7, Version),
    <<_:19/binary, Variant:8, _/binary>> = asobi_id:generate(),
    ?assert(lists:member(Variant, "89ab")).

generate_is_unique_across_calls_test() ->
    Ids = [asobi_id:generate() || _ <- lists:seq(1, 1000)],
    ?assertEqual(1000, length(lists:usort(Ids))).

%% The high 48 bits are a millisecond timestamp, so ids minted in order
%% must sort in order - that is what makes them B-tree friendly.
generate_is_time_ordered_test() ->
    First = asobi_id:generate(),
    timer:sleep(2),
    Second = asobi_id:generate(),
    ?assert(First < Second).

rand_suffix_is_lowercase_hex_of_twice_the_byte_length_test() ->
    [
        begin
            Suffix = asobi_id:rand_suffix(N),
            ?assertEqual(N * 2, byte_size(Suffix)),
            ?assertMatch({match, _}, re:run(Suffix, "^[0-9a-f]+$"))
        end
     || N <- [1, 4, 8, 16]
    ].

%% The documented reason rand_suffix/1 exists is that generate/0 shares a
%% prefix within a millisecond. If this ever became timestamp-derived the
%% collision it was written to avoid would come straight back.
rand_suffix_does_not_repeat_within_a_millisecond_test() ->
    Suffixes = [asobi_id:rand_suffix(8) || _ <- lists:seq(1, 1000)],
    ?assertEqual(1000, length(lists:usort(Suffixes))).

rand_suffix_rejects_a_non_positive_length_test() ->
    ?assertError(function_clause, asobi_id:rand_suffix(0)),
    ?assertError(function_clause, asobi_id:rand_suffix(-1)).
