-module(prop_zone_invariants).
-include_lib("proper/include/proper.hrl").
%% NB: include order matters — proper's LET/4 conflicts with eunit's LET if eunit
%% is included after. Bring proper in first, then re-include eunit for the
%% ?_assert wrapper used by rebar3 eunit's auto-discovery.
-undef(LET).
-include_lib("eunit/include/eunit.hrl").

%% PropEr: random sequences of join/leave/move/reconnect on a single
%% asobi_world_server preserve these invariants:
%%   - player_count from get_info equals the number of currently-joined players.
%%   - Every joined player appears in get_info's `players` list exactly once.
%%   - Every previously-left player no longer appears.
%%   - get_info `player_count` is bounded above by max_players.

-define(GAME, asobi_test_world_game).
-define(MAX_PLAYERS, 8).
-define(GRID_SIZE, 2).
-define(NUMTESTS, list_to_integer(os:getenv("PROPER_NUMTESTS", "25"))).
-define(BASE_CONFIG, #{
    game_module => ?GAME,
    grid_size => ?GRID_SIZE,
    zone_size => 100,
    tick_rate => 50,
    max_players => ?MAX_PLAYERS,
    view_radius => 1,
    %% Keep the world alive across iterations even when reset_world drains all
    %% players. With empty_grace_ms=0 (default), the world auto-finishes the
    %% moment the last player leaves and subsequent joins time out.
    empty_grace_ms => 600000,
    persistent => true
}).

zone_invariants_test_() ->
    {setup, fun setup/0, fun cleanup/1, fun(Ctx) ->
        [
            {timeout, max(60, ?NUMTESTS div 2),
                ?_assert(
                    proper:quickcheck(prop_zone_invariants(Ctx), [
                        {numtests, ?NUMTESTS}, {to_file, user}
                    ])
                )}
        ]
    end}.

setup() ->
    %% Use pg:start (not start_link) so pg outlives the setup process —
    %% the world supervisor itself is unlinked, but its init pg:join calls
    %% will fail if pg dies between setup and test body.
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
    meck:expect(asobi_presence, send, fun(_PlayerId, _Msg) -> ok end),
    start_world().

cleanup(#{instance_pid := InstancePid}) ->
    catch exit(InstancePid, shutdown),
    timer:sleep(10),
    catch meck:unload(asobi_presence),
    catch meck:unload(asobi_repo),
    ok.

%% --- Property ---

%% Shared world across iterations: setup/0 starts it once, cleanup/1 stops it
%% once. Each iteration resets by leaving any players still joined.
prop_zone_invariants(Ctx) ->
    ?FORALL(
        Cmds,
        command_seq(),
        run_iteration(Ctx, narrow_cmds(Cmds))
    ).

-spec run_iteration(map(), [term()]) -> boolean().
run_iteration(Ctx, Cmds) ->
    reset_world(Ctx),
    Final = lists:foldl(fun(C, S) -> step(C, Ctx, S) end, init_state(), Cmds),
    check_invariants(Ctx, Final).

-spec narrow_cmds(term()) -> [term()].
narrow_cmds(L) when is_list(L) -> L.

reset_world(#{world_pid := Pid}) ->
    Info = asobi_world_server:get_info(Pid),
    [asobi_world_server:leave(Pid, P) || P <- maps:get(players, Info, [])],
    timer:sleep(20),
    ok.

%% --- Command generator ---

command_seq() ->
    proper_types:list(command()).

command() ->
    proper_types:oneof([
        {join, player_id()},
        {leave, player_id()},
        {move, player_id(), pos()}
    ]).

%% Bounded universe so commands actually overlap (~?MAX_PLAYERS distinct players).
player_id() ->
    proper_types:elements([
        <<"p1">>,
        <<"p2">>,
        <<"p3">>,
        <<"p4">>,
        <<"p5">>,
        <<"p6">>,
        <<"p7">>,
        <<"p8">>
    ]).

pos() ->
    {proper_types:integer(0, ?GRID_SIZE * 100 - 1), proper_types:integer(0, ?GRID_SIZE * 100 - 1)}.

%% --- Model + step ---

init_state() ->
    #{joined => sets:new(), max => ?MAX_PLAYERS}.

step({join, P}, #{world_pid := Pid}, #{joined := J, max := Max} = S) ->
    case sets:size(J) >= Max orelse sets:is_element(P, J) of
        true ->
            _ = asobi_world_server:join(Pid, P),
            S;
        false ->
            case asobi_world_server:join(Pid, P) of
                ok -> S#{joined => sets:add_element(P, J)};
                {error, _} -> S
            end
    end;
step({leave, P}, #{world_pid := Pid}, #{joined := J} = S) ->
    case sets:is_element(P, J) of
        true ->
            asobi_world_server:leave(Pid, P),
            timer:sleep(5),
            S#{joined => sets:del_element(P, J)};
        false ->
            S
    end;
step({move, P, NewPos}, #{world_pid := Pid}, #{joined := J} = S) ->
    case sets:is_element(P, J) of
        true ->
            asobi_world_server:move_player(Pid, P, NewPos),
            timer:sleep(2),
            S;
        false ->
            S
    end.

%% --- Invariant check ---

check_invariants(#{world_pid := Pid}, #{joined := J}) ->
    %% Drain pending casts.
    timer:sleep(20),
    Info = asobi_world_server:get_info(Pid),
    Expected = sets:to_list(J),
    Actual = lists:sort(maps:get(players, Info, [])),
    ExpectedSorted = lists:sort(Expected),
    PlayerCount = maps:get(player_count, Info, -1),
    ExpectedCount = length(Expected),
    case {PlayerCount =:= ExpectedCount, Actual =:= ExpectedSorted} of
        {true, true} ->
            true;
        Other ->
            io:format(
                user,
                "~ninvariant violated: ~p~n  expected players=~p count=~p~n  actual   players=~p count=~p~n",
                [Other, ExpectedSorted, ExpectedCount, Actual, PlayerCount]
            ),
            false
    end.

%% --- Fixture ---

start_world() ->
    {ok, InstancePid} = asobi_world_instance:start_link(?BASE_CONFIG),
    unlink(InstancePid),
    timer:sleep(40),
    ServerPid = asobi_world_instance:get_child(InstancePid, asobi_world_server),
    #{instance_pid => InstancePid, world_pid => ServerPid}.
