-module(asobi_player_stats_tests).
-include_lib("eunit/include/eunit.hrl").

%% asobi#329: how a game-declared match result maps onto the wins/losses
%% columns. The SQL itself is exercised against Postgres by
%% asobi_match_stats_SUITE; here we only pin the outcome convention.

-define(SQL_TAB, asobi_player_stats_tests_sql).

setup() ->
    case ets:whereis(?SQL_TAB) of
        undefined -> ets:new(?SQL_TAB, [named_table, public, duplicate_bag]);
        _ -> ets:delete_all_objects(?SQL_TAB)
    end,
    meck:new(kura_db, [passthrough, no_link]),
    meck:expect(kura_db, query, fun(_Repo, SQL, [PlayerId, Win, Loss]) ->
        ets:insert(?SQL_TAB, {PlayerId, Win, Loss, iolist_to_binary(SQL)}),
        #{num_rows => 1}
    end),
    ok.

cleanup(_) ->
    meck:unload(kura_db),
    ok.

record(Participants, Result) ->
    ok = asobi_player_stats:record_match(Participants, Result),
    lists:sort([{P, W, L} || {P, W, L, _SQL} <- ets:tab2list(?SQL_TAB)]).

record_match_test_() ->
    {foreach, fun setup/0, fun cleanup/1, [
        {"every participant gets exactly one games_played increment", fun counts_everyone_once/0},
        {"an empty roster writes nothing", fun empty_roster/0},
        {"a single winner makes every other participant a loser", fun single_winner/0},
        {"binary result keys work, because Lua results have them", fun binary_keys/0},
        {"a winners list is honoured verbatim", fun winners_list/0},
        {"explicit losers override the everyone-else default", fun explicit_losers/0},
        {"ids outside the roster are ignored", fun unknown_ids_ignored/0},
        {"a result with no outcome only moves games_played", fun no_outcome/0},
        {"the UPDATE increments rather than overwrites", fun sql_increments/0}
    ]}.

counts_everyone_once() ->
    ?assertEqual(
        [{~"p1", 0, 0}, {~"p2", 0, 0}, {~"p3", 0, 0}],
        record([~"p1", ~"p2", ~"p3"], #{})
    ).

empty_roster() ->
    ?assertEqual([], record([], #{winner => ~"p1"})).

single_winner() ->
    ?assertEqual(
        [{~"p1", 1, 0}, {~"p2", 0, 1}, {~"p3", 0, 1}],
        record([~"p1", ~"p2", ~"p3"], #{winner => ~"p1"})
    ).

binary_keys() ->
    ?assertEqual(
        [{~"p1", 0, 1}, {~"p2", 1, 0}],
        record([~"p1", ~"p2"], #{~"winner" => ~"p2"})
    ).

winners_list() ->
    ?assertEqual(
        [{~"p1", 1, 0}, {~"p2", 1, 0}, {~"p3", 0, 1}],
        record([~"p1", ~"p2", ~"p3"], #{winners => [~"p1", ~"p2"]})
    ).

explicit_losers() ->
    %% A co-op game where two players survived and nobody is charged a loss.
    ?assertEqual(
        [{~"p1", 1, 0}, {~"p2", 1, 0}, {~"p3", 0, 0}],
        record([~"p1", ~"p2", ~"p3"], #{winners => [~"p1", ~"p2"], losers => []})
    ).

unknown_ids_ignored() ->
    %% A spectator or a player who already left is not in the roster, so it
    %% must not make the remaining participants losers by omission either.
    ?assertEqual(
        [{~"p1", 0, 0}, {~"p2", 0, 0}],
        record([~"p1", ~"p2"], #{winner => ~"ghost"})
    ).

no_outcome() ->
    ?assertEqual(
        [{~"p1", 0, 0}, {~"p2", 0, 0}],
        record([~"p1", ~"p2"], #{status => ~"cancelled"})
    ).

sql_increments() ->
    ok = asobi_player_stats:record_match([~"p1"], #{winner => ~"p1"}),
    [{_, _, _, SQL}] = ets:tab2list(?SQL_TAB),
    ?assertNotEqual(nomatch, binary:match(SQL, ~"games_played = games_played + 1")),
    ?assertNotEqual(nomatch, binary:match(SQL, ~"wins = wins + $2")),
    ?assertNotEqual(nomatch, binary:match(SQL, ~"losses = losses + $3")),
    ?assertNotEqual(nomatch, binary:match(SQL, ~"WHERE player_id = $1")).

%% init/1 is the one stats-creation entry the register, OAuth, and guest
%% controllers all share (asobi#448). The SQL is exercised end to end by the
%% controller SUITEs; here we pin the shared body: it casts a stats changeset
%% for the player and never lets an insert failure escape.

init_setup() ->
    meck:new(asobi_repo, [no_link]),
    meck:new(kura_changeset, [passthrough, no_link]),
    ok.

init_cleanup(_) ->
    meck:unload(kura_changeset),
    meck:unload(asobi_repo),
    ok.

init_test_() ->
    {foreach, fun init_setup/0, fun init_cleanup/1, [
        {"init casts a stats changeset for the player and returns ok",
            fun init_casts_and_returns_ok/0},
        {"init swallows an insert error and still returns ok", fun init_swallows_insert_error/0}
    ]}.

init_casts_and_returns_ok() ->
    meck:expect(asobi_repo, insert, fun(_CS) -> {ok, inserted} end),
    PlayerId = asobi_id:generate(),
    ?assertEqual(ok, asobi_player_stats:init(PlayerId)),
    ?assert(
        meck:called(
            kura_changeset, cast, [asobi_player_stats, #{}, #{player_id => PlayerId}, [player_id]]
        )
    ),
    ?assertEqual(1, meck:num_calls(asobi_repo, insert, '_')).

init_swallows_insert_error() ->
    meck:expect(asobi_repo, insert, fun(_CS) -> {error, boom} end),
    ?assertEqual(ok, asobi_player_stats:init(asobi_id:generate())),
    ?assertEqual(1, meck:num_calls(asobi_repo, insert, '_')).
