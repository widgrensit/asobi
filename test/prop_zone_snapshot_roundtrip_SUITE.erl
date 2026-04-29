-module(prop_zone_snapshot_roundtrip_SUITE).
-moduledoc """
PropEr property for asobi_zone_snapshotter round-trip:

  ∀ (entities, zone_state, entity_timers, spawner_state, tick):
    write_snapshot(WorldId, coords, ...) followed by
    load_snapshots(WorldId) returns the exact same payloads.

The existing eunit/CT coverage uses fixed payloads for a small number of
named regression cases (bad column types, world_id collisions, delete
sweeps). This property explores the data shape: arbitrary entity maps
with binary keys, mixed numeric/string field values, empty zones, and
randomized coords/ticks. A regression that drops keys, mangles JSONB
encoding, or swaps association ordering would shrink to a minimal case.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("proper/include/proper.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([snapshot_roundtrip_property/1]).
-export([prop_snapshot_roundtrip/0]).

-define(NUMTESTS, 25).

all() ->
    [snapshot_roundtrip_property].

init_per_suite(Config) ->
    asobi_test_helpers:start(Config).

end_per_suite(_Config) ->
    ok.

snapshot_roundtrip_property(_Config) ->
    Result = proper:quickcheck(prop_snapshot_roundtrip(), [
        {numtests, ?NUMTESTS},
        {to_file, user},
        long_result
    ]),
    case Result of
        true -> ok;
        Counter -> ct:fail({property_failed, Counter})
    end.

%% --- Property ---

prop_snapshot_roundtrip() ->
    ?FORALL(
        Payload,
        snapshot_payload(),
        run_iteration(narrow_payload(Payload))
    ).

%% Generators
snapshot_payload() ->
    {entities(), zone_state(), entity_timers(), spawner_state(), tick(), coords()}.

%% Map literals with raw types as values are *constants* in PropEr — the
%% raw type is never resolved. Wrap each in ?LET so values get generated.
entities() ->
    proper_types:map(binary_id(), entity_value()).

entity_value() ->
    proper_types:oneof([player_entity(), mob_entity(), proper_types:exactly(#{})]).

player_entity() ->
    ?LET({X, Y}, {coord(), coord()}, #{~"type" => ~"player", ~"x" => X, ~"y" => Y}).

mob_entity() ->
    ?LET(HP, coord(), #{~"type" => ~"mob", ~"hp" => HP}).

zone_state() ->
    proper_types:oneof([
        proper_types:exactly(#{}),
        ?LET(T, proper_types:non_neg_integer(), #{~"tick" => T}),
        ?LET(P, proper_types:oneof([~"day", ~"night"]), #{~"phase" => P})
    ]).

entity_timers() ->
    proper_types:map(binary_id(), proper_types:non_neg_integer()).

spawner_state() ->
    proper_types:oneof([
        proper_types:exactly(#{}),
        ?LET(N, proper_types:non_neg_integer(), #{~"next_id" => N})
    ]).

tick() ->
    proper_types:non_neg_integer().

coords() ->
    {proper_types:integer(-3, 3), proper_types:integer(-3, 3)}.

binary_id() ->
    ?LET(N, proper_types:integer(1, 200), id_to_binary(N)).

-spec id_to_binary(term()) -> binary().
id_to_binary(N) when is_integer(N) -> list_to_binary(integer_to_list(N)).

coord() ->
    proper_types:integer(-100, 100).

%% --- Runner ---

-spec run_iteration({map(), map(), map(), map(), non_neg_integer(), {integer(), integer()}}) ->
    boolean().
run_iteration({Entities, ZoneState, EntityTimers, SpawnerState, Tick, Coords}) ->
    WorldId = asobi_id:generate(),
    Payload = #{
        world_id => WorldId,
        coords => Coords,
        entities => Entities,
        zone_state => ZoneState,
        entity_timers => EntityTimers,
        spawner_state => SpawnerState,
        tick => Tick
    },
    ok = asobi_zone_snapshotter:snapshot_sync(Payload),
    case asobi_zone_snapshotter:load_snapshots(WorldId) of
        {ok, Loaded} when is_map(Loaded) ->
            check_round_trip(Coords, Payload, Loaded);
        Other ->
            io:format(user, "load_snapshots returned ~p~n", [Other]),
            false
    end.

check_round_trip(Coords, Payload, Loaded) ->
    case maps:get(Coords, Loaded, undefined) of
        undefined ->
            io:format(user, "missing coords ~p in loaded ~p~n", [Coords, Loaded]),
            false;
        Snap when is_map(Snap) ->
            Fields = [entities, zone_state, entity_timers, spawner_state, tick],
            lists:all(
                fun(F) ->
                    case maps:get(F, Snap) =:= maps:get(F, Payload) of
                        true ->
                            true;
                        false ->
                            io:format(
                                user,
                                "field ~p mismatch:~n  in:  ~p~n  out: ~p~n",
                                [F, maps:get(F, Payload), maps:get(F, Snap)]
                            ),
                            false
                    end
                end,
                Fields
            )
    end.

-spec narrow_payload(term()) ->
    {map(), map(), map(), map(), non_neg_integer(), {integer(), integer()}}.
narrow_payload({Entities, ZoneState, EntityTimers, SpawnerState, Tick, {ZX, ZY}}) when
    is_map(Entities),
    is_map(ZoneState),
    is_map(EntityTimers),
    is_map(SpawnerState),
    is_integer(Tick),
    Tick >= 0,
    is_integer(ZX),
    is_integer(ZY)
->
    {Entities, ZoneState, EntityTimers, SpawnerState, Tick, {ZX, ZY}}.
