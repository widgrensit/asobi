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
        {"subscriber DOWN cleans up", fun subscriber_down_cleanup/0},
        {"tick touches zone_manager when subscribers present", fun tick_touches_zone_manager/0},
        {"tick hibernates when empty", fun tick_hibernates_when_empty/0},
        {"tick does not hibernate with NPC entities", fun tick_no_hibernate_with_npcs/0}
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
