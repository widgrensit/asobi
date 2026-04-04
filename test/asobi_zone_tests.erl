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
        {"subscriber DOWN cleans up", fun subscriber_down_cleanup/0}
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
    asobi_zone:subscribe(Pid, {<<"p1">>, self()}),
    asobi_zone:add_entity(Pid, <<"e1">>, #{x => 0, y => 0, type => ~"player"}),
    timer:sleep(10),
    %% First tick — entity appears as added
    asobi_zone:tick(Pid, 1),
    receive
        {asobi_message, {zone_delta, 1, Deltas}} ->
            ?assertEqual(1, length(Deltas)),
            [Delta] = Deltas,
            ?assertEqual(~"a", maps:get(~"op", Delta)),
            ?assertEqual(<<"e1">>, maps:get(~"id", Delta))
    after 1000 ->
        ?assert(false)
    end,
    %% Second tick — no changes, no delta message
    asobi_zone:tick(Pid, 2),
    receive
        {asobi_message, {zone_delta, 2, _}} ->
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
