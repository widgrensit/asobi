-module(asobi_terrain_integration_tests).
-include_lib("eunit/include/eunit.hrl").

%% End-to-end: terrain provider → store → zone subscribe → player receives chunk

-define(GAME, asobi_terrain_test_game).

setup() ->
    case whereis(nova_scope) of
        undefined -> pg:start_link(nova_scope);
        _ -> ok
    end,
    meck:new(asobi_repo, [no_link, non_strict]),
    meck:expect(asobi_repo, insert, fun(_) -> {ok, #{}} end),
    meck:expect(asobi_repo, insert, fun(_, _) -> {ok, #{}} end),
    meck:new(asobi_presence, [no_link, non_strict]),
    meck:expect(asobi_presence, send, fun(_, _) -> ok end),
    meck:new(asobi_zone_snapshotter, [no_link, non_strict]),
    meck:expect(asobi_zone_snapshotter, load_snapshots, fun(_) -> {ok, #{}} end),
    meck:expect(asobi_zone_snapshotter, delete_world, fun(_) -> ok end),
    meck:expect(asobi_zone_snapshotter, snapshot_sync, fun(_) -> ok end),
    meck:expect(asobi_zone_snapshotter, snapshot, fun(_) -> ok end),
    ok.

cleanup(_) ->
    meck:unload(asobi_zone_snapshotter),
    meck:unload(asobi_presence),
    meck:unload(asobi_repo),
    ok.

world_config() ->
    #{
        game_module => ?GAME,
        grid_size => 3,
        zone_size => 100,
        tick_rate => 50,
        max_players => 10,
        view_radius => 1,
        lazy_zones => false
    }.

terrain_integration_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        {"world starts with terrain store", fun terrain_store_started/0},
        {"zone subscribe sends terrain chunk", fun terrain_chunk_on_subscribe/0},
        {"terrain chunk has correct data", fun terrain_data_correct/0}
    ]}.

terrain_store_started() ->
    {ok, InstancePid} = asobi_world_instance:start_link(world_config()),
    unlink(InstancePid),
    timer:sleep(100),
    WorldPid =
        case asobi_world_instance:get_child(InstancePid, asobi_world_server) of
            WP when is_pid(WP) -> WP
        end,
    ?assertEqual(running, maps:get(status, asobi_world_server:get_info(WorldPid))),
    catch exit(InstancePid, shutdown),
    timer:sleep(50).

terrain_chunk_on_subscribe() ->
    {ok, InstancePid} = asobi_world_instance:start_link(world_config()),
    unlink(InstancePid),
    timer:sleep(100),
    ZMPid = asobi_world_instance:get_child(InstancePid, asobi_zone_manager),
    {ok, ZonePid} = asobi_zone_manager:ensure_zone(ZMPid, {0, 0}),
    asobi_zone:subscribe(ZonePid, {~"test_player", self()}),
    Received = collect_messages(500),
    HasTerrain = lists:any(
        fun
            ({asobi_message, {terrain_chunk, {0, 0}, _}}) -> true;
            (_) -> false
        end,
        Received
    ),
    ?assert(HasTerrain),
    catch exit(InstancePid, shutdown),
    timer:sleep(50).

terrain_data_correct() ->
    {ok, InstancePid} = asobi_world_instance:start_link(world_config()),
    unlink(InstancePid),
    timer:sleep(100),
    ZMPid = asobi_world_instance:get_child(InstancePid, asobi_zone_manager),
    {ok, ZonePid} = asobi_zone_manager:ensure_zone(ZMPid, {1, 2}),
    asobi_zone:subscribe(ZonePid, {~"test_player2", self()}),
    Received = collect_messages(500),
    [{asobi_message, {terrain_chunk, {1, 2}, ChunkData}}] =
        [M || {asobi_message, {terrain_chunk, _, _}} = M <- Received],
    Tiles = asobi_terrain:decode_chunk(asobi_terrain:decompress_chunk(ChunkData)),
    %% Provider: tile_id = X + Y + Seed + 1, Seed from store config (default 0)
    %% So tile_id = 1 + 2 + 0 + 1 = 4
    ?assert(lists:member({0, 0, 4, 0, 0}, Tiles)),
    catch exit(InstancePid, shutdown),
    timer:sleep(50).

collect_messages(Timeout) ->
    collect_messages(Timeout, []).

collect_messages(Timeout, Acc) ->
    receive
        Msg -> collect_messages(Timeout, [Msg | Acc])
    after Timeout ->
        lists:reverse(Acc)
    end.
