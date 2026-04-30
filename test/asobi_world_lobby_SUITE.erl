-module(asobi_world_lobby_SUITE).
-moduledoc """
Regression coverage for `asobi_world_lobby:find_or_create/1` and
`asobi_world_lobby:list_worlds/1`.

Two concurrent players asking for the same `mode` MUST land in the same
world process — if they don't, multiplayer is silently broken. These
tests pin that contract so the bug can never sneak back in unnoticed.
""".

-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1, init_per_testcase/2, end_per_testcase/2]).
-export([
    list_worlds_starts_empty/1,
    list_worlds_returns_running_world/1,
    list_worlds_filters_by_mode/1,
    list_worlds_filters_by_capacity/1,
    find_or_create_creates_when_none_exist/1,
    find_or_create_reuses_existing_world/1,
    find_or_create_creates_new_for_different_mode/1,
    find_or_create_creates_new_when_existing_full/1,
    find_or_create_concurrent_callers_share_world/1,
    create_world_player_cap_blocks_after_limit/1,
    create_world_player_cap_releases_when_world_dies/1,
    create_world_global_cap_blocks_at_max/1,
    create_world_anonymous_bypasses_player_cap/1
]).

-define(MODE_HUB, ~"test_hub").
-define(MODE_ARENA, ~"test_arena").
-define(MODE_SOLO, ~"test_solo").

all() ->
    [
        list_worlds_starts_empty,
        list_worlds_returns_running_world,
        list_worlds_filters_by_mode,
        list_worlds_filters_by_capacity,
        find_or_create_creates_when_none_exist,
        find_or_create_reuses_existing_world,
        find_or_create_creates_new_for_different_mode,
        find_or_create_creates_new_when_existing_full,
        find_or_create_concurrent_callers_share_world,
        create_world_player_cap_blocks_after_limit,
        create_world_player_cap_releases_when_world_dies,
        create_world_global_cap_blocks_at_max,
        create_world_anonymous_bypasses_player_cap
    ].

init_per_suite(Config) ->
    Config1 = asobi_test_helpers:start(Config),
    application:set_env(asobi, game_modes, #{
        ?MODE_HUB => #{
            type => world,
            module => asobi_test_world_game,
            max_players => 4,
            grid_size => 1,
            zone_size => 100,
            tick_rate => 50
        },
        ?MODE_ARENA => #{
            type => world,
            module => asobi_test_world_game,
            max_players => 4,
            grid_size => 1,
            zone_size => 100,
            tick_rate => 50
        },
        ?MODE_SOLO => #{
            type => world,
            module => asobi_test_world_game,
            max_players => 1,
            grid_size => 1,
            zone_size => 100,
            tick_rate => 50
        }
    }),
    Config1.

end_per_suite(_Config) ->
    application:unset_env(asobi, game_modes),
    ok.

init_per_testcase(_TC, Config) ->
    cleanup_worlds(),
    Config.

end_per_testcase(_TC, _Config) ->
    cleanup_worlds(),
    ok.

%% --- list_worlds ---

list_worlds_starts_empty(_Config) ->
    ?assertEqual([], asobi_world_lobby:list_worlds()),
    ?assertEqual([], asobi_world_lobby:list_worlds(#{mode => ?MODE_HUB})).

list_worlds_returns_running_world(_Config) ->
    {ok, _Pid, Info} = asobi_world_lobby:create_world(?MODE_HUB),
    WorldId = maps:get(world_id, Info),
    wait_until_running(WorldId),

    Worlds = asobi_world_lobby:list_worlds(),
    ?assertEqual(1, length(Worlds), "list_worlds() must return the running world"),
    [Listed] = Worlds,
    ?assertEqual(WorldId, maps:get(world_id, Listed)),
    ?assertEqual(running, maps:get(status, Listed)),
    ?assertEqual(?MODE_HUB, maps:get(mode, Listed)).

list_worlds_filters_by_mode(_Config) ->
    {ok, _, HubInfo} = asobi_world_lobby:create_world(?MODE_HUB),
    {ok, _, ArenaInfo} = asobi_world_lobby:create_world(?MODE_ARENA),
    wait_until_running(maps:get(world_id, HubInfo)),
    wait_until_running(maps:get(world_id, ArenaInfo)),

    [Hub] = asobi_world_lobby:list_worlds(#{mode => ?MODE_HUB}),
    [Arena] = asobi_world_lobby:list_worlds(#{mode => ?MODE_ARENA}),
    ?assertEqual(?MODE_HUB, maps:get(mode, Hub)),
    ?assertEqual(?MODE_ARENA, maps:get(mode, Arena)).

list_worlds_filters_by_capacity(_Config) ->
    {ok, Pid, Info} = asobi_world_lobby:create_world(?MODE_SOLO),
    WorldId = maps:get(world_id, Info),
    wait_until_running(WorldId),

    %% Empty world has capacity
    ?assertEqual(
        1, length(asobi_world_lobby:list_worlds(#{has_capacity => true}))
    ),
    %% Fill the world (max_players = 1)
    ok = asobi_world_server:join(Pid, ~"player1"),
    %% Now no capacity
    ?assertEqual(
        [], asobi_world_lobby:list_worlds(#{has_capacity => true})
    ),
    %% But still listed without the capacity filter
    ?assertEqual(
        1, length(asobi_world_lobby:list_worlds())
    ).

%% --- find_or_create ---

find_or_create_creates_when_none_exist(_Config) ->
    ?assertEqual([], asobi_world_lobby:list_worlds()),
    {ok, Pid, Info} = asobi_world_lobby:find_or_create(?MODE_HUB),
    ?assert(is_pid(Pid)),
    ?assertEqual(?MODE_HUB, maps:get(mode, Info)),
    ?assertEqual(1, length(asobi_world_lobby:list_worlds())).

find_or_create_reuses_existing_world(_Config) ->
    {ok, Pid1, Info1} = asobi_world_lobby:find_or_create(?MODE_HUB),
    WorldId1 = maps:get(world_id, Info1),
    wait_until_running(WorldId1),

    %% Second call MUST return the same world pid + id.
    {ok, Pid2, Info2} = asobi_world_lobby:find_or_create(?MODE_HUB),
    WorldId2 = maps:get(world_id, Info2),

    ?assertEqual(
        WorldId1,
        WorldId2,
        "find_or_create must reuse the existing hub world rather than spawning a duplicate"
    ),
    ?assertEqual(Pid1, Pid2),
    ?assertEqual(1, length(asobi_world_lobby:list_worlds())).

find_or_create_creates_new_for_different_mode(_Config) ->
    {ok, _, HubInfo} = asobi_world_lobby:find_or_create(?MODE_HUB),
    HubId = maps:get(world_id, HubInfo),
    wait_until_running(HubId),

    {ok, _, ArenaInfo} = asobi_world_lobby:find_or_create(?MODE_ARENA),
    ArenaId = maps:get(world_id, ArenaInfo),

    ?assertNotEqual(HubId, ArenaId),
    ?assertEqual(2, length(asobi_world_lobby:list_worlds())).

find_or_create_creates_new_when_existing_full(_Config) ->
    {ok, Pid1, Info1} = asobi_world_lobby:find_or_create(?MODE_SOLO),
    Id1 = maps:get(world_id, Info1),
    wait_until_running(Id1),
    %% Fill it (max_players = 1)
    ok = asobi_world_server:join(Pid1, ~"player1"),

    %% A second find_or_create must spawn a fresh solo world.
    {ok, _Pid2, Info2} = asobi_world_lobby:find_or_create(?MODE_SOLO),
    Id2 = maps:get(world_id, Info2),

    ?assertNotEqual(Id1, Id2),
    ?assertEqual(2, length(asobi_world_lobby:list_worlds())).

find_or_create_concurrent_callers_share_world(_Config) ->
    %% N parallel callers asking for the same mode at the same instant
    %% MUST all land in a single world. The pre-fix code raced: each
    %% caller saw `list_worlds = []` because no other had finished
    %% `create_world` yet, so each spawned its own world for the same
    %% mode. Customer-visible symptom: two players opening barrow at
    %% the same instant land in different hub worlds.
    %%
    %% `asobi_world_lobby_server` serializes all `find_or_create` calls
    %% through a single gen_server, so the second caller now sees the
    %% world the first one just spawned. This test pins the contract.
    Self = self(),
    N = 8,
    [
        spawn(fun() ->
            {ok, _, Info} = asobi_world_lobby:find_or_create(?MODE_HUB),
            Self ! {worker, maps:get(world_id, Info)}
        end)
     || _ <- lists:seq(1, N)
    ],
    Ids = collect_ids(N, []),
    Unique = lists:usort(Ids),
    ?assertEqual(
        1,
        length(Unique),
        lists:flatten(
            io_lib:format(
                "~p concurrent find_or_create callers landed in ~p distinct worlds; "
                "should be exactly 1 (got ids: ~p)",
                [N, length(Unique), Unique]
            )
        )
    ),
    %% Also pin the follow-up: a sequential call after the burst must
    %% reuse the same world.
    {ok, _, Info} = asobi_world_lobby:find_or_create(?MODE_HUB),
    FollowupId = maps:get(world_id, Info),
    ?assertEqual(hd(Unique), FollowupId).

%% --- F-9: per-player and global concurrent-world caps ---

create_world_player_cap_blocks_after_limit(_Config) ->
    %% Drop the per-player cap to a small number for the test.
    application:set_env(asobi, world_max_per_player, 2),
    try
        Player = ~"player_cap_test",
        {ok, _Pid1, _} = asobi_world_lobby:create_world(?MODE_HUB, Player),
        {ok, _Pid2, _} = asobi_world_lobby:create_world(?MODE_HUB, Player),
        ?assertEqual(
            {error, player_world_limit_reached},
            asobi_world_lobby:create_world(?MODE_HUB, Player)
        ),
        %% A different player must still be able to create.
        ?assertMatch(
            {ok, _, _},
            asobi_world_lobby:create_world(?MODE_HUB, ~"other_player")
        )
    after
        application:unset_env(asobi, world_max_per_player)
    end.

create_world_player_cap_releases_when_world_dies(_Config) ->
    application:set_env(asobi, world_max_per_player, 1),
    try
        Player = ~"player_release_test",
        {ok, Pid, _} = asobi_world_lobby:create_world(?MODE_HUB, Player),
        ?assertEqual(
            {error, player_world_limit_reached},
            asobi_world_lobby:create_world(?MODE_HUB, Player)
        ),
        %% Killing the world must release the slot via pg.
        Ref = monitor(process, Pid),
        exit(Pid, kill),
        receive
            {'DOWN', Ref, process, Pid, _} -> ok
        after 2000 -> ct:fail("world process did not die")
        end,
        wait_until_player_count(Player, 0, 50),
        ?assertMatch(
            {ok, _, _},
            asobi_world_lobby:create_world(?MODE_HUB, Player)
        )
    after
        application:unset_env(asobi, world_max_per_player)
    end.

create_world_global_cap_blocks_at_max(_Config) ->
    application:set_env(asobi, world_max, 1),
    try
        {ok, _Pid, _} = asobi_world_lobby:create_world(?MODE_HUB, ~"p_global_a"),
        ?assertEqual(
            {error, world_capacity_reached},
            asobi_world_lobby:create_world(?MODE_HUB, ~"p_global_b")
        ),
        %% Anonymous create also blocked by the global cap.
        ?assertEqual(
            {error, world_capacity_reached},
            asobi_world_lobby:create_world(?MODE_HUB)
        )
    after
        application:unset_env(asobi, world_max)
    end.

create_world_anonymous_bypasses_player_cap(_Config) ->
    %% Anonymous (PlayerId = undefined) creates are internal callers and
    %% should not be subject to the per-player cap. The global cap still
    %% applies and is covered above.
    application:set_env(asobi, world_max_per_player, 1),
    try
        {ok, _Pid1, _} = asobi_world_lobby:create_world(?MODE_HUB),
        {ok, _Pid2, _} = asobi_world_lobby:create_world(?MODE_HUB),
        {ok, _Pid3, _} = asobi_world_lobby:create_world(?MODE_HUB)
    after
        application:unset_env(asobi, world_max_per_player)
    end.

wait_until_player_count(_Player, _Target, 0) ->
    ct:fail("player owned-world count never reached target");
wait_until_player_count(Player, Target, N) ->
    case asobi_world_lobby:player_owned_world_count(Player) of
        Target ->
            ok;
        _ ->
            timer:sleep(20),
            wait_until_player_count(Player, Target, N - 1)
    end.

%% --- helpers ---

collect_ids(0, Acc) ->
    Acc;
collect_ids(N, Acc) ->
    receive
        {worker, Id} -> collect_ids(N - 1, [Id | Acc])
    after 5000 ->
        ct:fail("worker did not report within 5s")
    end.

cleanup_worlds() ->
    case erlang:whereis(asobi_world_instance_sup) of
        undefined ->
            ok;
        _ ->
            Children = supervisor:which_children(asobi_world_instance_sup),
            [
                supervisor:terminate_child(asobi_world_instance_sup, Pid)
             || {_, Pid, _, _} <- Children, is_pid(Pid)
            ],
            timer:sleep(20),
            ok
    end.

wait_until_running(WorldId) ->
    wait_until_running(WorldId, 50).

wait_until_running(_WorldId, 0) ->
    ct:fail("world never reached running state");
wait_until_running(WorldId, N) ->
    case asobi_world_server:whereis(WorldId) of
        {ok, Pid} ->
            case asobi_world_server:get_info(Pid) of
                #{status := running} ->
                    ok;
                _ ->
                    timer:sleep(20),
                    wait_until_running(WorldId, N - 1)
            end;
        error ->
            timer:sleep(20),
            wait_until_running(WorldId, N - 1)
    end.
