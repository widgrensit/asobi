-module(asobi_spatial_grid_tests).

-include_lib("eunit/include/eunit.hrl").

%% -------------------------------------------------------------------
%% Helpers
%% -------------------------------------------------------------------

empty_grid() ->
    asobi_spatial_grid:new(16).

populated_grid() ->
    G0 = asobi_spatial_grid:new(16),
    G1 = asobi_spatial_grid:insert(~"a", {5.0, 5.0}, G0),
    G2 = asobi_spatial_grid:insert(~"b", {20.0, 20.0}, G1),
    G3 = asobi_spatial_grid:insert(~"c", {50.0, 50.0}, G2),
    asobi_spatial_grid:insert(~"d", {5.0, 20.0}, G3).

brute_force_radius(Entities, {CX, CY}, Radius) ->
    R2 = Radius * Radius,
    [
        {Id, Pos}
     || {Id, Pos = {X, Y}} <- Entities,
        (X - CX) * (X - CX) + (Y - CY) * (Y - CY) =< R2
    ].

brute_force_rect(Entities, {X1, Y1}, {X2, Y2}) ->
    MinX = min(X1, X2),
    MinY = min(Y1, Y2),
    MaxX = max(X1, X2),
    MaxY = max(Y1, Y2),
    [
        {Id, Pos}
     || {Id, Pos = {X, Y}} <- Entities,
        X >= MinX,
        X =< MaxX,
        Y >= MinY,
        Y =< MaxY
    ].

%% -------------------------------------------------------------------
%% Construction
%% -------------------------------------------------------------------

new_test() ->
    G = empty_grid(),
    ?assertEqual(0, asobi_spatial_grid:size(G)).

%% -------------------------------------------------------------------
%% Insert / Remove / Size
%% -------------------------------------------------------------------

insert_test() ->
    G0 = empty_grid(),
    G1 = asobi_spatial_grid:insert(~"e1", {10.0, 10.0}, G0),
    ?assertEqual(1, asobi_spatial_grid:size(G1)),
    G2 = asobi_spatial_grid:insert(~"e2", {30.0, 30.0}, G1),
    ?assertEqual(2, asobi_spatial_grid:size(G2)).

remove_test() ->
    G0 = asobi_spatial_grid:insert(~"e1", {10.0, 10.0}, empty_grid()),
    G1 = asobi_spatial_grid:remove(~"e1", G0),
    ?assertEqual(0, asobi_spatial_grid:size(G1)).

remove_nonexistent_test() ->
    G = empty_grid(),
    ?assertEqual(0, asobi_spatial_grid:size(asobi_spatial_grid:remove(~"nope", G))).

%% -------------------------------------------------------------------
%% Update
%% -------------------------------------------------------------------

update_same_cell_test() ->
    G0 = asobi_spatial_grid:insert(~"e1", {1.0, 1.0}, empty_grid()),
    G1 = asobi_spatial_grid:update(~"e1", {2.0, 2.0}, G0),
    ?assertEqual(1, asobi_spatial_grid:size(G1)),
    Results = asobi_spatial_grid:query_radius({2.0, 2.0}, 0.1, G1),
    ?assertEqual([{~"e1", {2.0, 2.0}}], Results).

update_cross_cell_test() ->
    G0 = asobi_spatial_grid:insert(~"e1", {1.0, 1.0}, empty_grid()),
    G1 = asobi_spatial_grid:update(~"e1", {20.0, 20.0}, G0),
    ?assertEqual(1, asobi_spatial_grid:size(G1)),
    NearOld = asobi_spatial_grid:query_radius({1.0, 1.0}, 1.0, G1),
    ?assertEqual([], NearOld),
    NearNew = asobi_spatial_grid:query_radius({20.0, 20.0}, 1.0, G1),
    ?assertEqual([{~"e1", {20.0, 20.0}}], NearNew).

update_nonexistent_inserts_test() ->
    G = asobi_spatial_grid:update(~"e1", {5.0, 5.0}, empty_grid()),
    ?assertEqual(1, asobi_spatial_grid:size(G)).

%% -------------------------------------------------------------------
%% query_radius
%% -------------------------------------------------------------------

query_radius_empty_test() ->
    ?assertEqual([], asobi_spatial_grid:query_radius({0.0, 0.0}, 100.0, empty_grid())).

query_radius_basic_test() ->
    G = populated_grid(),
    Results = asobi_spatial_grid:query_radius({5.0, 5.0}, 1.0, G),
    Ids = [Id || {Id, _} <- Results],
    ?assertEqual([~"a"], lists:sort(Ids)).

query_radius_multiple_test() ->
    G = populated_grid(),
    Results = asobi_spatial_grid:query_radius({10.0, 10.0}, 20.0, G),
    Ids = lists:sort([Id || {Id, _} <- Results]),
    ?assert(lists:member(~"a", Ids)),
    ?assert(lists:member(~"b", Ids)),
    ?assert(lists:member(~"d", Ids)).

query_radius_vs_brute_force_test() ->
    G0 = asobi_spatial_grid:new(8),
    AllEntities = [
        {list_to_binary(integer_to_list(I)), {float(I rem 64), float(I div 64)}}
     || I <- lists:seq(0, 255)
    ],
    G = insert_all(AllEntities, G0),
    Center = {32.0, 2.0},
    Radius = 10.0,
    GridResults = lists:sort(asobi_spatial_grid:query_radius(Center, Radius, G)),
    BruteResults = lists:sort(brute_force_radius(AllEntities, Center, Radius)),
    ?assertEqual(BruteResults, GridResults).

%% -------------------------------------------------------------------
%% query_rect
%% -------------------------------------------------------------------

query_rect_empty_test() ->
    ?assertEqual([], asobi_spatial_grid:query_rect({0.0, 0.0}, {100.0, 100.0}, empty_grid())).

query_rect_basic_test() ->
    G = populated_grid(),
    Results = asobi_spatial_grid:query_rect({0.0, 0.0}, {10.0, 10.0}, G),
    Ids = lists:sort([Id || {Id, _} <- Results]),
    ?assertEqual([~"a"], Ids).

query_rect_multiple_test() ->
    G = populated_grid(),
    Results = asobi_spatial_grid:query_rect({0.0, 0.0}, {25.0, 25.0}, G),
    Ids = lists:sort([Id || {Id, _} <- Results]),
    ?assertEqual([~"a", ~"b", ~"d"], Ids).

query_rect_vs_brute_force_test() ->
    G0 = asobi_spatial_grid:new(8),
    AllEntities = [
        {list_to_binary(integer_to_list(I)), {float(I rem 64), float(I div 64)}}
     || I <- lists:seq(0, 255)
    ],
    G = insert_all(AllEntities, G0),
    GridResults = lists:sort(asobi_spatial_grid:query_rect({10.0, 1.0}, {40.0, 3.0}, G)),
    BruteResults = lists:sort(brute_force_rect(AllEntities, {10.0, 1.0}, {40.0, 3.0})),
    ?assertEqual(BruteResults, GridResults).

-spec insert_all([{binary(), asobi_spatial_grid:pos()}], asobi_spatial_grid:grid()) ->
    asobi_spatial_grid:grid().
insert_all([], Grid) ->
    Grid;
insert_all([{Id, Pos} | Rest], Grid) ->
    insert_all(Rest, asobi_spatial_grid:insert(Id, Pos, Grid)).

%% -------------------------------------------------------------------
%% entities_in_cell
%% -------------------------------------------------------------------

entities_in_cell_test() ->
    G = asobi_spatial_grid:insert(
        ~"e1",
        {1.0, 1.0},
        asobi_spatial_grid:insert(~"e2", {2.0, 3.0}, empty_grid())
    ),
    Results = asobi_spatial_grid:entities_in_cell({0, 0}, G),
    Ids = lists:sort([Id || {Id, _} <- Results]),
    ?assertEqual([~"e1", ~"e2"], Ids).

entities_in_empty_cell_test() ->
    ?assertEqual([], asobi_spatial_grid:entities_in_cell({99, 99}, empty_grid())).

%% -------------------------------------------------------------------
%% Edge cases
%% -------------------------------------------------------------------

entity_on_cell_boundary_test() ->
    G0 = asobi_spatial_grid:new(16),
    G1 = asobi_spatial_grid:insert(~"edge", {16.0, 16.0}, G0),
    ?assertEqual(1, asobi_spatial_grid:size(G1)),
    Results = asobi_spatial_grid:query_radius({16.0, 16.0}, 0.1, G1),
    ?assertEqual([{~"edge", {16.0, 16.0}}], Results).

single_entity_test() ->
    G = asobi_spatial_grid:insert(~"solo", {32.0, 32.0}, empty_grid()),
    ?assertEqual(1, asobi_spatial_grid:size(G)),
    ?assertEqual(
        [{~"solo", {32.0, 32.0}}],
        asobi_spatial_grid:query_radius({32.0, 32.0}, 1.0, G)
    ),
    ?assertEqual(
        [],
        asobi_spatial_grid:query_radius({0.0, 0.0}, 1.0, G)
    ).

negative_coords_test() ->
    G0 = asobi_spatial_grid:new(16),
    G1 = asobi_spatial_grid:insert(~"neg", {-5.0, -5.0}, G0),
    Results = asobi_spatial_grid:query_radius({-5.0, -5.0}, 1.0, G1),
    ?assertEqual([{~"neg", {-5.0, -5.0}}], Results).
