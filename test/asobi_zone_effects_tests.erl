-module(asobi_zone_effects_tests).
-include_lib("eunit/include/eunit.hrl").

-define(LOG, asobi_zone_effects_log).

%% Game module under test: records every effects batch it is handed and applies
%% each event's `hp_delta`, so a test can assert both what arrived and that the
%% zone wrote the result back.
-export([zone_tick/2, handle_input/3, handle_effects/2]).
-export([zone_tick_no_effects/2]).

zone_tick(E, ZS) -> {E, ZS}.
handle_input(_P, _I, E) -> {ok, E}.
zone_tick_no_effects(E, ZS) -> {E, ZS}.

%% Recorded in ETS rather than sent to the test process: eunit runs a `foreach`
%% setup in a different process from the test body, so `self()` captured in
%% setup is not the process that would receive the message.
handle_effects(Effects, Entities) ->
    ets:insert(?LOG, {erlang:unique_integer([monotonic]), Effects}),
    {ok, apply_deltas(Effects, Entities)}.

apply_deltas([], Entities) ->
    Entities;
apply_deltas([{Id, Event} | Rest], Entities) ->
    #{Id := E} = Entities,
    Hp = maps:get(hp, E, 0) + maps:get(~"hp_delta", Event, 0),
    apply_deltas(Rest, Entities#{Id => E#{hp => Hp}}).

setup() ->
    case ets:whereis(?LOG) of
        undefined -> ets:new(?LOG, [named_table, public, ordered_set]);
        _ -> ets:delete_all_objects(?LOG)
    end,
    case ets:info(asobi_world_state) of
        undefined -> ets:new(asobi_world_state, [named_table, public, set]);
        _ -> ok
    end,
    case pg:start(nova_scope) of
        {ok, _} -> ok;
        {error, {already_started, _}} -> ok
    end,
    case persistent_term:get({?MODULE, tab}, undefined) of
        undefined -> persistent_term:put({?MODULE, tab}, asobi_zone_border:new());
        Tab -> ets:delete_all_objects(Tab)
    end,
    ok.

tab() -> persistent_term:get({?MODULE, tab}).

start_zone(GameMod) ->
    {ok, Pid} = asobi_zone:start_link(#{
        world_id => ~"effects-world",
        coords => {1, 1},
        ticker_pid => self(),
        zone_size => 100,
        grid_size => 5,
        border_band => 0.1,
        border_tab => tab(),
        game_module => GameMod
    }),
    Pid.

tick(Pid, N) ->
    asobi_zone:tick(Pid, N),
    _ = sys:get_state(Pid),
    ok.

effects_test_() ->
    {foreach, fun setup/0, fun(_) -> ok end, [
        {"an effect reaches the owning zone's handler", fun effect_delivered/0},
        {"the handler's entity map is written back", fun effect_result_applied/0},
        {"an effect for an entity the zone lost is dropped", fun effect_for_missing_entity/0},
        {"the queue is drained every tick", fun queue_drains/0},
        {"the queue is capped by count", fun queue_capped/0},
        {"the queue is capped by size", fun queue_capped_by_size/0},
        {"a module with no handler drops effects and survives", fun no_handler_survives/0},
        {"a zone publishes its band as it ticks", fun zone_publishes_band/0},
        {"a zone clears its band on stop", fun zone_clears_band_on_stop/0},
        {"a killed zone's band does not outlive it", fun band_does_not_survive_a_kill/0},
        {"a handler returning a non-map leaves the entities alone", fun bad_return_is_a_noop/0},
        {"a spawn warms a cold zone", fun spawn_warms/0},
        {"an entity timer warms a cold zone", fun timer_warms/0},
        {"effects run after inputs, and timers after effects", fun effect_ordering/0}
    ]}.

effect_delivered() ->
    Pid = start_zone(?MODULE),
    asobi_zone:add_entity(Pid, ~"target", #{type => ~"npc", x => 150.0, y => 150.0, hp => 100}),
    asobi_zone:apply_effect(Pid, ~"target", #{~"hp_delta" => -30}),
    tick(Pid, 1),
    ?assertEqual([[{~"target", #{~"hp_delta" => -30}}]], logged()),
    gen_server:stop(Pid).

logged() -> [E || {_, E} <- ets:tab2list(?LOG)].

effect_result_applied() ->
    Pid = start_zone(?MODULE),
    asobi_zone:add_entity(Pid, ~"target", #{type => ~"npc", x => 150.0, y => 150.0, hp => 100}),
    asobi_zone:apply_effect(Pid, ~"target", #{~"hp_delta" => -30}),
    tick(Pid, 1),
    ?assertMatch(#{~"target" := #{hp := 70}}, asobi_zone:get_entities(Pid)),
    gen_server:stop(Pid).

effect_for_missing_entity() ->
    %% The target crossed away or died between the neighbour reading the band
    %% and this tick. The handler must not be asked to look up a nil id.
    Pid = start_zone(?MODULE),
    asobi_zone:apply_effect(Pid, ~"ghost", #{~"hp_delta" => -30}),
    tick(Pid, 1),
    ?assertEqual([], logged()),
    gen_server:stop(Pid).

queue_drains() ->
    Pid = start_zone(?MODULE),
    asobi_zone:add_entity(Pid, ~"target", #{type => ~"npc", x => 150.0, y => 150.0, hp => 100}),
    asobi_zone:apply_effect(Pid, ~"target", #{~"hp_delta" => -10}),
    tick(Pid, 1),
    ?assertEqual(1, length(logged())),
    tick(Pid, 2),
    ?assertEqual(1, length(logged())),
    ?assertMatch(#{~"target" := #{hp := 90}}, asobi_zone:get_entities(Pid)),
    gen_server:stop(Pid).

queue_capped() ->
    Pid = start_zone(?MODULE),
    asobi_zone:add_entity(Pid, ~"target", #{type => ~"npc", x => 150.0, y => 150.0, hp => 0}),
    lists:foreach(
        fun(_) -> asobi_zone:apply_effect(Pid, ~"target", #{~"hp_delta" => 1}) end,
        lists:seq(1, 400)
    ),
    tick(Pid, 1),
    ?assertMatch([Effects] when length(Effects) =:= 256, logged()),
    gen_server:stop(Pid).

%% A count alone bounds nothing that matters: 256 entries of an arbitrary table
%% is an arbitrary number of megabytes on the zone's heap.
queue_capped_by_size() ->
    Pid = start_zone(?MODULE),
    asobi_zone:add_entity(Pid, ~"target", #{type => ~"npc", x => 150.0, y => 150.0, hp => 0}),
    Big = maps:from_keys([integer_to_binary(I) || I <- lists:seq(1, 2_000)], 1),
    lists:foreach(
        fun(_) -> asobi_zone:apply_effect(Pid, ~"target", Big#{~"hp_delta" => 1}) end,
        lists:seq(1, 200)
    ),
    tick(Pid, 1),
    [Effects] = logged(),
    %% Well under both the 200 sent and the 256-entry count cap: the byte cap is
    %% what stopped it, which is the only cap that bounds the zone's heap.
    ?assert(length(Effects) > 0),
    ?assert(length(Effects) < 100),
    gen_server:stop(Pid).

no_handler_survives() ->
    Pid = start_zone(asobi_zone_spatial_test_game),
    asobi_zone:add_entity(Pid, ~"target", #{type => ~"npc", x => 150.0, y => 150.0, hp => 100}),
    asobi_zone:apply_effect(Pid, ~"target", #{~"hp_delta" => -30}),
    tick(Pid, 1),
    ?assert(is_process_alive(Pid)),
    ?assertMatch(#{~"target" := #{hp := 100}}, asobi_zone:get_entities(Pid)),
    gen_server:stop(Pid).

zone_publishes_band() ->
    %% band = 0.1 * 100 = 10, so [100,110) is in the band for zone (1,1).
    Pid = start_zone(?MODULE),
    asobi_zone:add_entity(Pid, ~"edge", #{type => ~"npc", x => 105.0, y => 150.0}),
    asobi_zone:add_entity(Pid, ~"middle", #{type => ~"npc", x => 150.0, y => 150.0}),
    tick(Pid, 1),
    Seen = asobi_zone_border:query_radius(tab(), {0, 1}, 5, {105.0, 150.0}, 50.0),
    ?assertMatch([{~"edge", _, _}], Seen),
    gen_server:stop(Pid).

%% asobi_zone does not trap exits, so terminate/2 does not run on a supervisor
%% shutdown or a linked crash. terminate/2 alone therefore cannot be where the
%% band row is reclaimed, or a crashed zone leaves a dead entity visible to
%% every neighbour for the life of the node.
%% Nothing else in the suite pins this: every other test here would pass with
%% effects applied before inputs, or after entity timers.
effect_ordering() ->
    Pid = start_zone(asobi_zone_order_game),
    asobi_zone:add_entity(Pid, ~"t", #{
        type => ~"npc", x => 150.0, y => 150.0, trace => []
    }),
    asobi_zone:player_input(Pid, ~"p1", #{~"kind" => ~"move"}),
    asobi_zone:apply_effect(Pid, ~"t", #{~"hp_delta" => -1}),
    asobi_zone:start_entity_timer(Pid, #{
        entity_id => ~"t",
        timer_id => ~"t1",
        duration => 0,
        on_complete => #{~"type" => ~"noop"}
    }),
    tick(Pid, 1),
    #{~"t" := Entity} = asobi_zone:get_entities(Pid),
    ?assertEqual([tick, input, effect], maps:get(trace, Entity)),
    %% The timer ran after the effect: apply_timer_events/2 is fed the map
    %% handle_effects/2 returned, so the completion is on the stamped entity.
    ?assertMatch(#{~"completed_timers" := [_ | _]}, Entity),
    gen_server:stop(Pid).

band_does_not_survive_a_kill() ->
    process_flag(trap_exit, true),
    P1 = start_zone(?MODULE),
    asobi_zone:add_entity(P1, ~"edge", #{type => ~"npc", x => 105.0, y => 150.0}),
    tick(P1, 1),
    ?assertMatch(
        [_], asobi_zone_border:query_radius(tab(), {0, 1}, 5, {105.0, 150.0}, 50.0)
    ),
    exit(P1, kill),
    receive
        {'EXIT', P1, _} -> ok
    after 1000 -> error(no_exit)
    end,
    %% The ETS crash backup would otherwise hand the replacement the same entity
    %% and republish it, which would pass this test for the wrong reason.
    ets:delete(asobi_world_state, {~"effects-world", {1, 1}}),
    P2 = start_zone(?MODULE),
    tick(P2, 1),
    ?assertEqual(
        [], asobi_zone_border:query_radius(tab(), {0, 1}, 5, {105.0, 150.0}, 50.0)
    ),
    process_flag(trap_exit, false),
    gen_server:stop(P2).

bad_return_is_a_noop() ->
    Pid = start_zone(asobi_zone_effects_bad_return_game),
    asobi_zone:add_entity(Pid, ~"target", #{type => ~"npc", x => 150.0, y => 150.0, hp => 100}),
    asobi_zone:apply_effect(Pid, ~"target", #{~"hp_delta" => -30}),
    tick(Pid, 1),
    ?assert(is_process_alive(Pid)),
    ?assertMatch(#{~"target" := #{hp := 100}}, asobi_zone:get_entities(Pid)),
    gen_server:stop(Pid).

%% warm_up/1 has to fire on every message that creates work for a cold zone, not
%% just the ones a player sends: a zone that spawns from its own script or arms a
%% timer has work to do at full rate.
spawn_warms() ->
    Pid = start_zone(?MODULE),
    tick(Pid, 1),
    ?assert(is_cold(Pid)),
    asobi_zone:spawn_entities(Pid, []),
    _ = sys:get_state(Pid),
    ?assertNot(is_cold(Pid)),
    gen_server:stop(Pid).

timer_warms() ->
    Pid = start_zone(?MODULE),
    tick(Pid, 1),
    ?assert(is_cold(Pid)),
    asobi_zone:start_entity_timer(Pid, #{
        entity_id => ~"t", timer_id => ~"t1", duration => 60_000
    }),
    _ = sys:get_state(Pid),
    ?assertNot(is_cold(Pid)),
    gen_server:stop(Pid).

is_cold(Pid) ->
    case sys:get_state(Pid) of
        #{cold := Cold} -> Cold
    end.

zone_clears_band_on_stop() ->
    Pid = start_zone(?MODULE),
    asobi_zone:add_entity(Pid, ~"edge", #{type => ~"npc", x => 105.0, y => 150.0}),
    tick(Pid, 1),
    ?assertMatch(
        [_], asobi_zone_border:query_radius(tab(), {0, 1}, 5, {105.0, 150.0}, 50.0)
    ),
    gen_server:stop(Pid),
    ?assertEqual(
        [], asobi_zone_border:query_radius(tab(), {0, 1}, 5, {105.0, 150.0}, 50.0)
    ).
