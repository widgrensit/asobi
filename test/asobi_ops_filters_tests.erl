-module(asobi_ops_filters_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("kura/include/kura.hrl").

build(Params, Specs) ->
    asobi_ops_filters:build(kura_query:from(asobi_player), Params, Specs).

wheres(Params, Specs) ->
    {ok, #kura_query{wheres = Wheres}} = build(Params, Specs),
    Wheres.

%%--------------------------------------------------------------------
%% Absent and empty
%%--------------------------------------------------------------------

no_params_no_clauses_test() ->
    ?assertEqual([], wheres(#{}, [{~"mode", mode, equals}, {~"q", username, ilike}])).

empty_value_does_not_filter_test() ->
    ?assertEqual([], wheres(#{~"mode" => ~""}, [{~"mode", mode, equals}])).

%%--------------------------------------------------------------------
%% Exact match
%%--------------------------------------------------------------------

equals_builds_one_clause_test() ->
    ?assertEqual(
        [{mode, ~"deathmatch"}],
        wheres(#{~"mode" => ~"deathmatch"}, [{~"mode", mode, equals}])
    ).

%% Spec order is clause order, so an endpoint's `WHERE` list is stable and
%% its tests can assert on it.
clauses_follow_spec_order_test() ->
    ?assertEqual(
        [{mode, ~"duel"}, {status, ~"finished"}],
        wheres(
            #{~"mode" => ~"duel", ~"status" => ~"finished"},
            [{~"mode", mode, equals}, {~"status", status, equals}]
        )
    ).

oversized_equals_is_dropped_test() ->
    ?assertEqual([], wheres(#{~"mode" => binary:copy(~"m", 65)}, [{~"mode", mode, equals}])).

%%--------------------------------------------------------------------
%% Boolean
%%--------------------------------------------------------------------

boolean_builds_a_boolean_clause_test() ->
    ?assertEqual(
        [{active, false}], wheres(#{~"active" => ~"false"}, [{~"active", active, boolean}])
    ).

unparseable_boolean_does_not_filter_test() ->
    ?assertEqual([], wheres(#{~"active" => ~"1"}, [{~"active", active, boolean}])).

%%--------------------------------------------------------------------
%% Uuid
%%--------------------------------------------------------------------

uuid_builds_an_equality_clause_test() ->
    Id = asobi_id:generate(),
    ?assertEqual(
        [{player_id, Id}],
        wheres(#{~"player_id" => Id}, [{~"player_id", player_id, uuid}])
    ).

%% The one filter that is rejected rather than dropped. Dropping it would
%% answer a request scoped to one player with every player's rows, and no
%% part of the response would say so.
malformed_uuid_is_rejected_not_dropped_test() ->
    ?assertEqual(
        {error, {invalid_filter, ~"player_id"}},
        build(#{~"player_id" => ~"'; drop table players --"}, [{~"player_id", player_id, uuid}])
    ).

rejection_stops_the_build_test() ->
    ?assertEqual(
        {error, {invalid_filter, ~"player_id"}},
        build(
            #{~"player_id" => ~"nope", ~"type" => ~"system"},
            [{~"type", type, equals}, {~"player_id", player_id, uuid}]
        )
    ).

absent_uuid_does_not_filter_test() ->
    ?assertEqual([], wheres(#{}, [{~"player_id", player_id, uuid}])).

%%--------------------------------------------------------------------
%% ilike
%%--------------------------------------------------------------------

ilike_one_column_is_a_bare_clause_test() ->
    ?assertEqual(
        [{mode, ilike, ~"%duel%"}],
        wheres(#{~"q" => ~"duel"}, [{~"q", mode, ilike}])
    ).

ilike_many_columns_is_a_disjunction_test() ->
    ?assertEqual(
        [{'or', [{username, ilike, ~"%kai%"}, {display_name, ilike, ~"%kai%"}]}],
        wheres(#{~"q" => ~"kai"}, [{~"q", [username, display_name], ilike}])
    ).

ilike_a_single_column_list_is_not_a_disjunction_test() ->
    ?assertEqual(
        [{username, ilike, ~"%kai%"}],
        wheres(#{~"q" => ~"kai"}, [{~"q", [username], ilike}])
    ).

%% A lone `%` in a search term matches every row unless it is escaped, which
%% turns a search box into a full scan.
ilike_escapes_wildcards_test() ->
    ?assertEqual(
        [{username, ilike, ~"%100\\%\\_off%"}],
        wheres(#{~"q" => ~"100%_off"}, [{~"q", username, ilike}])
    ).

oversized_search_does_not_filter_test() ->
    ?assertEqual([], wheres(#{~"q" => binary:copy(~"a", 65)}, [{~"q", username, ilike}])).
