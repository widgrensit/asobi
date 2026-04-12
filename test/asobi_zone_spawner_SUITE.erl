-module(asobi_zone_spawner_SUITE).

-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([
    spawn_from_template/1,
    spawn_unknown_template/1,
    spawn_with_overrides/1,
    spawn_with_explicit_id/1,
    entity_removed_schedules_respawn/1,
    tick_respawns_entities/1,
    respawn_max_limit/1,
    no_respawn_when_undefined/1,
    serialise_deserialise/1,
    info_reports_state/1
]).

all() ->
    [
        spawn_from_template,
        spawn_unknown_template,
        spawn_with_overrides,
        spawn_with_explicit_id,
        entity_removed_schedules_respawn,
        tick_respawns_entities,
        respawn_max_limit,
        no_respawn_when_undefined,
        serialise_deserialise,
        info_reports_state
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(asobi),
    Config.

end_per_suite(Config) ->
    Config.

templates() ->
    #{
        ~"goblin" => #{
            template_id => ~"goblin",
            type => ~"npc",
            base_state => #{health => 100, ai => ~"patrol"},
            respawn => #{strategy => timer, delay => 1000, max_respawns => infinity, jitter => 0}
        },
        ~"ore" => #{
            template_id => ~"ore",
            type => ~"resource",
            base_state => #{quantity => 5},
            respawn => #{strategy => timer, delay => 500, max_respawns => 2, jitter => 0}
        },
        ~"chest" => #{
            template_id => ~"chest",
            type => ~"object",
            base_state => #{loot => ~"common"},
            respawn => undefined
        }
    }.

%% --- Tests ---

spawn_from_template(_Config) ->
    S0 = asobi_zone_spawner:new(templates()),
    {ok, {Id, Entity}, S1} = asobi_zone_spawner:spawn_entity(~"goblin", {10.0, 20.0}, S0),
    ?assert(is_binary(Id)),
    ?assertMatch(#{type := ~"npc", health := 100, x := 10.0, y := 20.0}, Entity),
    ?assertEqual(1, asobi_zone_spawner:get_spawn_count(~"goblin", S1)),
    ok.

spawn_unknown_template(_Config) ->
    S0 = asobi_zone_spawner:new(templates()),
    ?assertEqual(
        {error, unknown_template}, asobi_zone_spawner:spawn_entity(~"dragon", {0.0, 0.0}, S0)
    ),
    ok.

spawn_with_overrides(_Config) ->
    S0 = asobi_zone_spawner:new(templates()),
    {ok, {_, Entity}, _S1} = asobi_zone_spawner:spawn_entity(
        ~"goblin", {5.0, 5.0}, #{health => 200}, S0
    ),
    ?assertMatch(#{health := 200, ai := ~"patrol"}, Entity),
    ok.

spawn_with_explicit_id(_Config) ->
    S0 = asobi_zone_spawner:new(templates()),
    {ok, {~"my-goblin", Entity}, _S1} = asobi_zone_spawner:spawn_entity(
        ~"goblin", ~"my-goblin", {1.0, 2.0}, #{}, S0
    ),
    ?assertMatch(#{type := ~"npc", x := 1.0, y := 2.0}, Entity),
    ok.

entity_removed_schedules_respawn(_Config) ->
    S0 = asobi_zone_spawner:new(templates()),
    {ok, {Id, _}, S1} = asobi_zone_spawner:spawn_entity(~"goblin", {10.0, 20.0}, S0),
    Now = erlang:system_time(millisecond),
    S2 = asobi_zone_spawner:entity_removed(Id, Now, S1),
    Info = asobi_zone_spawner:info(S2),
    ?assertEqual(1, maps:get(pending_respawns, Info)),
    ok.

tick_respawns_entities(_Config) ->
    S0 = asobi_zone_spawner:new(templates()),
    {ok, {Id, _}, S1} = asobi_zone_spawner:spawn_entity(~"goblin", {10.0, 20.0}, S0),
    Now = erlang:system_time(millisecond),
    S2 = asobi_zone_spawner:entity_removed(Id, Now, S1),
    %% Not ready yet
    {[], S3} = asobi_zone_spawner:tick(Now + 500, S2),
    %% Ready after delay
    {Spawned, S4} = asobi_zone_spawner:tick(Now + 1001, S3),
    ?assertEqual(1, length(Spawned)),
    [{_, Entity, {10.0, 20.0}}] = Spawned,
    ?assertMatch(#{type := ~"npc", health := 100}, Entity),
    ?assertEqual(0, maps:get(pending_respawns, asobi_zone_spawner:info(S4))),
    ok.

respawn_max_limit(_Config) ->
    S0 = asobi_zone_spawner:new(templates()),
    %% Ore has max_respawns => 2, so after 2 spawns no more respawns
    {ok, {Id, _}, S1} = asobi_zone_spawner:spawn_entity(~"ore", ~"ore1", {5.0, 5.0}, #{}, S0),
    Now = erlang:system_time(millisecond),
    %% First removal: count=1, should schedule respawn (1 < 2)
    S2 = asobi_zone_spawner:entity_removed(Id, Now, S1),
    {Spawned1, S3} = asobi_zone_spawner:tick(Now + 501, S2),
    ?assertEqual(1, length(Spawned1)),
    %% Second removal: count=2, should NOT schedule respawn (2 >= 2)
    S4 = asobi_zone_spawner:entity_removed(Id, Now + 600, S3),
    ?assertEqual(0, maps:get(pending_respawns, asobi_zone_spawner:info(S4))),
    ok.

no_respawn_when_undefined(_Config) ->
    S0 = asobi_zone_spawner:new(templates()),
    {ok, {Id, _}, S1} = asobi_zone_spawner:spawn_entity(~"chest", {1.0, 1.0}, S0),
    Now = erlang:system_time(millisecond),
    S2 = asobi_zone_spawner:entity_removed(Id, Now, S1),
    ?assertEqual(0, maps:get(pending_respawns, asobi_zone_spawner:info(S2))),
    ok.

serialise_deserialise(_Config) ->
    S0 = asobi_zone_spawner:new(templates()),
    {ok, {Id, _}, S1} = asobi_zone_spawner:spawn_entity(~"goblin", ~"g1", {10.0, 20.0}, #{}, S0),
    Now = erlang:system_time(millisecond),
    S2 = asobi_zone_spawner:entity_removed(Id, Now, S1),
    Serialised = asobi_zone_spawner:serialise(S2),
    %% Should be JSON-safe maps
    ?assert(is_map(Serialised)),
    S3 = asobi_zone_spawner:deserialise(Serialised),
    ?assertEqual(1, maps:get(pending_respawns, asobi_zone_spawner:info(S3))),
    ok.

info_reports_state(_Config) ->
    S0 = asobi_zone_spawner:new(templates()),
    Info0 = asobi_zone_spawner:info(S0),
    ?assertEqual(0, maps:get(pending_respawns, Info0)),
    ?assertEqual(0, maps:get(total_spawned, Info0)),
    ?assertEqual(0, maps:get(tracked_entities, Info0)),
    {ok, {_, _}, S1} = asobi_zone_spawner:spawn_entity(~"goblin", {0.0, 0.0}, S0),
    Info1 = asobi_zone_spawner:info(S1),
    ?assertEqual(1, maps:get(total_spawned, Info1)),
    ?assertEqual(1, maps:get(tracked_entities, Info1)),
    ok.
