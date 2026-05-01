-module(asobi_match_server_tests).
-include_lib("eunit/include/eunit.hrl").

-define(GAME, asobi_test_game).
-define(BASE_CONFIG, #{game_module => ?GAME, min_players => 2, max_players => 4, tick_rate => 50}).

%% --- Setup / Teardown ---

setup() ->
    case ets:whereis(asobi_match_state) of
        undefined -> ets:new(asobi_match_state, [named_table, public, set]);
        _ -> ok
    end,
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

start_match() ->
    start_match(#{}).

start_match(Overrides) ->
    Config = maps:merge(?BASE_CONFIG, Overrides),
    {ok, Pid} = asobi_match_server:start_link(Config),
    Pid.

%% --- Test generators ---

match_server_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        {"starts in waiting state", fun starts_waiting/0},
        {"get_info returns match metadata", fun get_info_waiting/0},
        {"join adds player", fun join_adds_player/0},
        {"join rejects when full", fun join_rejects_full/0},
        {"duplicate join is idempotent", fun duplicate_join/0},
        {"transitions to running at min_players", fun transitions_to_running/0},
        {"leave removes player", fun leave_removes_player/0},
        {"leave last player stops match", fun leave_last_stops/0},
        {"input queued while running", fun input_queued/0},
        {"invalid input does not crash", fun invalid_input_survives/0},
        {"tick executes game logic", fun tick_executes/0},
        {"pause and resume", fun pause_resume/0},
        {"pause when already paused errors", fun pause_already_paused/0},
        {"resume when not paused errors", fun resume_not_paused/0},
        {timeout, 15, {"cancel from running finishes match", fun cancel_match/0}},
        {timeout, 15, {"cancel from paused finishes match", fun cancel_from_paused/0}},
        {timeout, 70, {"waiting timeout stops match", fun waiting_timeout/0}},
        {"get_info works in all states", fun get_info_all_states/0},
        {"state backup and recovery", fun state_backup_recovery/0},
        {"generate_id produces valid uuidv7", fun generate_id_format/0},
        {"disconnect with reconnect policy starts grace", fun disconnect_starts_grace/0},
        {"disconnect without policy is immediate leave", fun disconnect_no_policy_leaves/0},
        {"reconnect within grace keeps player", fun reconnect_within_grace_keeps/0},
        {"reconnect with no policy returns error", fun reconnect_no_policy_errors/0}
    ]}.

%% --- Tests ---

starts_waiting() ->
    Pid = start_match(),
    Info = asobi_match_server:get_info(Pid),
    ?assertEqual(waiting, maps:get(status, Info)),
    ?assertEqual(0, maps:get(player_count, Info)),
    stop(Pid).

get_info_waiting() ->
    Pid = start_match(),
    Info = asobi_match_server:get_info(Pid),
    ?assertMatch(#{match_id := _, status := waiting, player_count := 0, players := []}, Info),
    stop(Pid).

join_adds_player() ->
    Pid = start_match(),
    ok = asobi_match_server:join(Pid, ~"p1"),
    Info = asobi_match_server:get_info(Pid),
    ?assertEqual(1, maps:get(player_count, Info)),
    ?assertEqual([~"p1"], maps:get(players, Info)),
    stop(Pid).

join_rejects_full() ->
    Pid = start_match(#{min_players => 1, max_players => 2}),
    ok = asobi_match_server:join(Pid, ~"p1"),
    timer:sleep(50),
    ok = asobi_match_server:join(Pid, ~"p2"),
    ?assertMatch({error, match_full}, asobi_match_server:join(Pid, ~"p3")),
    stop(Pid).

duplicate_join() ->
    Pid = start_match(),
    ok = asobi_match_server:join(Pid, ~"p1"),
    ok = asobi_match_server:join(Pid, ~"p1"),
    Info = asobi_match_server:get_info(Pid),
    ?assertEqual(1, maps:get(player_count, Info)),
    stop(Pid).

transitions_to_running() ->
    Pid = start_match(),
    ok = asobi_match_server:join(Pid, ~"p1"),
    Info1 = asobi_match_server:get_info(Pid),
    ?assertEqual(waiting, maps:get(status, Info1)),
    ok = asobi_match_server:join(Pid, ~"p2"),
    timer:sleep(50),
    Info2 = asobi_match_server:get_info(Pid),
    ?assertEqual(running, maps:get(status, Info2)),
    ?assertEqual(2, maps:get(player_count, Info2)),
    stop(Pid).

leave_removes_player() ->
    Pid = start_match(),
    ok = asobi_match_server:join(Pid, ~"p1"),
    ok = asobi_match_server:join(Pid, ~"p2"),
    timer:sleep(50),
    asobi_match_server:leave(Pid, ~"p1"),
    timer:sleep(50),
    Info = asobi_match_server:get_info(Pid),
    ?assertEqual(1, maps:get(player_count, Info)),
    ?assertEqual([~"p2"], maps:get(players, Info)),
    stop(Pid).

leave_last_stops() ->
    Pid = start_match(#{min_players => 1, max_players => 2}),
    unlink(Pid),
    Ref = monitor(process, Pid),
    ok = asobi_match_server:join(Pid, ~"p1"),
    timer:sleep(50),
    asobi_match_server:leave(Pid, ~"p1"),
    receive
        {'DOWN', Ref, process, Pid, {shutdown, empty}} -> ok
    after 2000 ->
        ?assert(false)
    end.

input_queued() ->
    Pid = start_match(),
    ok = asobi_match_server:join(Pid, ~"p1"),
    ok = asobi_match_server:join(Pid, ~"p2"),
    timer:sleep(50),
    asobi_match_server:handle_input(Pid, ~"p1", #{~"action" => ~"move"}),
    timer:sleep(100),
    Info = asobi_match_server:get_info(Pid),
    ?assertEqual(running, maps:get(status, Info)),
    stop(Pid).

invalid_input_survives() ->
    Pid = start_match(),
    ok = asobi_match_server:join(Pid, ~"p1"),
    ok = asobi_match_server:join(Pid, ~"p2"),
    timer:sleep(50),
    asobi_match_server:handle_input(Pid, ~"p1", #{~"action" => ~"invalid"}),
    timer:sleep(100),
    Info = asobi_match_server:get_info(Pid),
    ?assertEqual(running, maps:get(status, Info)),
    stop(Pid).

tick_executes() ->
    Pid = start_match(#{min_players => 1, max_players => 2, tick_rate => 20}),
    ok = asobi_match_server:join(Pid, ~"p1"),
    timer:sleep(200),
    Info = asobi_match_server:get_info(Pid),
    ?assertEqual(running, maps:get(status, Info)),
    stop(Pid).

pause_resume() ->
    Pid = start_match(),
    ok = asobi_match_server:join(Pid, ~"p1"),
    ok = asobi_match_server:join(Pid, ~"p2"),
    timer:sleep(50),
    ok = asobi_match_server:pause(Pid),
    ?assertMatch(#{status := paused}, asobi_match_server:get_info(Pid)),
    ok = asobi_match_server:resume(Pid),
    timer:sleep(50),
    ?assertMatch(#{status := running}, asobi_match_server:get_info(Pid)),
    stop(Pid).

pause_already_paused() ->
    Pid = start_match(),
    ok = asobi_match_server:join(Pid, ~"p1"),
    ok = asobi_match_server:join(Pid, ~"p2"),
    timer:sleep(50),
    ok = asobi_match_server:pause(Pid),
    ?assertMatch({error, already_paused}, asobi_match_server:pause(Pid)),
    stop(Pid).

resume_not_paused() ->
    Pid = start_match(),
    ok = asobi_match_server:join(Pid, ~"p1"),
    ok = asobi_match_server:join(Pid, ~"p2"),
    timer:sleep(50),
    ?assertMatch({error, not_paused}, asobi_match_server:resume(Pid)),
    stop(Pid).

cancel_match() ->
    Pid = start_match(),
    unlink(Pid),
    Ref = monitor(process, Pid),
    ok = asobi_match_server:join(Pid, ~"p1"),
    ok = asobi_match_server:join(Pid, ~"p2"),
    timer:sleep(50),
    ?assertMatch(#{status := running}, asobi_match_server:get_info(Pid)),
    asobi_match_server:cancel(Pid),
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 10000 ->
        ?assert(false)
    end.

cancel_from_paused() ->
    Pid = start_match(),
    unlink(Pid),
    Ref = monitor(process, Pid),
    ok = asobi_match_server:join(Pid, ~"p1"),
    ok = asobi_match_server:join(Pid, ~"p2"),
    timer:sleep(50),
    ok = asobi_match_server:pause(Pid),
    asobi_match_server:cancel(Pid),
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 10000 ->
        ?assert(false)
    end.

waiting_timeout() ->
    Pid = start_match(#{min_players => 10}),
    unlink(Pid),
    Ref = monitor(process, Pid),
    ok = asobi_match_server:join(Pid, ~"p1"),
    receive
        {'DOWN', Ref, process, Pid, {shutdown, timeout}} -> ok
    after 65000 ->
        ?assert(false)
    end.

get_info_all_states() ->
    Pid = start_match(),
    ?assertMatch(#{status := waiting}, asobi_match_server:get_info(Pid)),
    ok = asobi_match_server:join(Pid, ~"p1"),
    ok = asobi_match_server:join(Pid, ~"p2"),
    timer:sleep(50),
    ?assertMatch(#{status := running}, asobi_match_server:get_info(Pid)),
    ok = asobi_match_server:pause(Pid),
    ?assertMatch(#{status := paused}, asobi_match_server:get_info(Pid)),
    ok = asobi_match_server:resume(Pid),
    timer:sleep(50),
    ?assertMatch(#{status := running}, asobi_match_server:get_info(Pid)),
    stop(Pid).

state_backup_recovery() ->
    MatchId = asobi_id:generate(),
    Pid = start_match(#{match_id => MatchId}),
    unlink(Pid),
    ok = asobi_match_server:join(Pid, ~"p1"),
    ok = asobi_match_server:join(Pid, ~"p2"),
    timer:sleep(100),
    exit(Pid, kill),
    timer:sleep(50),
    ?assertMatch([{MatchId, running, _}], ets:lookup(asobi_match_state, MatchId)),
    Pid2 = start_match(#{match_id => MatchId}),
    timer:sleep(50),
    Info = asobi_match_server:get_info(Pid2),
    ?assertEqual(running, maps:get(status, Info)),
    ?assertEqual(2, maps:get(player_count, Info)),
    stop(Pid2).

generate_id_format() ->
    Id = asobi_id:generate(),
    ?assertEqual(36, byte_size(Id)),
    ?assertMatch(
        <<_:8/binary, "-", _:4/binary, "-", _:4/binary, "-", _:4/binary, "-", _:12/binary>>,
        Id
    ),
    ?assertEqual(<<"7">>, binary:part(Id, 14, 1)).

%% --- Reconnect tests ---

disconnect_starts_grace() ->
    %% With a reconnect policy, killing the player session must NOT remove
    %% the player from the match — the grace timer holds them in place
    %% until reconnect/2 returns or grace expires.
    Pid = start_match(#{
        min_players => 1,
        max_players => 2,
        reconnect => #{
            grace_period => 30_000,
            during_grace => idle,
            on_reconnect => resume,
            on_expire => remove,
            pause_match => false,
            max_offline_total => infinity
        }
    }),
    SessionPid = fake_session(~"p1"),
    ok = asobi_match_server:join(Pid, ~"p1"),
    timer:sleep(50),
    %% Match transitioned to running; player count is 1.
    ?assertEqual(1, maps:get(player_count, asobi_match_server:get_info(Pid))),

    exit(SessionPid, kill),
    timer:sleep(50),
    %% Player still counted — grace is active.
    ?assertEqual(1, maps:get(player_count, asobi_match_server:get_info(Pid))),
    stop(Pid).

disconnect_no_policy_leaves() ->
    %% Without a reconnect policy, session DOWN goes through handle_leave —
    %% same as an explicit leave/2.
    Pid = start_match(#{min_players => 1, max_players => 2}),
    unlink(Pid),
    PidRef = monitor(process, Pid),
    SessionPid = fake_session(~"p1"),
    ok = asobi_match_server:join(Pid, ~"p1"),
    timer:sleep(50),

    exit(SessionPid, kill),
    %% Single-player match shuts down on last leave.
    receive
        {'DOWN', PidRef, process, Pid, {shutdown, empty}} -> ok
    after 2000 ->
        ?assert(false)
    end.

reconnect_within_grace_keeps() ->
    %% Disconnect → reconnect inside the grace window leaves the player
    %% counted and re-monitors the new session.
    Pid = start_match(#{
        min_players => 1,
        max_players => 2,
        reconnect => #{
            grace_period => 30_000,
            during_grace => idle,
            on_reconnect => resume,
            on_expire => remove,
            pause_match => false,
            max_offline_total => infinity
        }
    }),
    SessionPid1 = fake_session(~"p1"),
    ok = asobi_match_server:join(Pid, ~"p1"),
    timer:sleep(50),

    exit(SessionPid1, kill),
    timer:sleep(30),
    %% Replace the registered session with a fresh fake.
    catch pg:leave(nova_scope, {player, ~"p1"}, SessionPid1),
    _SessionPid2 = fake_session(~"p1"),
    ?assertEqual(ok, asobi_match_server:reconnect(Pid, ~"p1")),
    timer:sleep(30),
    ?assertEqual(1, maps:get(player_count, asobi_match_server:get_info(Pid))),
    stop(Pid).

reconnect_no_policy_errors() ->
    Pid = start_match(#{min_players => 1, max_players => 2}),
    _SessionPid = fake_session(~"p1"),
    ok = asobi_match_server:join(Pid, ~"p1"),
    timer:sleep(50),
    ?assertMatch({error, no_reconnect_policy}, asobi_match_server:reconnect(Pid, ~"p1")),
    stop(Pid).

%% --- Helpers ---

fake_session(PlayerId) ->
    %% Spawn a tiny process and register it as the player's session in the
    %% nova_scope pg group so asobi_match_server:find_player_pid/1 returns it.
    Pid = spawn(fun L() ->
        receive
            stop -> ok;
            _ -> L()
        end
    end),
    ok = pg:join(nova_scope, {player, PlayerId}, Pid),
    Pid.

stop(Pid) ->
    case is_process_alive(Pid) of
        true ->
            unlink(Pid),
            Ref = monitor(process, Pid),
            exit(Pid, shutdown),
            receive
                {'DOWN', Ref, process, Pid, _} -> ok
            after 5000 -> ok
            end;
        false ->
            ok
    end.
