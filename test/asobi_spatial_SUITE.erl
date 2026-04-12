-module(asobi_spatial_SUITE).

-include_lib("stdlib/include/assert.hrl").

-export([all/0]).
-export([
    query_radius_basic/1,
    query_radius_with_type_filter/1,
    query_radius_with_exclude/1,
    query_radius_with_custom_filter/1,
    query_radius_sorted/1,
    query_radius_max_results/1,
    query_radius_empty/1,
    query_rect_basic/1,
    query_rect_with_opts/1,
    nearest_basic/1,
    nearest_with_type/1,
    nearest_fewer_than_n/1,
    in_range_true/1,
    in_range_false/1,
    distance_entities/1,
    distance_pos/1,
    entities_without_coords_skipped/1
]).

all() ->
    [
        query_radius_basic,
        query_radius_with_type_filter,
        query_radius_with_exclude,
        query_radius_with_custom_filter,
        query_radius_sorted,
        query_radius_max_results,
        query_radius_empty,
        query_rect_basic,
        query_rect_with_opts,
        nearest_basic,
        nearest_with_type,
        nearest_fewer_than_n,
        in_range_true,
        in_range_false,
        distance_entities,
        distance_pos,
        entities_without_coords_skipped
    ].

%% --- Test data ---

entities() ->
    #{
        ~"a" => #{x => 0.0, y => 0.0, type => ~"npc", health => 100},
        ~"b" => #{x => 3.0, y => 4.0, type => ~"npc", health => 50},
        ~"c" => #{x => 10.0, y => 0.0, type => ~"player", health => 100},
        ~"d" => #{x => 1.0, y => 1.0, type => ~"resource", health => 0},
        ~"e" => #{x => 100.0, y => 100.0, type => ~"npc", health => 200},
        ~"f" => #{name => ~"no_coords"}
    }.

%% --- Radius tests ---

query_radius_basic(_Config) ->
    E = entities(),
    Results = asobi_spatial:query_radius(E, {0.0, 0.0}, 6.0),
    Ids = [Id || {Id, _, _} <- Results],
    ?assert(lists:member(~"a", Ids)),
    ?assert(lists:member(~"b", Ids)),
    ?assert(lists:member(~"d", Ids)),
    ?assertNot(lists:member(~"c", Ids)),
    ?assertNot(lists:member(~"e", Ids)),
    ?assertNot(lists:member(~"f", Ids)),
    %% Check distance for "b" (3-4-5 triangle)
    {~"b", _, Dist} = lists:keyfind(~"b", 1, Results),
    ?assert(abs(Dist - 5.0) < 0.001),
    ok.

query_radius_with_type_filter(_Config) ->
    E = entities(),
    Results = asobi_spatial:query_radius(E, {0.0, 0.0}, 6.0, #{type => ~"npc"}),
    Ids = [Id || {Id, _, _} <- Results],
    ?assert(lists:member(~"a", Ids)),
    ?assert(lists:member(~"b", Ids)),
    ?assertNot(lists:member(~"d", Ids)),
    ok.

query_radius_with_exclude(_Config) ->
    E = entities(),
    Results = asobi_spatial:query_radius(E, {0.0, 0.0}, 6.0, #{exclude => ~"a"}),
    Ids = [Id || {Id, _, _} <- Results],
    ?assertNot(lists:member(~"a", Ids)),
    ?assert(lists:member(~"b", Ids)),
    ok.

query_radius_with_custom_filter(_Config) ->
    E = entities(),
    Results = asobi_spatial:query_radius(E, {0.0, 0.0}, 6.0, #{
        filter => fun
            (_Id, #{health := H}) -> H > 0;
            (_, _) -> false
        end
    }),
    Ids = [Id || {Id, _, _} <- Results],
    ?assert(lists:member(~"a", Ids)),
    ?assert(lists:member(~"b", Ids)),
    ?assertNot(lists:member(~"d", Ids)),
    ok.

query_radius_sorted(_Config) ->
    E = entities(),
    Results = asobi_spatial:query_radius(E, {0.0, 0.0}, 6.0, #{sort => nearest}),
    Distances = [D || {_, _, D} <- Results],
    ?assertEqual(Distances, lists:sort(Distances)),
    ok.

query_radius_max_results(_Config) ->
    E = entities(),
    Results = asobi_spatial:query_radius(E, {0.0, 0.0}, 200.0, #{
        max_results => 2, sort => nearest
    }),
    ?assertEqual(2, length(Results)),
    ok.

query_radius_empty(_Config) ->
    Results = asobi_spatial:query_radius(#{}, {0.0, 0.0}, 10.0),
    ?assertEqual([], Results),
    ok.

%% --- Rect tests ---

query_rect_basic(_Config) ->
    E = entities(),
    Results = asobi_spatial:query_rect(E, {-1.0, -1.0}, {5.0, 5.0}),
    Ids = [Id || {Id, _} <- Results],
    ?assert(lists:member(~"a", Ids)),
    ?assert(lists:member(~"b", Ids)),
    ?assert(lists:member(~"d", Ids)),
    ?assertNot(lists:member(~"c", Ids)),
    ?assertNot(lists:member(~"e", Ids)),
    ok.

query_rect_with_opts(_Config) ->
    E = entities(),
    Results = asobi_spatial:query_rect(E, {-1.0, -1.0}, {5.0, 5.0}, #{
        type => ~"npc", max_results => 1
    }),
    ?assertEqual(1, length(Results)),
    ok.

%% --- Nearest tests ---

nearest_basic(_Config) ->
    E = entities(),
    [{Id, _, _}] = asobi_spatial:nearest(E, {0.0, 0.0}, 1),
    ?assertEqual(~"a", Id),
    ok.

nearest_with_type(_Config) ->
    E = entities(),
    [{Id, _, _}] = asobi_spatial:nearest(E, {0.0, 0.0}, 1, #{type => ~"resource"}),
    ?assertEqual(~"d", Id),
    ok.

nearest_fewer_than_n(_Config) ->
    E = entities(),
    Results = asobi_spatial:nearest(E, {0.0, 0.0}, 100, #{type => ~"resource"}),
    ?assertEqual(1, length(Results)),
    ok.

%% --- Point utilities ---

in_range_true(_Config) ->
    A = #{x => 0.0, y => 0.0},
    B = #{x => 3.0, y => 4.0},
    ?assert(asobi_spatial:in_range(A, B, 5.0)),
    ?assert(asobi_spatial:in_range(A, B, 6.0)),
    ok.

in_range_false(_Config) ->
    A = #{x => 0.0, y => 0.0},
    B = #{x => 3.0, y => 4.0},
    ?assertNot(asobi_spatial:in_range(A, B, 4.9)),
    ok.

distance_entities(_Config) ->
    A = #{x => 0.0, y => 0.0},
    B = #{x => 3.0, y => 4.0},
    ?assert(abs(asobi_spatial:distance(A, B) - 5.0) < 0.001),
    ok.

distance_pos(_Config) ->
    ?assert(abs(asobi_spatial:distance_pos({0.0, 0.0}, {3.0, 4.0}) - 5.0) < 0.001),
    ok.

entities_without_coords_skipped(_Config) ->
    E = #{~"no_pos" => #{name => ~"test"}, ~"with_pos" => #{x => 1.0, y => 1.0, type => ~"npc"}},
    Results = asobi_spatial:query_radius(E, {0.0, 0.0}, 10.0),
    ?assertEqual(1, length(Results)),
    ok.
