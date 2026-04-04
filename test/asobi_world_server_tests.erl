-module(asobi_world_server_tests).
-include_lib("eunit/include/eunit.hrl").

-define(GAME, asobi_test_world_game).
-define(BASE_CONFIG, #{
    game_module => ?GAME,
    grid_size => 2,
    zone_size => 100,
    tick_rate => 50,
    max_players => 10,
    view_radius => 1
}).

setup() ->
    case whereis(nova_scope) of
        undefined -> pg:start_link(nova_scope);
        _ -> ok
    end,
    meck:new(asobi_repo, [no_link]),
    meck:expect(asobi_repo, insert, fun(_CS) -> {ok, #{}} end),
    meck:expect(asobi_repo, insert, fun(_CS, _Opts) -> {ok, #{}} end),
    meck:new(asobi_presence, [non_strict, no_link]),
    meck:expect(asobi_presence, send, fun(_PlayerId, _Msg) -> ok end),
    ok.

cleanup(_) ->
    meck:unload(asobi_presence),
    meck:unload(asobi_repo),
    ok.

start_world() ->
    start_world(#{}).

start_world(Overrides) ->
    {ok, ZoneSupPid} = asobi_zone_sup:start_link(),
    unlink(ZoneSupPid),
    TickerConfig = #{tick_rate => 50},
    {ok, TickerPid} = asobi_world_ticker:start_link(TickerConfig),
    unlink(TickerPid),
    Config = maps:merge(?BASE_CONFIG, Overrides),
    FullConfig = Config#{
        zone_sup_pid => ZoneSupPid,
        ticker_pid => TickerPid
    },
    {ok, Pid} = asobi_world_server:start_link(FullConfig),
    unlink(Pid),
    %% Give time for loading -> running transition
    timer:sleep(20),
    #{world_pid => Pid, zone_sup_pid => ZoneSupPid, ticker_pid => TickerPid}.

stop_world(#{world_pid := Pid, zone_sup_pid := ZSPid, ticker_pid := TPid}) ->
    catch gen_statem:stop(Pid, normal, 5000),
    catch gen_server:stop(TPid, normal, 5000),
    catch exit(ZSPid, shutdown),
    timer:sleep(10),
    ok.

world_server_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        {"starts and transitions to running", fun starts_running/0},
        {"spawns correct number of zones", fun spawns_zones/0},
        {"join adds player to world", fun join_player/0},
        {"join rejects when full", fun join_rejects_full/0},
        {"leave removes player", fun leave_player/0},
        {timeout, 15, {"leave last player finishes world", fun leave_last_finishes/0}},
        {"get_info returns world metadata", fun get_info/0},
        {timeout, 15, {"cancel finishes world", fun cancel_world/0}},
        {"whereis finds world by id", fun whereis_world/0}
    ]}.

starts_running() ->
    Ctx = start_world(),
    Info = asobi_world_server:get_info(maps:get(world_pid, Ctx)),
    ?assertEqual(running, maps:get(status, Info)),
    stop_world(Ctx).

spawns_zones() ->
    Ctx = start_world(#{grid_size => 3}),
    %% 3x3 grid = 9 zones
    Info = asobi_world_server:get_info(maps:get(world_pid, Ctx)),
    ?assertEqual(3, maps:get(grid_size, Info)),
    stop_world(Ctx).

join_player() ->
    Ctx = start_world(),
    Pid = maps:get(world_pid, Ctx),
    ?assertEqual(ok, asobi_world_server:join(Pid, <<"p1">>)),
    Info = asobi_world_server:get_info(Pid),
    ?assertEqual(1, maps:get(player_count, Info)),
    ?assert(lists:member(<<"p1">>, maps:get(players, Info))),
    stop_world(Ctx).

join_rejects_full() ->
    Ctx = start_world(#{max_players => 1}),
    Pid = maps:get(world_pid, Ctx),
    ?assertEqual(ok, asobi_world_server:join(Pid, <<"p1">>)),
    ?assertEqual({error, world_full}, asobi_world_server:join(Pid, <<"p2">>)),
    stop_world(Ctx).

leave_player() ->
    Ctx = start_world(),
    Pid = maps:get(world_pid, Ctx),
    asobi_world_server:join(Pid, <<"p1">>),
    asobi_world_server:join(Pid, <<"p2">>),
    asobi_world_server:leave(Pid, <<"p1">>),
    timer:sleep(20),
    Info = asobi_world_server:get_info(Pid),
    ?assertEqual(1, maps:get(player_count, Info)),
    stop_world(Ctx).

leave_last_finishes() ->
    Ctx = #{world_pid := Pid} = start_world(),
    MonRef = monitor(process, Pid),
    asobi_world_server:join(Pid, <<"p1">>),
    asobi_world_server:leave(Pid, <<"p1">>),
    receive
        {'DOWN', MonRef, process, Pid, _} -> ok
    after 10000 ->
        stop_world(Ctx),
        ?assert(false)
    end.

get_info() ->
    Ctx = start_world(),
    Pid = maps:get(world_pid, Ctx),
    Info = asobi_world_server:get_info(Pid),
    ?assert(maps:is_key(world_id, Info)),
    ?assert(maps:is_key(status, Info)),
    ?assert(maps:is_key(player_count, Info)),
    ?assert(maps:is_key(grid_size, Info)),
    stop_world(Ctx).

cancel_world() ->
    Ctx = start_world(),
    Pid = maps:get(world_pid, Ctx),
    MonRef = monitor(process, Pid),
    asobi_world_server:cancel(Pid),
    receive
        {'DOWN', MonRef, process, Pid, _} -> ok
    after 10000 ->
        ?assert(false)
    end.

whereis_world() ->
    Ctx = start_world(),
    Pid = maps:get(world_pid, Ctx),
    Info = asobi_world_server:get_info(Pid),
    WorldId = maps:get(world_id, Info),
    ?assertEqual({ok, Pid}, asobi_world_server:whereis(WorldId)),
    stop_world(Ctx).
