-module(asobi_zone_snapshotter_SUITE).
-moduledoc """
Regression coverage for `asobi_zone_snapshotter:write_snapshot/1`.

Two bugs lived together in this code path and both silently broke
zone persistence:

1. `snapshot_at` was a `system_time(millisecond)` integer, but the
   schema declares the column as `utc_datetime`. Every changeset cast
   failed validation and the row was dropped (the call site swallows
   the error so it only surfaced as a warning log).

2. `world_id` arrived as `undefined` because the zone manager started
   before the world server (which generates the id), so all zone
   snapshots collided on the
   `zone_snapshots_world_id_zone_x_zone_y_index` unique constraint
   from the second world onwards.

These tests pin both: a snapshot for a real world must round-trip
through `load_snapshots/1`, and two worlds writing zones at the same
coordinates must not collide.
""".

-include_lib("nova_test/include/nova_test.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([
    snapshot_round_trip/1,
    snapshot_at_is_castable/1,
    two_worlds_at_same_coords_do_not_collide/1,
    delete_world_clears_snapshots/1
]).

all() ->
    [
        snapshot_round_trip,
        snapshot_at_is_castable,
        two_worlds_at_same_coords_do_not_collide,
        delete_world_clears_snapshots
    ].

init_per_suite(Config) ->
    asobi_test_helpers:start(Config).

end_per_suite(_Config) ->
    ok.

snapshot_round_trip(_Config) ->
    WorldId = asobi_id:generate(),
    %% JSONB does not preserve atom keys — they come back as binaries.
    %% Use the wire form throughout so we pin actual round-trip shape.
    Entities = #{~"player1" => #{~"type" => ~"player", ~"x" => 16, ~"y" => 16}},
    ok = asobi_zone_snapshotter:snapshot_sync(#{
        world_id => WorldId,
        coords => {0, 0},
        entities => Entities,
        zone_state => #{},
        entity_timers => #{},
        spawner_state => #{},
        tick => 0
    }),
    {ok, Loaded} = asobi_zone_snapshotter:load_snapshots(WorldId),
    ?assertMatch(#{{0, 0} := _}, Loaded),
    Snap = maps:get({0, 0}, Loaded),
    ?assertEqual(Entities, maps:get(entities, Snap)).

snapshot_at_is_castable(_Config) ->
    %% Pin the schema contract: snapshot_at must be a calendar:datetime()
    %% tuple after write_snapshot/1 prepares the changeset. A regression
    %% to a raw integer would re-introduce the silent "cannot cast to
    %% utc_datetime" failure.
    WorldId = asobi_id:generate(),
    ok = asobi_zone_snapshotter:snapshot_sync(#{
        world_id => WorldId,
        coords => {1, 2},
        entities => #{},
        zone_state => #{},
        entity_timers => #{},
        spawner_state => #{},
        tick => 7
    }),
    {ok, Loaded} = asobi_zone_snapshotter:load_snapshots(WorldId),
    ?assertMatch(#{{1, 2} := #{tick := 7}}, Loaded),
    SnapshotAt = maps:get(snapshot_at, maps:get({1, 2}, Loaded)),
    ?assertMatch({{_, _, _}, {_, _, _}}, SnapshotAt).

two_worlds_at_same_coords_do_not_collide(_Config) ->
    %% Two worlds writing zone (0, 0) must coexist; the
    %% zone_snapshots_world_id_zone_x_zone_y_index unique constraint
    %% scopes to (world_id, zone_x, zone_y), so distinct world_ids
    %% must never collide.
    WorldA = asobi_id:generate(),
    WorldB = asobi_id:generate(),
    ok = asobi_zone_snapshotter:snapshot_sync(#{
        world_id => WorldA,
        coords => {0, 0},
        entities => #{~"a" => #{}},
        zone_state => #{},
        entity_timers => #{},
        spawner_state => #{},
        tick => 0
    }),
    ok = asobi_zone_snapshotter:snapshot_sync(#{
        world_id => WorldB,
        coords => {0, 0},
        entities => #{~"b" => #{}},
        zone_state => #{},
        entity_timers => #{},
        spawner_state => #{},
        tick => 0
    }),
    {ok, LoadedA} = asobi_zone_snapshotter:load_snapshots(WorldA),
    {ok, LoadedB} = asobi_zone_snapshotter:load_snapshots(WorldB),
    ?assertMatch(#{{0, 0} := #{entities := #{~"a" := _}}}, LoadedA),
    ?assertMatch(#{{0, 0} := #{entities := #{~"b" := _}}}, LoadedB).

delete_world_clears_snapshots(_Config) ->
    WorldId = asobi_id:generate(),
    ok = asobi_zone_snapshotter:snapshot_sync(#{
        world_id => WorldId,
        coords => {0, 0},
        entities => #{},
        zone_state => #{},
        entity_timers => #{},
        spawner_state => #{},
        tick => 0
    }),
    {ok, Before} = asobi_zone_snapshotter:load_snapshots(WorldId),
    ?assertEqual(1, map_size(Before)),
    asobi_zone_snapshotter:delete_world(WorldId),
    %% delete is async cast; give it a moment.
    timer:sleep(50),
    {ok, After} = asobi_zone_snapshotter:load_snapshots(WorldId),
    ?assertEqual(0, map_size(After)).
