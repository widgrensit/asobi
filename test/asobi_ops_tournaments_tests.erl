-module(asobi_ops_tournaments_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("kura/include/kura.hrl").

default_order_is_deterministic_test() ->
    {ok, #kura_query{order_bys = Orders}} = asobi_ops_tournaments:query(#{}),
    ?assertEqual([{start_at, desc}, {id, desc}], Orders).

every_sort_ends_on_the_unique_key_test() ->
    [
        begin
            {ok, #kura_query{order_bys = Orders}} = asobi_ops_tournaments:query(#{~"sort" => Wire}),
            ?assertMatch({id, _Direction}, lists:last(Orders))
        end
     || {Wire, _Column} <- asobi_ops_tournaments:sortable()
    ].

reject_unknown_sort_test() ->
    ?assertEqual(
        {error, {unknown_sort, ~"metadata"}},
        asobi_ops_tournaments:query(#{~"sort" => ~"metadata"})
    ).

status_filter_is_equality_test() ->
    {ok, #kura_query{wheres = Wheres}} = asobi_ops_tournaments:query(#{~"status" => ~"active"}),
    ?assertEqual([{status, ~"active"}], Wheres).

search_is_ilike_on_the_name_test() ->
    {ok, #kura_query{wheres = Wheres}} = asobi_ops_tournaments:query(#{~"q" => ~"summer"}),
    ?assertEqual([{name, ilike, ~"%summer%"}], Wheres).

projection_drops_game_authored_metadata_test() ->
    Projected = asobi_ops_tournaments:project(sample()),
    ?assertNot(maps:is_key(metadata, Projected)),
    ?assertEqual(#{~"gold" => 100}, maps:get(rewards, Projected)).

%% Sorting on a column that never leaves would leak its ordering to a caller
%% who cannot read it.
sortable_fields_are_all_projected_test() ->
    Projected = maps:keys(asobi_ops_tournaments:project(sample())),
    [
        ?assert(lists:member(Column, Projected))
     || {_Wire, Column} <- asobi_ops_tournaments:sortable()
    ].

%% A row can say `active` with no process behind it - after a node restart,
%% that is exactly what the flag is for. Nothing is registered here, so every
%% row is honestly not live.
live_is_false_when_no_process_is_registered_test() ->
    ?assertEqual(false, maps:get(live, asobi_ops_tournaments:project(sample()))).

live_is_true_while_the_tournament_runs_test() ->
    Id = maps:get(id, sample()),
    yes = global:register_name({asobi_tournament_server, Id}, self()),
    try
        ?assertEqual(true, maps:get(live, asobi_ops_tournaments:project(sample())))
    after
        global:unregister_name({asobi_tournament_server, Id})
    end.

%% `project/1` runs per row from the paginator, so it must not assume the row
%% it is handed carries every column.
live_survives_a_row_without_an_id_test() ->
    ?assertEqual(false, maps:get(live, asobi_ops_tournaments:project(#{name => ~"Cup"}))).

sample() ->
    #{
        id => ~"0197f3d0-1c2b-7000-8000-0000000000aa",
        name => ~"Summer Cup",
        leaderboard_id => ~"summer",
        max_entries => 64,
        entry_fee => #{~"gold" => 10},
        rewards => #{~"gold" => 100},
        status => ~"active",
        start_at => {{2026, 8, 1}, {12, 0, 0}},
        end_at => {{2026, 8, 8}, {12, 0, 0}},
        metadata => #{~"secret" => true},
        inserted_at => {{2026, 7, 30}, {12, 0, 0}}
    }.
