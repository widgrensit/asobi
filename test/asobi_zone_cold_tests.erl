-module(asobi_zone_cold_tests).
-include_lib("eunit/include/eunit.hrl").

%% widgrensit/asobi#543: a zone with nothing to simulate should stop paying the
%% full per-tick cost. These assert the classification and, more importantly,
%% the two directions of the transition - a zone that never promotes again is a
%% zone that stops responding to players.

-export([zone_tick/2, handle_input/3]).

zone_tick(E, ZS) -> {E, ZS}.
handle_input(_P, _I, E) -> {ok, E}.

setup() ->
    case ets:info(asobi_world_state) of
        undefined -> ets:new(asobi_world_state, [named_table, public, set]);
        _ -> ok
    end,
    case pg:start(nova_scope) of
        {ok, _} -> ok;
        {error, {already_started, _}} -> ok
    end,
    ok.

start_zone() ->
    {ok, Pid} = asobi_zone:start_link(#{
        world_id => ~"cold-world",
        coords => {1, 1},
        ticker_pid => self(),
        zone_size => 100,
        grid_size => 5,
        game_module => ?MODULE
    }),
    Pid.

tick(Pid, N) ->
    asobi_zone:tick(Pid, N),
    _ = sys:get_state(Pid),
    ok.

is_cold(Pid) ->
    case sys:get_state(Pid) of
        #{cold := Cold} -> Cold
    end.

%% The zone casts promote/demote at its ticker_pid, which is this process.
drain_ticker_casts() ->
    receive
        {'$gen_cast', {promote_zone, _}} -> [promote | drain_ticker_casts()];
        {'$gen_cast', {demote_zone, _}} -> [demote | drain_ticker_casts()];
        {'$gen_cast', {tick_done, _, _}} -> drain_ticker_casts()
    after 0 -> []
    end.

cold_test_() ->
    {foreach, fun setup/0, fun(_) -> ok end, [
        {"a zone starts hot", fun starts_hot/0},
        {"an empty zone goes cold on its first tick", fun empties_go_cold/0},
        {"going cold is announced once", fun demote_announced_once/0},
        {"an entity warms the zone before its next tick", fun entity_warms/0},
        {"an input warms the zone before its next tick", fun input_warms/0},
        {"an effect warms the zone", fun effect_warms/0},
        {"an occupied zone stays hot", fun occupied_stays_hot/0},
        {"a subscriber alone does not keep a zone hot", fun subscriber_does_not_warm/0},
        {"going cold and warming again are each announced once", fun transitions_emit_telemetry/0}
    ]}.

%% An operator watching a world needs to see a zone stop simulating - a zone
%% that goes cold and never comes back is one that has stopped responding to the
%% players in it, and before this there was no signal for it at all.
transitions_emit_telemetry() ->
    {ok, _} = application:ensure_all_started(telemetry),
    Ref = make_ref(),
    Self = self(),
    ok = telemetry:attach_many(
        {?MODULE, Ref},
        [[asobi, zone, cold], [asobi, zone, hot]],
        fun(Event, _Measure, Meta, _) -> Self ! {telemetry, Event, Meta} end,
        []
    ),
    try
        Pid = start_zone(),
        tick(Pid, 1),
        ?assertEqual(
            {[asobi, zone, cold], {1, 1}}, next_event()
        ),
        %% A second idle tick must not re-announce: this is a transition, not a
        %% state, or a large empty world emits one event per zone per tick.
        tick(Pid, 2),
        asobi_zone:add_entity(Pid, ~"npc", #{type => ~"npc", x => 150.0, y => 150.0}),
        _ = sys:get_state(Pid),
        ?assertEqual({[asobi, zone, hot], {1, 1}}, next_event()),
        gen_server:stop(Pid)
    after
        telemetry:detach({?MODULE, Ref})
    end.

next_event() ->
    receive
        {telemetry, Event, #{coords := Coords}} -> {Event, Coords}
    after 1000 -> timeout
    end.

starts_hot() ->
    Pid = start_zone(),
    ?assertNot(is_cold(Pid)),
    gen_server:stop(Pid).

empties_go_cold() ->
    Pid = start_zone(),
    tick(Pid, 1),
    ?assert(is_cold(Pid)),
    gen_server:stop(Pid).

demote_announced_once() ->
    Pid = start_zone(),
    tick(Pid, 1),
    ?assertEqual([demote], drain_ticker_casts()),
    tick(Pid, 2),
    tick(Pid, 3),
    ?assertEqual([], drain_ticker_casts()),
    gen_server:stop(Pid).

entity_warms() ->
    Pid = start_zone(),
    tick(Pid, 1),
    _ = drain_ticker_casts(),
    ?assert(is_cold(Pid)),
    %% Promotion must happen on the message that created the work, not on the
    %% zone's own next tick - a cold zone ticks once every cold_tick_divisor
    %% ticks, so waiting would put that whole divisor of latency on entering a
    %% zone.
    asobi_zone:add_entity(Pid, ~"npc", #{type => ~"npc", x => 150.0, y => 150.0}),
    _ = sys:get_state(Pid),
    ?assertNot(is_cold(Pid)),
    ?assertEqual([promote], drain_ticker_casts()),
    gen_server:stop(Pid).

input_warms() ->
    Pid = start_zone(),
    tick(Pid, 1),
    _ = drain_ticker_casts(),
    asobi_zone:player_input(Pid, ~"p1", #{~"kind" => ~"move"}),
    _ = sys:get_state(Pid),
    ?assertNot(is_cold(Pid)),
    ?assertEqual([promote], drain_ticker_casts()),
    gen_server:stop(Pid).

effect_warms() ->
    Pid = start_zone(),
    tick(Pid, 1),
    _ = drain_ticker_casts(),
    asobi_zone:apply_effect(Pid, ~"someone", #{~"hp_delta" => -1}),
    _ = sys:get_state(Pid),
    ?assertNot(is_cold(Pid)),
    ?assertEqual([promote], drain_ticker_casts()),
    gen_server:stop(Pid).

occupied_stays_hot() ->
    Pid = start_zone(),
    asobi_zone:add_entity(Pid, ~"npc", #{type => ~"npc", x => 150.0, y => 150.0}),
    tick(Pid, 1),
    tick(Pid, 2),
    ?assertNot(is_cold(Pid)),
    %% Not merely "the flag stayed false": reclassify/1 must take its no-op
    %% branch rather than cast promote on every one of the world's ticks.
    ?assertEqual([], drain_ticker_casts()),
    gen_server:stop(Pid).

subscriber_does_not_warm() ->
    %% This is the "watched but empty" case #543 asks about: a pilot in a
    %% neighbouring zone subscribes to this one, but there is nothing here to
    %% simulate and nothing to send, so it does not need a full-rate tick.
    Pid = start_zone(),
    Player = spawn(fun() ->
        receive
            stop -> ok
        end
    end),
    asobi_zone:subscribe(Pid, {~"p1", Player}),
    _ = sys:get_state(Pid),
    tick(Pid, 1),
    ?assert(is_cold(Pid)),
    Player ! stop,
    gen_server:stop(Pid).
