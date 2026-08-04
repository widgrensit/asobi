-module(asobi_ops_matchmaker_tests).

-include_lib("eunit/include/eunit.hrl").

%%--------------------------------------------------------------------
%% Snapshot sampling
%%--------------------------------------------------------------------

ticket(Mode, SubmittedAt) ->
    #{mode => Mode, submitted_at => SubmittedAt, player_id => ~"p", id => ~"t"}.

tally_groups_by_mode_test() ->
    Tickets = #{
        ~"t1" => ticket(~"arena", 1000),
        ~"t2" => ticket(~"arena", 3000),
        ~"t3" => ticket(~"duel", 2000)
    },
    ?assertEqual(
        #{
            ~"arena" => #{waiting => 2, oldest => 1000, submitted_sum => 4000},
            ~"duel" => #{waiting => 1, oldest => 2000, submitted_sum => 2000}
        },
        asobi_matchmaker:tally(Tickets)
    ).

tally_of_empty_queue_test() ->
    ?assertEqual(#{}, asobi_matchmaker:tally(#{})).

%% A ticket shape the matchmaker never mints is skipped rather than crashing the
%% tick: publishing runs inside the tick, so a bad row must not stop matchmaking.
tally_skips_unusable_ticket_test() ->
    Tickets = #{~"t1" => #{mode => ~"arena"}, ~"t2" => ticket(~"arena", 1000)},
    ?assertEqual(
        #{~"arena" => #{waiting => 1, oldest => 1000, submitted_sum => 1000}},
        asobi_matchmaker:tally(Tickets)
    ).

modes() ->
    #{~"arena" => #{waiting => 2, oldest => 1000, submitted_sum => 4000}}.

render_reports_totals_test() ->
    Snapshot = asobi_matchmaker:render(5000, modes(), 6000),
    ?assertEqual([age_ms, modes, sampled_at, waiting], lists:sort(maps:keys(Snapshot))),
    ?assertEqual(5000, maps:get(sampled_at, Snapshot)),
    ?assertEqual(1000, maps:get(age_ms, Snapshot)),
    ?assertEqual(2, maps:get(waiting, Snapshot)).

render_waits_are_relative_to_the_reader_test() ->
    [#{oldest_wait_ms := Oldest, average_wait_ms := Average}] =
        maps:get(modes, asobi_matchmaker:render(5000, modes(), 6000)),
    ?assertEqual(5000, Oldest),
    ?assertEqual(4000, Average).

%% The reason waits are derived at read time and not at publish time: between
%% ticks the counts hold still but the waits must keep growing, or a queue that
%% is not moving looks like a queue nobody is waiting in.
render_waits_age_between_ticks_test() ->
    [#{oldest_wait_ms := Early}] = maps:get(modes, asobi_matchmaker:render(5000, modes(), 6000)),
    [#{oldest_wait_ms := Later}] = maps:get(modes, asobi_matchmaker:render(5000, modes(), 9000)),
    ?assertEqual(3000, Later - Early).

%% system_time can step backwards. A negative wait would be read as a broken
%% console rather than a corrected clock.
render_clamps_a_backward_clock_test() ->
    Future = #{~"arena" => #{waiting => 1, oldest => 9000, submitted_sum => 9000}},
    Snapshot = asobi_matchmaker:render(9000, Future, 5000),
    ?assertEqual(0, maps:get(age_ms, Snapshot)),
    [#{oldest_wait_ms := Oldest, average_wait_ms := Average}] = maps:get(modes, Snapshot),
    ?assertEqual(0, Oldest),
    ?assertEqual(0, Average).

%% Reading the queue is total: no matchmaker, or no tick yet, is an empty queue
%% with null timestamps, never an exit and never a blocked caller.
snapshot_is_total_test() ->
    Snapshot = asobi_matchmaker:snapshot(),
    ?assertEqual([age_ms, modes, sampled_at, waiting], lists:sort(maps:keys(Snapshot))),
    ?assert(is_list(maps:get(modes, Snapshot))),
    ?assert(is_integer(maps:get(waiting, Snapshot))).

%%--------------------------------------------------------------------
%% Ops projection
%%--------------------------------------------------------------------

snapshot(Modes) ->
    #{sampled_at => 5000, age_ms => 900, waiting => 3, modes => Modes}.

row(Mode, Waiting) ->
    #{mode => Mode, waiting => Waiting, oldest_wait_ms => 100, average_wait_ms => 50}.

rows_default_order_is_deepest_queue_first_test() ->
    {ok, {_Rows, Orders}} = asobi_ops_matchmaker:rows(snapshot([]), #{}),
    ?assertEqual([{waiting, desc}, {mode, asc}], Orders).

%% One row per mode, so `mode` is the unique key the order has to end on -
%% `id`, the default tie-breaker, does not exist on these rows at all.
rows_order_ends_on_the_unique_key_test() ->
    {ok, {_Rows, Orders}} = asobi_ops_matchmaker:rows(snapshot([]), #{~"sort" => ~"waiting"}),
    ?assertEqual({mode, asc}, lists:last(Orders)).

rows_sort_uses_allowlisted_atom_test() ->
    {ok, {_Rows, Orders}} = asobi_ops_matchmaker:rows(
        snapshot([]), #{~"sort" => ~"oldest_wait_ms", ~"order" => ~"desc"}
    ),
    ?assertEqual([{oldest_wait_ms, desc}, {mode, asc}], Orders).

rows_reject_unknown_sort_test() ->
    ?assertEqual(
        {error, {unknown_sort, ~"player_id"}},
        asobi_ops_matchmaker:rows(snapshot([]), #{~"sort" => ~"player_id"})
    ).

rows_reject_unknown_order_test() ->
    ?assertEqual(
        {error, {unknown_order, ~"sideways"}},
        asobi_ops_matchmaker:rows(snapshot([]), #{~"sort" => ~"mode", ~"order" => ~"sideways"})
    ).

rows_pass_the_modes_through_test() ->
    Modes = [row(~"arena", 2), row(~"duel", 1)],
    ?assertMatch({ok, {Modes, _}}, asobi_ops_matchmaker:rows(snapshot(Modes), #{})).

summary_reports_staleness_test() ->
    Summary = asobi_ops_matchmaker:summary(snapshot([row(~"arena", 3)])),
    ?assertEqual(#{waiting => 3, modes => 1, sampled_at => 5000, age_ms => 900}, Summary).

%% Who is queued is player data. The queue endpoint answers how many and how
%% long, and a ticket or player id must not survive the projection even if the
%% snapshot ever starts carrying one.
project_drops_ticket_detail_test() ->
    Projected = asobi_ops_matchmaker:project(
        (row(~"arena", 2))#{player_id => ~"p1", ticket_id => ~"t1", properties => #{}}
    ),
    ?assertEqual(
        [average_wait_ms, mode, oldest_wait_ms, waiting], lists:sort(maps:keys(Projected))
    ).

sortable_fields_are_all_projected_test() ->
    Projected = maps:keys(asobi_ops_matchmaker:project(row(~"arena", 1))),
    [
        ?assert(lists:member(Column, Projected))
     || {_Wire, Column} <- asobi_ops_matchmaker:sortable()
    ].
