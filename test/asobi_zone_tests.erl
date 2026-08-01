-module(asobi_zone_tests).
-include_lib("eunit/include/eunit.hrl").

-define(GAME, asobi_test_world_game).

setup() ->
    case whereis(nova_scope) of
        undefined -> pg:start_link(nova_scope);
        _ -> ok
    end,
    ok.

cleanup(_) ->
    ok.

start_zone() ->
    start_zone(#{}).

start_zone(Overrides) ->
    Config = maps:merge(
        #{
            world_id => <<"test_world">>,
            coords => {0, 0},
            ticker_pid => self(),
            game_module => ?GAME,
            zone_state => #{}
        },
        Overrides
    ),
    {ok, Pid} = asobi_zone:start_link(Config),
    Pid.

zone_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        {"starts empty", fun starts_empty/0},
        {"add and remove entities", fun add_remove_entities/0},
        {"subscribe and unsubscribe", fun subscribe_unsubscribe/0},
        {"tick processes inputs and broadcasts deltas", fun tick_broadcasts/0},
        {"tick with no changes sends no deltas", fun tick_no_changes/0},
        {"tick acks to ticker", fun tick_acks/0},
        {"queued inputs apply in arrival order", fun inputs_apply_in_arrival_order/0},
        {"subscriber DOWN cleans up", fun subscriber_down_cleanup/0},
        {"tick touches zone_manager when subscribers present", fun tick_touches_zone_manager/0},
        {"tick hibernates when empty", fun tick_hibernates_when_empty/0},
        {"tick does not hibernate with NPC entities", fun tick_no_hibernate_with_npcs/0},
        {"spawn_entity with a known template creates the entity",
            fun spawn_entity_known_template/0},
        {"spawn_entity with an unknown template logs and emits telemetry, spawns nothing",
            fun spawn_entity_unknown_template_observable/0},
        {"spawn_entity bounds an over-long template_id before it is observable",
            fun spawn_entity_long_template_id_bounded/0},
        {"spawn_entity keeps a multibyte template_id valid UTF-8 when bounding",
            fun spawn_entity_multibyte_template_id_stays_utf8/0},
        {"spawn_templates_hint updates a live zone's spawnable templates",
            fun spawn_templates_hint_updates_live_zone/0},
        {"spawn_templates_hint returning garbage logs a warning and survives",
            fun spawn_templates_hint_malformed_return_is_observable/0}
    ]}.

starts_empty() ->
    Pid = start_zone(),
    ?assertEqual(#{}, asobi_zone:get_entities(Pid)),
    ?assertEqual(0, asobi_zone:get_subscriber_count(Pid)),
    gen_server:stop(Pid).

add_remove_entities() ->
    Pid = start_zone(),
    asobi_zone:add_entity(Pid, <<"e1">>, #{x => 10, y => 20}),
    timer:sleep(10),
    ?assertEqual(#{<<"e1">> => #{x => 10, y => 20}}, asobi_zone:get_entities(Pid)),
    asobi_zone:remove_entity(Pid, <<"e1">>),
    timer:sleep(10),
    ?assertEqual(#{}, asobi_zone:get_entities(Pid)),
    gen_server:stop(Pid).

spawn_entity_known_template() ->
    Pid = start_zone(#{
        spawn_templates => #{
            ~"cube" => #{type => ~"object", base_state => #{~"solid" => true}}
        }
    }),
    asobi_zone:spawn_entity(Pid, ~"cube", {10, 20}),
    timer:sleep(10),
    Entities = asobi_zone:get_entities(Pid),
    ?assertEqual(1, map_size(Entities)),
    [Entity] = maps:values(Entities),
    ?assertEqual(~"object", maps:get(type, Entity)),
    gen_server:stop(Pid).

%% asobi#247: an unresolvable template_id must be observable (log +
%% telemetry), not silently dropped - the game.zone.spawn caller has no
%% synchronous way to learn a cast failed, so this is the only signal.
spawn_entity_unknown_template_observable() ->
    Self = self(),
    Ref = make_ref(),
    {ok, _} = application:ensure_all_started(telemetry),
    telemetry:attach(
        Ref, [asobi, error], fun(_E, _M, Meta, _) -> Self ! {ev, Meta} end, []
    ),
    Pid = start_zone(#{spawn_templates => #{}}),
    try
        asobi_zone:spawn_entity(Pid, ~"nonexistent", {10, 20}),
        timer:sleep(10),
        ?assertEqual(#{}, asobi_zone:get_entities(Pid)),
        receive
            {ev, #{kind := unknown_spawn_template, details := D}} ->
                ?assertEqual(~"nonexistent", maps:get(template_id, D))
        after 1000 -> ?assert(false, timeout_waiting_for_unknown_spawn_template_event)
        end
    after
        telemetry:detach(Ref),
        gen_server:stop(Pid)
    end.

spawn_entity_long_template_id_bounded() ->
    Self = self(),
    Ref = make_ref(),
    {ok, _} = application:ensure_all_started(telemetry),
    telemetry:attach(
        Ref, [asobi, error], fun(_E, _M, Meta, _) -> Self ! {ev, Meta} end, []
    ),
    Long = binary:copy(~"a", 200),
    Pid = start_zone(#{spawn_templates => #{}}),
    try
        asobi_zone:spawn_entity(Pid, Long, {10, 20}),
        receive
            {ev, #{kind := unknown_spawn_template, details := D}} ->
                Id = maps:get(template_id, D),
                ?assertEqual(64, byte_size(Id)),
                ?assertEqual(binary:part(Long, 0, 64), Id)
        after 1000 -> ?assert(false, timeout_waiting_for_bounded_template_id)
        end
    after
        telemetry:detach(Ref),
        gen_server:stop(Pid)
    end.

%% A 64-byte cut lands mid-codepoint here; the details map is exported verbatim
%% to handlers that JSON-encode it, so it must stay valid UTF-8.
spawn_entity_multibyte_template_id_stays_utf8() ->
    Self = self(),
    Ref = make_ref(),
    {ok, _} = application:ensure_all_started(telemetry),
    telemetry:attach(
        Ref, [asobi, error], fun(_E, _M, Meta, _) -> Self ! {ev, Meta} end, []
    ),
    Split = <<(binary:copy(~"a", 63))/binary, "å"/utf8>>,
    Pid = start_zone(#{spawn_templates => #{}}),
    try
        asobi_zone:spawn_entity(Pid, Split, {10, 20}),
        receive
            {ev, #{kind := unknown_spawn_template, details := D}} ->
                Id = maps:get(template_id, D),
                ?assert(byte_size(Id) =< 64),
                ?assert(is_binary(unicode:characters_to_binary(Id))),
                _ = json:encode(#{~"template_id" => Id})
        after 1000 -> ?assert(false, timeout_waiting_for_utf8_safe_template_id)
        end
    after
        telemetry:detach(Ref),
        gen_server:stop(Pid)
    end.

subscribe_unsubscribe() ->
    Pid = start_zone(),
    asobi_zone:subscribe(Pid, {<<"p1">>, self()}),
    timer:sleep(10),
    ?assertEqual(1, asobi_zone:get_subscriber_count(Pid)),
    asobi_zone:unsubscribe(Pid, <<"p1">>),
    timer:sleep(10),
    ?assertEqual(0, asobi_zone:get_subscriber_count(Pid)),
    gen_server:stop(Pid).

tick_broadcasts() ->
    Pid = start_zone(),
    asobi_zone:add_entity(Pid, <<"e1">>, #{x => 0, y => 0, type => ~"player"}),
    timer:sleep(10),
    asobi_zone:subscribe(Pid, {<<"p1">>, self()}),
    timer:sleep(10),
    %% Subscribe sends immediate snapshot
    receive
        {asobi_message, {zone_delta, 0, Snapshot}} ->
            ?assertEqual(1, length(Snapshot)),
            [S] = Snapshot,
            ?assertEqual(~"a", maps:get(~"op", S)),
            ?assertEqual(<<"e1">>, maps:get(~"id", S))
    after 1000 ->
        ?assert(false)
    end,
    %% Broadcast interval is 3, so tick 3 broadcasts
    asobi_zone:tick(Pid, 1),
    asobi_zone:tick(Pid, 2),
    asobi_zone:tick(Pid, 3),
    receive
        {asobi_message, {zone_delta_raw, Bin}} when is_binary(Bin) ->
            #{~"type" := ~"world.tick", ~"payload" := #{~"tick" := 3}} = json:decode(Bin),
            ok
    after 1000 ->
        ?assert(false)
    end,
    %% Tick 4 does not broadcast (4 rem 3 = 1)
    asobi_zone:tick(Pid, 4),
    receive
        {asobi_message, {zone_delta_raw, _}} ->
            ?assert(false)
    after 100 ->
        ok
    end,
    gen_server:stop(Pid).

inputs_apply_in_arrival_order() ->
    %% Regression: when several player_input casts arrive between two
    %% ticks they used to be processed newest-first, so the OLDEST x
    %% won and every later move was overwritten. Assert the newest
    %% input wins instead.
    Pid = start_zone(),
    asobi_zone:add_entity(Pid, <<"p1">>, #{x => 0, y => 0, type => ~"player"}),
    timer:sleep(10),
    [
        asobi_zone:player_input(Pid, <<"p1">>, #{
            ~"action" => ~"move", ~"x" => X, ~"y" => 100
        })
     || X <- [10, 20, 30, 40, 50]
    ],
    asobi_zone:tick(Pid, 1),
    timer:sleep(20),
    Entities = asobi_zone:get_entities(Pid),
    ?assertMatch(#{x := 50, y := 100}, maps:get(<<"p1">>, Entities)),
    gen_server:stop(Pid).

tick_no_changes() ->
    Pid = start_zone(),
    asobi_zone:subscribe(Pid, {<<"p1">>, self()}),
    timer:sleep(10),
    asobi_zone:tick(Pid, 1),
    receive
        {asobi_message, {zone_delta, 1, _}} ->
            ?assert(false);
        {asobi_message, {zone_delta_raw, _}} ->
            ?assert(false)
    after 100 ->
        ok
    end,
    gen_server:stop(Pid).

tick_acks() ->
    Pid = start_zone(),
    timer:sleep(10),
    asobi_zone:tick(Pid, 1),
    receive
        {'$gen_cast', {tick_done, Pid, 1}} ->
            ok
    after 1000 ->
        ?assert(false)
    end,
    gen_server:stop(Pid).

subscriber_down_cleanup() ->
    Pid = start_zone(),
    SubPid = spawn(fun() ->
        receive
            stop -> ok
        end
    end),
    asobi_zone:subscribe(Pid, {<<"p1">>, SubPid}),
    timer:sleep(10),
    ?assertEqual(1, asobi_zone:get_subscriber_count(Pid)),
    exit(SubPid, kill),
    timer:sleep(50),
    ?assertEqual(0, asobi_zone:get_subscriber_count(Pid)),
    gen_server:stop(Pid).

tick_touches_zone_manager() ->
    ZMPid = start_mock_zone_manager(),
    Pid = start_zone(#{zone_manager_pid => ZMPid}),
    asobi_zone:subscribe(Pid, {<<"p1">>, self()}),
    flush_messages(),
    timer:sleep(10),
    asobi_zone:tick(Pid, 1),
    timer:sleep(50),
    ZMPid ! {get_touches, self()},
    receive
        {touches, Touches} ->
            ?assert(length(Touches) > 0),
            ?assertEqual({0, 0}, hd(Touches))
    after 1000 ->
        ?assert(false)
    end,
    gen_server:stop(Pid),
    ZMPid ! stop.

tick_hibernates_when_empty() ->
    Pid = start_zone(),
    asobi_zone:tick(Pid, 1),
    timer:sleep(50),
    {current_function, {Mod, Fun, _}} = erlang:process_info(Pid, current_function),
    HibernateStr = atom_to_list(Fun),
    ?assert(
        string:find(HibernateStr, "hibernate") =/= nomatch,
        lists:flatten(io_lib:format("expected hibernate, got ~p:~p", [Mod, Fun]))
    ),
    gen_server:stop(Pid).

tick_no_hibernate_with_npcs() ->
    Pid = start_zone(),
    asobi_zone:add_entity(Pid, <<"npc1">>, #{type => ~"npc", x => 0, y => 0}),
    timer:sleep(10),
    asobi_zone:tick(Pid, 1),
    timer:sleep(50),
    {current_function, CF} = erlang:process_info(Pid, current_function),
    ?assertNotEqual({erlang, hibernate, 3}, CF),
    gen_server:stop(Pid).

%% asobi#253: spawn_templates/1 is only ever called once, at zone creation -
%% a template added by a later script hot-reload never reached an
%% already-running zone. spawn_templates_hint/1 is the fix: an optional,
%% per-tick, cheap "did templates change" callback. asobi_test_world_game
%% doesn't export it normally (verified: it's absent from
%% -export([init/1, join/2, ...])), so injecting it via meck's non_strict
%% mode - the same technique already used for phases/1 in
%% asobi_world_server_tests.erl - both proves the callback is genuinely
%% optional (erlang:function_exported/3 must see it appear) and lets this
%% test control exactly when a "change" is reported.
spawn_templates_hint_updates_live_zone() ->
    Pid = start_zone(#{spawn_templates => #{}}),
    meck:new(?GAME, [passthrough, non_strict]),
    meck:expect(?GAME, spawn_templates_hint, fun(_ZoneState) ->
        {changed, #{~"goblin" => #{type => ~"npc", base_state => #{}}}}
    end),
    try
        %% Before the hint has run: the template is genuinely unknown.
        asobi_zone:spawn_entity(Pid, ~"goblin", {5, 5}),
        timer:sleep(10),
        ?assertEqual(#{}, asobi_zone:get_entities(Pid)),
        %% A tick applies the hint's {changed, _} result to the live spawner.
        asobi_zone:tick(Pid, 1),
        timer:sleep(10),
        %% The same template_id that failed above now spawns.
        asobi_zone:spawn_entity(Pid, ~"goblin", {5, 5}),
        timer:sleep(10),
        Entities = asobi_zone:get_entities(Pid),
        ?assertEqual(1, map_size(Entities)),
        [Entity] = maps:values(Entities),
        ?assertEqual(~"npc", maps:get(type, Entity))
    after
        meck:unload(?GAME),
        gen_server:stop(Pid)
    end.

%% asobi#253 code review: a callback return that's neither `unchanged` nor a
%% well-formed `{changed, Map}` is a bug in the game module, not a normal
%% "nothing changed" outcome. It must be observable (logged) and must not
%% touch the spawner's existing templates - not silently swallowed like the
%% expected `unchanged` case.
spawn_templates_hint_malformed_return_is_observable() ->
    Pid = start_zone(#{
        spawn_templates => #{~"cube" => #{type => ~"object", base_state => #{}}}
    }),
    meck:new(?GAME, [passthrough, non_strict]),
    meck:expect(?GAME, spawn_templates_hint, fun(_ZoneState) -> not_a_valid_hint_return end),
    try
        asobi_zone:tick(Pid, 1),
        timer:sleep(10),
        ?assert(is_process_alive(Pid)),
        %% The existing template survives untouched - the malformed return
        %% must not have reached asobi_zone_spawner:set_templates/2.
        asobi_zone:spawn_entity(Pid, ~"cube", {1, 1}),
        timer:sleep(10),
        ?assertEqual(1, map_size(asobi_zone:get_entities(Pid)))
    after
        meck:unload(?GAME),
        gen_server:stop(Pid)
    end.

start_mock_zone_manager() ->
    spawn(fun() -> mock_zm_loop([]) end).

mock_zm_loop(Touches) ->
    receive
        {'$gen_cast', {touch_zone, Coords}} ->
            mock_zm_loop([Coords | Touches]);
        {get_touches, From} ->
            From ! {touches, Touches},
            mock_zm_loop(Touches);
        stop ->
            ok
    end.

flush_messages() ->
    receive
        _ -> flush_messages()
    after 0 -> ok
    end.
