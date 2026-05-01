-module(prop_input_never_dropped).
-include_lib("eunit/include/eunit.hrl").
%% Include proper after eunit so proper's ?LET/3 wins (eunit defines a 3-arg
%% ?LET internally that breaks proper's generator binding).
-undef(LET).
-include_lib("proper/include/proper.hrl").

%% PropEr: for any sequence of [join, input, ...] across N players, every
%% input that was sent eventually reaches the game module's handle_input/3
%% and bumps the per-player inputs_seen counter to a value >= sent_count.
%%
%% This is the engine-level form of the regression we just fixed: an input
%% sent immediately after a successful join must not be dropped, regardless
%% of cast/reply ordering races between WS handler, world_server, and zone.

-define(GAME, asobi_test_input_count_game).
-define(MAX_PLAYERS, 6).
-define(GRID_SIZE, 2).
-define(WAIT_TICKS_MS, 500).
-define(NUMTESTS, list_to_integer(os:getenv("PROPER_NUMTESTS", "25"))).
-define(BASE_CONFIG, #{
    game_module => ?GAME,
    grid_size => ?GRID_SIZE,
    zone_size => 100,
    tick_rate => 50,
    max_players => ?MAX_PLAYERS,
    view_radius => 1,
    empty_grace_ms => 600000,
    persistent => true
}).

input_never_dropped_test_() ->
    {setup, fun setup/0, fun cleanup/1, fun(Ctx) ->
        [
            {timeout, max(60, ?NUMTESTS div 2),
                ?_assert(
                    proper:quickcheck(prop_input_never_dropped(Ctx), [
                        {numtests, ?NUMTESTS}, {to_file, user}
                    ])
                )}
        ]
    end}.

setup() ->
    case whereis(nova_scope) of
        undefined -> pg:start(nova_scope);
        _ -> ok
    end,
    case ets:info(asobi_player_worlds) of
        undefined ->
            ets:new(asobi_player_worlds, [named_table, public, set, {read_concurrency, true}]);
        _ ->
            ets:delete_all_objects(asobi_player_worlds)
    end,
    meck:new(asobi_repo, [no_link]),
    meck:expect(asobi_repo, insert, fun(_CS) -> {ok, #{}} end),
    meck:expect(asobi_repo, insert, fun(_CS, _Opts) -> {ok, #{}} end),
    meck:new(asobi_presence, [non_strict, no_link]),
    meck:expect(asobi_presence, send, fun(_, _) -> ok end),
    start_world().

cleanup(#{instance_pid := InstancePid}) ->
    catch exit(InstancePid, shutdown),
    timer:sleep(10),
    catch meck:unload(asobi_presence),
    catch meck:unload(asobi_repo),
    ok.

%% --- Property ---

prop_input_never_dropped(Ctx) ->
    ?FORALL(
        {Players, InputsPerPlayer},
        {players_set(), input_count()},
        run_iteration(Ctx, narrow_players(Players), narrow_int(InputsPerPlayer))
    ).

-spec run_iteration(map(), [binary()], pos_integer()) -> boolean().
run_iteration(Ctx, Players, InputsPerPlayer) ->
    reset_world(Ctx),
    ok = join_all(Ctx, Players),
    ok = send_inputs(Ctx, Players, InputsPerPlayer),
    ok = wait_for_observation(Ctx, Players, InputsPerPlayer, ?WAIT_TICKS_MS),
    check_all_observed(Ctx, Players, InputsPerPlayer).

-spec narrow_players(term()) -> [binary()].
narrow_players(L) when is_list(L) -> [B || B <- L, is_binary(B)].

-spec narrow_int(term()) -> pos_integer().
narrow_int(N) when is_integer(N), N >= 1 -> N.

players_set() ->
    ?LET(
        N,
        proper_types:integer(1, ?MAX_PLAYERS),
        gen_player_ids(N)
    ).

-spec gen_player_ids(term()) -> [binary()].
gen_player_ids(N) when is_integer(N), N >= 1 ->
    [list_to_binary("p" ++ integer_to_list(I)) || I <- lists:seq(1, N)].

input_count() ->
    proper_types:integer(1, 5).

%% --- Drivers ---

-spec join_all(map(), [binary()]) -> ok.
join_all(#{world_pid := Pid}, Players) ->
    lists:foreach(
        fun(P) when is_binary(P) ->
            case asobi_world_server:join(Pid, P) of
                ok -> ok;
                {error, _} = E -> error({join_failed, P, E})
            end
        end,
        Players
    ),
    ok.

-spec send_inputs(map(), [binary()], pos_integer()) -> ok.
send_inputs(Ctx, Players, N) when is_integer(N) ->
    %% Find the zone every player landed in (all spawn at (0,0) → zone (0,0))
    ZonePid = zone_at(Ctx, {0, 0}),
    lists:foreach(
        fun(P) when is_binary(P) ->
            lists:foreach(
                fun(I) -> asobi_zone:player_input(ZonePid, P, #{<<"seq">> => I}) end,
                lists:seq(1, N)
            )
        end,
        Players
    ),
    ok.

wait_for_observation(_Ctx, _Players, _N, BudgetMs) when BudgetMs =< 0 ->
    ok;
wait_for_observation(Ctx, Players, N, BudgetMs) ->
    case all_observed(Ctx, Players, N) of
        true ->
            ok;
        false ->
            timer:sleep(20),
            wait_for_observation(Ctx, Players, N, BudgetMs - 20)
    end.

all_observed(Ctx, Players, N) ->
    Entities = entities_at(Ctx, {0, 0}),
    lists:all(
        fun(P) ->
            case maps:get(P, Entities, undefined) of
                #{inputs_seen := Seen} -> Seen >= N;
                _ -> false
            end
        end,
        Players
    ).

check_all_observed(Ctx, Players, N) ->
    Entities = entities_at(Ctx, {0, 0}),
    Result = [
        {P, maps:get(inputs_seen, maps:get(P, Entities, #{inputs_seen => 0}), 0)}
     || P <- Players
    ],
    AllOk = lists:all(fun({_, S}) -> S >= N end, Result),
    case AllOk of
        true ->
            true;
        false ->
            io:format(user, "~ninputs dropped: expected >=~p per player, got ~p~n", [N, Result]),
            false
    end.

%% --- World fixture ---

reset_world(#{world_pid := Pid}) ->
    Info = asobi_world_server:get_info(Pid),
    [asobi_world_server:leave(Pid, P) || P <- maps:get(players, Info, [])],
    timer:sleep(20),
    ok.

zone_at(#{world_pid := WorldPid}, Coords) ->
    case sys:get_state(WorldPid) of
        {_StateName, StateData} when is_map(StateData) ->
            case maps:get(zone_manager_pid, StateData) of
                ZMPid when is_pid(ZMPid) ->
                    {ok, ZP} = asobi_zone_manager:ensure_zone(ZMPid, Coords),
                    ZP
            end
    end.

entities_at(Ctx, Coords) ->
    asobi_zone:get_entities(zone_at(Ctx, Coords)).

start_world() ->
    {ok, InstancePid} = asobi_world_instance:start_link(?BASE_CONFIG),
    unlink(InstancePid),
    timer:sleep(40),
    ServerPid = asobi_world_instance:get_child(InstancePid, asobi_world_server),
    #{instance_pid => InstancePid, world_pid => ServerPid}.
