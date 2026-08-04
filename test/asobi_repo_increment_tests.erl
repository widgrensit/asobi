-module(asobi_repo_increment_tests).
-include_lib("eunit/include/eunit.hrl").

%% asobi#362: the statement shape, and everything the seam refuses before it
%% reaches Postgres. Accumulation against a real database is
%% asobi_repo_increment_SUITE.

-define(TAB, asobi_repo_increment_tests_sql).

setup() ->
    case ets:whereis(?TAB) of
        undefined -> ets:new(?TAB, [named_table, public, duplicate_bag]);
        _ -> ets:delete_all_objects(?TAB)
    end,
    meck:new(kura_db, [passthrough, no_link]),
    meck:expect(kura_db, query, fun(_Repo, SQL, Params) ->
        ets:insert(?TAB, {iolist_to_binary(SQL), Params}),
        #{rows => [#{games_played => 1}]}
    end),
    ok.

cleanup(_) ->
    meck:unload(kura_db),
    ok.

increment_test_() ->
    {foreach, fun setup/0, fun cleanup/1, [
        {"the statement accumulates rather than overwrites", fun accumulates/0},
        {"the conflict target is the key, and timestamps ride along", fun conflict_target/0},
        {"every caller value is a bound parameter", fun values_are_parameters/0},
        {"a column outside the schema never reaches SQL", fun unknown_field/0},
        {"a non-integer delta is refused", fun non_integer_delta/0},
        {"a counter cannot also be the conflict target", fun overlapping_key/0},
        {"an empty key or empty deltas is refused", fun empty_maps/0}
    ]}.

increment() ->
    asobi_repo:increment(
        asobi_player_stats,
        #{player_id => ~"p1"},
        #{games_played => 1, wins => 2}
    ).

sql() ->
    [{SQL, _}] = ets:tab2list(?TAB),
    SQL.

contains(SQL, Fragment) ->
    ?assertNotEqual(nomatch, binary:match(SQL, Fragment)).

%% The whole point: kura's on_conflict replaces with the excluded value, which
%% loses every concurrent increment but the last.
accumulates() ->
    ?assertMatch({ok, #{games_played := 1}}, increment()),
    SQL = sql(),
    contains(
        SQL, ~"\"games_played\" = \"player_stats\".\"games_played\" + EXCLUDED.\"games_played\""
    ),
    contains(SQL, ~"\"wins\" = \"player_stats\".\"wins\" + EXCLUDED.\"wins\""),
    contains(SQL, ~"DO UPDATE SET").

conflict_target() ->
    {ok, _} = increment(),
    SQL = sql(),
    contains(SQL, ~"INSERT INTO \"player_stats\""),
    contains(SQL, ~"ON CONFLICT (\"player_id\")"),
    contains(SQL, ~"\"updated_at\" = now()"),
    contains(SQL, ~"RETURNING *").

%% Nothing the caller supplies is interpolated: the id is $1, never text.
values_are_parameters() ->
    {ok, _} = increment(),
    [{SQL, Params}] = ets:tab2list(?TAB),
    ?assertEqual([~"p1", 1, 2], Params),
    ?assertEqual(nomatch, binary:match(SQL, ~"p1")),
    contains(SQL, ~"$1").

unknown_field() ->
    ?assertEqual(
        {error, {unknown_field, asobi_player_stats, robert}},
        asobi_repo:increment(asobi_player_stats, #{player_id => ~"p1"}, #{robert => 1})
    ),
    ?assertEqual([], ets:tab2list(?TAB)).

non_integer_delta() ->
    ?assertEqual(
        {error, {not_an_integer_delta, wins, ~"1"}},
        asobi_repo:increment(asobi_player_stats, #{player_id => ~"p1"}, #{wins => ~"1"})
    ),
    ?assertEqual([], ets:tab2list(?TAB)).

overlapping_key() ->
    ?assertEqual(
        {error, {conflict_target_is_also_a_counter, wins}},
        asobi_repo:increment(asobi_player_stats, #{wins => 1}, #{wins => 1})
    ),
    ?assertEqual([], ets:tab2list(?TAB)).

empty_maps() ->
    ?assertMatch(
        {error, {invalid_increment, _, _, _}},
        asobi_repo:increment(asobi_player_stats, #{}, #{wins => 1})
    ),
    ?assertMatch(
        {error, {invalid_increment, _, _, _}},
        asobi_repo:increment(asobi_player_stats, #{player_id => ~"p1"}, #{})
    ),
    ?assertEqual([], ets:tab2list(?TAB)).
