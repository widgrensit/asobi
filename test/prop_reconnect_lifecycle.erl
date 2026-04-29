-module(prop_reconnect_lifecycle).
-include_lib("eunit/include/eunit.hrl").
-undef(LET).
-include_lib("proper/include/proper.hrl").

%% PropEr: random sequences of join / disconnect / reconnect against a
%% world configured with `player_ttl_ms`. Invariants:
%%
%%   - A reconnect within the grace window leaves the player visible
%%     (player_count stays at the model's joined count).
%%   - A reconnect after a successful disconnect+reconnect cycle is
%%     idempotent (no double-bump of player_count).
%%   - leave/2 always settles to player_count == |joined|.
%%
%% Catches regressions in the DOWN handler / asobi_reconnect:disconnect
%% bookkeeping and in `running({call, _}, {reconnect, _}, _)` paths.

-define(MAX_PLAYERS, 5).
-define(TTL_MS, 60_000).
-define(NUMTESTS, list_to_integer(os:getenv("PROPER_NUMTESTS", "25"))).
-define(BASE_CONFIG, #{
    game_module => asobi_test_world_game,
    grid_size => 2,
    zone_size => 100,
    tick_rate => 50,
    max_players => ?MAX_PLAYERS,
    view_radius => 1,
    %% Long grace so disconnects don't lapse during the property iteration.
    player_ttl_ms => ?TTL_MS,
    empty_grace_ms => 600000,
    persistent => true
}).

reconnect_lifecycle_test_() ->
    {timeout, 120,
        {setup, fun setup/0, fun cleanup/1, fun(Ctx) ->
            [
                ?_assert(
                    proper:quickcheck(prop_reconnect_lifecycle(Ctx), [
                        {numtests, ?NUMTESTS}, {to_file, user}
                    ])
                )
            ]
        end}}.

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

prop_reconnect_lifecycle(Ctx) ->
    ?FORALL(
        Cmds,
        proper_types:list(command()),
        run_iteration(Ctx, narrow_list(Cmds))
    ).

command() ->
    proper_types:oneof([
        {join, player_id()},
        {disconnect, player_id()},
        {reconnect, player_id()},
        {leave, player_id()}
    ]).

player_id() ->
    proper_types:elements([~"r1", ~"r2", ~"r3", ~"r4", ~"r5"]).

%% --- Runner ---

-spec run_iteration(map(), [term()]) -> boolean().
run_iteration(Ctx, Cmds) ->
    cleanup_world(Ctx),
    Final = lists:foldl(fun(C, S) -> step(C, Ctx, S) end, init_state(), Cmds),
    timer:sleep(20),
    check(Ctx, Final).

init_state() ->
    %% joined = players currently expected to be in the world (whether
    %% disconnected within grace or actively connected).
    %% sessions = pid registered for that player.
    #{joined => sets:new(), sessions => #{}}.

step({join, P}, #{world_pid := Pid}, #{joined := J, sessions := Ss} = S) ->
    case sets:is_element(P, J) orelse sets:size(J) >= ?MAX_PLAYERS of
        true ->
            S;
        false ->
            SessionPid = fake_session(P),
            case asobi_world_server:join(Pid, P) of
                ok ->
                    S#{
                        joined => sets:add_element(P, J),
                        sessions => Ss#{P => SessionPid}
                    };
                {error, _} ->
                    catch exit(SessionPid, kill),
                    S
            end
    end;
step({disconnect, P}, _Ctx, #{joined := J, sessions := Ss} = S) ->
    case {sets:is_element(P, J), maps:get(P, Ss, undefined)} of
        {true, SessionPid} when is_pid(SessionPid) ->
            exit(SessionPid, kill),
            timer:sleep(15),
            S#{sessions => maps:remove(P, Ss)};
        _ ->
            S
    end;
step({reconnect, P}, #{world_pid := Pid}, #{joined := J, sessions := Ss} = S) ->
    case sets:is_element(P, J) andalso not maps:is_key(P, Ss) of
        true ->
            SessionPid = fake_session(P),
            case asobi_world_server:reconnect(Pid, P) of
                ok ->
                    S#{sessions => Ss#{P => SessionPid}};
                {error, _} ->
                    catch exit(SessionPid, kill),
                    S
            end;
        false ->
            S
    end;
step({leave, P}, #{world_pid := Pid}, #{joined := J, sessions := Ss} = S) ->
    case sets:is_element(P, J) of
        true ->
            asobi_world_server:leave(Pid, P),
            case maps:get(P, Ss, undefined) of
                SessionPid when is_pid(SessionPid) -> catch exit(SessionPid, kill);
                _ -> ok
            end,
            timer:sleep(10),
            S#{joined => sets:del_element(P, J), sessions => maps:remove(P, Ss)};
        false ->
            S
    end.

check(#{world_pid := Pid}, #{joined := J}) ->
    Info = asobi_world_server:get_info(Pid),
    Got = maps:get(player_count, Info, -1),
    Want = sets:size(J),
    case Got =:= Want of
        true ->
            true;
        false ->
            io:format(
                user,
                "~nplayer_count mismatch: got=~p want=~p (joined=~p, info=~p)~n",
                [Got, Want, sets:to_list(J), Info]
            ),
            false
    end.

%% --- Fixture ---

cleanup_world(#{world_pid := Pid}) ->
    Info = asobi_world_server:get_info(Pid),
    [asobi_world_server:leave(Pid, P) || P <- maps:get(players, Info, [])],
    timer:sleep(20),
    ok.

start_world() ->
    {ok, InstancePid} = asobi_world_instance:start_link(?BASE_CONFIG),
    unlink(InstancePid),
    timer:sleep(40),
    ServerPid = asobi_world_instance:get_child(InstancePid, asobi_world_server),
    #{instance_pid => InstancePid, world_pid => ServerPid}.

fake_session(PlayerId) ->
    Pid = spawn(fun L() ->
        receive
            stop -> ok;
            _ -> L()
        end
    end),
    ok = pg:join(nova_scope, {player, PlayerId}, Pid),
    Pid.

-spec narrow_list(term()) -> [term()].
narrow_list(L) when is_list(L) -> L.
