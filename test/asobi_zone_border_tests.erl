-module(asobi_zone_border_tests).
-include_lib("eunit/include/eunit.hrl").

%% A 100-unit zone at (1,1) covers [100,200) on both axes; a band of 10 is
%% therefore x<110, x>=190, y<110 or y>=190.
-define(ZS, 100).
-define(GRID, 5).
-define(TAB, {?MODULE, tab}).

%% One table per world in production, owned by the world's instance supervisor.
%% Here the eunit foreach parent owns it, which is the same lifetime property:
%% it outlives the individual test bodies.
setup() ->
    case persistent_term:get(?TAB, undefined) of
        undefined -> persistent_term:put(?TAB, asobi_zone_border:new());
        Tab -> ets:delete_all_objects(Tab)
    end.

tab() -> persistent_term:get(?TAB).

e(X, Y) -> #{type => ~"npc", x => X, y => Y}.

%% Mirrors what asobi_zone:publish_border/1 actually does - compute the band,
%% then write it - rather than a convenience wrapper src/ does not call. A test
%% driving a second implementation of the production path is a test that cannot
%% catch the production path being wrong.
publish(Tab, Coords, ZoneSize, Band, Entities) ->
    case asobi_zone_border:band_entities(Coords, ZoneSize, Band, Entities) of
        Empty when map_size(Empty) =:= 0 -> asobi_zone_border:clear(Tab, Coords);
        InBand -> asobi_zone_border:write_band(Tab, Coords, InBand)
    end.

border_test_() ->
    {foreach, fun setup/0, fun(_) -> setup() end, [
        {"the band keeps only entities near an edge", fun band_selects_edges/0},
        {"an entity with no position is never in the band", fun band_skips_unpositioned/0},
        {"binary-keyed entities are read too", fun band_reads_binary_keys/0},
        {"a corner zone has three neighbours", fun neighbours_clamped_to_grid/0},
        {"a middle zone has eight", fun neighbours_middle/0},
        {"a zone never neighbours itself", fun neighbours_excludes_self/0},
        {"a radius query reads the neighbours, not the caller", fun radius_reads_neighbours/0},
        {"query opts are honoured", fun radius_honours_opts/0},
        {"a rect query reads the neighbours", fun rect_reads_neighbours/0},
        {"owner finds the publishing zone", fun owner_finds_zone/0},
        {"owner refuses an entity no neighbour publishes", fun owner_refuses_unseen/0},
        {"clear removes the row", fun clear_removes/0},
        {"one world never reads another's band", fun worlds_are_isolated/0},
        {"no table at all degrades to empty, never crashes", fun no_table_is_empty/0}
    ]}.

band_selects_edges() ->
    Entities = #{
        ~"near_left" => e(105.0, 150.0),
        ~"near_right" => e(195.0, 150.0),
        ~"near_top" => e(150.0, 102.0),
        ~"middle" => e(150.0, 150.0)
    },
    InBand = asobi_zone_border:band_entities({1, 1}, ?ZS, 10, Entities),
    ?assertEqual(
        [~"near_left", ~"near_right", ~"near_top"], lists:sort(maps:keys(InBand))
    ).

band_skips_unpositioned() ->
    Entities = #{~"ghost" => #{type => ~"npc"}, ~"real" => e(105.0, 150.0)},
    ?assertEqual([~"real"], maps:keys(asobi_zone_border:band_entities({1, 1}, ?ZS, 10, Entities))).

band_reads_binary_keys() ->
    %% The Lua bridge decodes entities to binary keys; asobi_zone reads both
    %% shapes and so must this, or the mirror is silently empty for every Lua
    %% world.
    Entities = #{~"lua" => #{~"type" => ~"npc", ~"x" => 105.0, ~"y" => 150.0}},
    ?assertEqual([~"lua"], maps:keys(asobi_zone_border:band_entities({1, 1}, ?ZS, 10, Entities))).

neighbours_clamped_to_grid() ->
    ?assertEqual(
        [{0, 1}, {1, 0}, {1, 1}], lists:sort(asobi_zone_border:neighbours({0, 0}, ?GRID))
    ).

neighbours_middle() ->
    ?assertEqual(8, length(asobi_zone_border:neighbours({2, 2}, ?GRID))).

neighbours_excludes_self() ->
    ?assertNot(lists:member({2, 2}, asobi_zone_border:neighbours({2, 2}, ?GRID))).

radius_reads_neighbours() ->
    %% The caller is (1,1). (2,1) owns a pirate just past the shared seam at
    %% x=200; (1,1) owns a pilot of its own at x=195. A radius query from the
    %% caller must return the neighbour's pirate and NOT its own pilot - the
    %% caller already holds its own entity map, and returning both would double
    %% every in-zone entity.
    publish(tab(), {2, 1}, ?ZS, 10, #{~"pirate" => e(205.0, 150.0)}),
    publish(tab(), {1, 1}, ?ZS, 10, #{~"pilot" => e(195.0, 150.0)}),
    Results = asobi_zone_border:query_radius(tab(), {1, 1}, ?GRID, {195.0, 150.0}, 20.0),
    ?assertMatch([{~"pirate", _, _}], Results).

radius_honours_opts() ->
    publish(tab(), {2, 1}, ?ZS, 10, #{
        ~"pirate" => e(205.0, 150.0),
        ~"rock" => (e(206.0, 150.0))#{type => ~"debris"}
    }),
    Results = asobi_zone_border:query_radius(
        tab(), {1, 1}, ?GRID, {195.0, 150.0}, 20.0, #{type => ~"npc"}
    ),
    ?assertMatch([{~"pirate", _, _}], Results).

rect_reads_neighbours() ->
    publish(tab(), {2, 1}, ?ZS, 10, #{~"pirate" => e(205.0, 150.0)}),
    Results = asobi_zone_border:query_rect(
        tab(), {1, 1}, ?GRID, {190.0, 140.0}, {210.0, 160.0}
    ),
    ?assertMatch([{~"pirate", _}], Results).

owner_finds_zone() ->
    publish(tab(), {2, 1}, ?ZS, 10, #{~"pirate" => e(205.0, 150.0)}),
    ?assertEqual({ok, {2, 1}}, asobi_zone_border:owner(tab(), {1, 1}, ?GRID, ~"pirate")).

owner_refuses_unseen() ->
    %% (3,1) does not touch (1,1). Publishing there must not make its entities
    %% addressable from (1,1): "what I may affect" is "what I can see".
    publish(tab(), {3, 1}, ?ZS, 10, #{~"far" => e(305.0, 150.0)}),
    ?assertEqual(error, asobi_zone_border:owner(tab(), {1, 1}, ?GRID, ~"far")),
    ?assertEqual(error, asobi_zone_border:owner(tab(), {1, 1}, ?GRID, ~"nobody")),
    ?assertEqual(error, asobi_zone_border:owner(tab(), {1, 1}, ?GRID, not_a_binary)).

clear_removes() ->
    publish(tab(), {2, 1}, ?ZS, 10, #{~"pirate" => e(205.0, 150.0)}),
    asobi_zone_border:clear(tab(), {2, 1}),
    ?assertEqual([], asobi_zone_border:query_radius(tab(), {1, 1}, ?GRID, {200.0, 150.0}, 50.0)).

%% One table per world is the whole cross-tenant story for this mirror: there is
%% no key convention to get wrong, because a zone in world A is never handed
%% world B's table in the first place.
worlds_are_isolated() ->
    Other = asobi_zone_border:new(),
    asobi_zone_border:write_band(Other, {2, 1}, #{~"theirs" => e(205.0, 150.0)}),
    try
        ?assertEqual(
            [], asobi_zone_border:query_radius(tab(), {1, 1}, ?GRID, {205.0, 150.0}, 50.0)
        ),
        ?assertEqual(error, asobi_zone_border:owner(tab(), {1, 1}, ?GRID, ~"theirs")),
        ?assertMatch(
            [{~"theirs", _, _}],
            asobi_zone_border:query_radius(Other, {1, 1}, ?GRID, {205.0, 150.0}, 50.0)
        )
    after
        ets:delete(Other)
    end.

%% A zone started outside a world instance (every unit test that starts one
%% bare) has no table at all. Every entry point must degrade to empty rather
%% than crash the zone mid-tick.
no_table_is_empty() ->
    ?assertEqual([], asobi_zone_border:query_radius(undefined, {1, 1}, ?GRID, {0.0, 0.0}, 10.0)),
    ?assertEqual(
        [], asobi_zone_border:query_rect(undefined, {1, 1}, ?GRID, {0.0, 0.0}, {9.9, 9.9})
    ),
    ?assertEqual(error, asobi_zone_border:owner(undefined, {1, 1}, ?GRID, ~"x")),
    ?assertEqual(ok, asobi_zone_border:clear(undefined, {1, 1})),
    ?assertEqual(ok, asobi_zone_border:write_band(undefined, {1, 1}, #{~"a" => e(1.0, 1.0)})).
