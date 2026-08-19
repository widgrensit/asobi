-module(asobi_match_server_tests).
-include_lib("eunit/include/eunit.hrl").

-define(GAME, asobi_test_game).
-define(BASE_CONFIG, #{game_module => ?GAME, min_players => 2, max_players => 4, tick_rate => 50}).
%% One {PlayerId, WinDelta, LossDelta} per stats UPDATE the match server issued.
-define(STATS_TAB, asobi_match_server_tests_stats).

%% --- Setup / Teardown ---

setup() ->
    case ets:whereis(asobi_match_state) of
        undefined -> ets:new(asobi_match_state, [named_table, public, set]);
        _ -> ok
    end,
    case ets:whereis(?STATS_TAB) of
        undefined -> ets:new(?STATS_TAB, [named_table, public, duplicate_bag]);
        _ -> ets:delete_all_objects(?STATS_TAB)
    end,
    case whereis(nova_scope) of
        undefined -> pg:start_link(nova_scope);
        _ -> ok
    end,
    meck:new(asobi_repo, [no_link]),
    meck:expect(asobi_repo, insert, fun(_CS) -> {ok, #{}} end),
    meck:expect(asobi_repo, insert, fun(_CS, _Opts) -> {ok, #{}} end),
    meck:expect(asobi_repo, transaction, fun(Fun) -> Fun() end),
    meck:new(kura_db, [passthrough, no_link]),
    meck:expect(kura_db, query, fun(_Repo, _SQL, [PlayerId, Win, Loss]) ->
        ets:insert(?STATS_TAB, {PlayerId, Win, Loss}),
        #{num_rows => 1}
    end),
    meck:new(asobi_presence, [non_strict, no_link]),
    meck:expect(asobi_presence, send, fun(_PlayerId, _Msg) -> ok end),
    ok.

cleanup(_) ->
    meck:unload(asobi_presence),
    meck:unload(kura_db),
    meck:unload(asobi_repo),
    ok.

start_match() ->
    start_match(#{}).

%% Unlinked deliberately. A match left in `waiting` stops with
%% {shutdown, timeout} after ?WAITING_TIMEOUT, and a still-linked one takes
%% the eunit process with it - sixty seconds later, in whatever unrelated
%% group happens to be running by then (asobi#376).
start_match(Overrides) ->
    Config = maps:merge(?BASE_CONFIG, Overrides),
    {ok, Pid} = asobi_match_server:start_link(Config),
    unlink(Pid),
    Pid.

%% --- Test generators ---

match_server_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        {"starts in waiting state", fun starts_waiting/0},
        {"get_info returns match metadata", fun get_info_waiting/0},
        {"get_info(Pid, listing) omits the roster but keeps filter/listing fields",
            fun get_info_listing/0},
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
        {"reconnect with no policy returns error", fun reconnect_no_policy_errors/0},
        {"join with no live session does not crash",
            fun join_with_no_live_session_does_not_crash/0},
        {"reconnect with no live session returns error",
            fun reconnect_with_no_live_session_returns_error/0},
        {"failed reconnect leaves grace intact", fun failed_reconnect_leaves_grace_intact/0},
        {"session down while waiting removes player", fun waiting_down_removes_player/0},
        {"session down while paused with no policy is immediate leave",
            fun paused_down_no_policy_leaves/0},
        {"session down while paused with reconnect policy starts grace",
            fun paused_down_starts_grace/0},
        {"reconnect while paused succeeds instead of hanging",
            fun reconnect_while_paused_succeeds/0},
        {"reconnect while waiting does not crash", fun reconnect_while_waiting_does_not_crash/0},
        {"input while waiting is dropped without crashing", fun input_while_waiting_is_dropped/0},
        {"vote calls while waiting error instead of crashing",
            fun vote_calls_while_waiting_error/0},
        {"input while paused is dropped without crashing", fun input_while_paused_is_dropped/0},
        {"vote calls while paused error instead of hanging", fun vote_calls_while_paused_error/0},
        {"join while paused errors instead of hanging", fun join_while_paused_errors/0},
        {timeout, 15,
            {"grace expiry of the last player stops the match",
                fun grace_expiry_of_last_player_stops_match/0}},
        {timeout, 15,
            {"grace expiry with players left keeps the match running",
                fun grace_expiry_with_players_left_keeps_match/0}},
        {"join tells the session which match it joined", fun join_notifies_session/0},
        {"leave tells the session it is out", fun leave_notifies_session/0},
        {"a refused join notifies nobody", fun refused_join_notifies_nobody/0},
        {"a match defaults to joinable", fun joinable_by_default/0},
        {"set_joinable(false) closes the match to new joins", fun set_joinable_closes/0},
        {"a locked match reopens on set_joinable(true)", fun set_joinable_reopens/0},
        {"locked beats full", fun locked_reported_before_full/0},
        {"a locked match keeps the players it has", fun locked_keeps_roster/0},
        {"joinable survives a pause", fun set_joinable_while_paused/0},
        {"backfill into a running match does not restart the clock",
            fun backfill_keeps_started_at/0}
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

%% asobi#194: mirrors asobi_world_server_tests:get_info_listing/0.
get_info_listing() ->
    Pid = start_match(),
    ok = asobi_match_server:join(Pid, ~"p1"),
    Full = asobi_match_server:get_info(Pid),
    Listing = asobi_match_server:get_info(Pid, listing),
    ?assertNot(maps:is_key(players, Listing)),
    [
        ?assertEqual(maps:get(K, Full), maps:get(K, Listing))
     || K <- [match_id, status, player_count, max_players, mode, listed]
    ],
    ?assertEqual(
        asobi_match_server:listing_info(Full), asobi_match_server:listing_info(Listing)
    ),
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

%% Regression for widgrensit/asobi#280: find_player_pid/1 used to fall back
%% to self() when a player had no live pg registration, which would have
%% recorded this match server's own pid as that player's session_pid and
%% monitor_ref - not a crash, but silently wrong. join/2 with no fake_session
%% registered first is exactly that case.
join_with_no_live_session_does_not_crash() ->
    Pid = start_match(#{min_players => 2, max_players => 2}),
    ok = asobi_match_server:join(Pid, ~"no_session"),
    ?assert(is_process_alive(Pid)),
    ?assertEqual(1, maps:get(player_count, asobi_match_server:get_info(Pid))),
    {_StateName, #{
        players := #{~"no_session" := #{session_pid := SessionPid, monitor_ref := MonRef}}
    }} = sys:get_state(Pid),
    ?assertEqual(undefined, SessionPid),
    ?assertEqual(undefined, MonRef),
    stop(Pid).

%% Regression for widgrensit/asobi#280: a reconnect attempt with no live
%% pg-registered session for the player must fail cleanly (the caller
%% invoking reconnect/2 IS supposed to be that live session) rather than
%% crash on monitor(process, undefined) or silently monitor this match
%% server's own pid.
reconnect_with_no_live_session_returns_error() ->
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
    %% Unique player id - other tests in this suite leave dangling
    %% fake_session processes registered under {player, ~"p1"} in the shared
    %% nova_scope pg group, which would make find_player_pid/1 see a stray
    %% live pid instead of the empty-group case this test needs.
    PlayerId = ~"reconnect_no_session_280",
    SessionPid = fake_session(PlayerId),
    ok = asobi_match_server:join(Pid, PlayerId),
    timer:sleep(50),
    exit(SessionPid, kill),
    timer:sleep(100),
    %% No new session registered before reconnecting.
    ?assertEqual({error, no_live_session}, asobi_match_server:reconnect(Pid, PlayerId)),
    ?assert(is_process_alive(Pid)),
    stop(Pid).

%% Regression for widgrensit/asobi#280: the no-live-session check runs before
%% asobi_reconnect:reconnect/2, so a rejected reconnect must not consume the
%% player's disconnected/grace entry - a real session arriving afterwards
%% still gets to reconnect normally.
failed_reconnect_leaves_grace_intact() ->
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
    %% Unique player id - see reconnect_with_no_live_session_returns_error/0.
    PlayerId = ~"retry_after_no_session_280",
    SessionPid1 = fake_session(PlayerId),
    ok = asobi_match_server:join(Pid, PlayerId),
    timer:sleep(50),
    exit(SessionPid1, kill),
    timer:sleep(100),
    ?assertEqual({error, no_live_session}, asobi_match_server:reconnect(Pid, PlayerId)),
    {_StateName, #{reconnect_state := #{disconnected := #{PlayerId := _}}}} = sys:get_state(Pid),
    catch pg:leave(nova_scope, {player, PlayerId}, SessionPid1),
    _SessionPid2 = fake_session(PlayerId),
    ?assertEqual(ok, asobi_match_server:reconnect(Pid, PlayerId)),
    timer:sleep(30),
    ?assertEqual(1, maps:get(player_count, asobi_match_server:get_info(Pid))),
    stop(Pid).

%% Regression for widgrensit/asobi#285: waiting/3 had no clause for a
%% session dying while the match was still gathering players, so a DOWN
%% message crashed the match server with function_clause and took every
%% player already in the lobby down with it. Unique player ids - other
%% tests in this suite leave dangling fake_session processes registered
%% under {player, ~"p1"} in the shared nova_scope pg group.
waiting_down_removes_player() ->
    Pid = start_match(#{min_players => 3, max_players => 4}),
    SessionPid1 = fake_session(~"p285_waiting_1"),
    ok = asobi_match_server:join(Pid, ~"p285_waiting_1"),
    ok = asobi_match_server:join(Pid, ~"p285_waiting_2"),
    timer:sleep(50),
    Info0 = asobi_match_server:get_info(Pid),
    ?assertEqual(waiting, maps:get(status, Info0)),
    ?assertEqual(2, maps:get(player_count, Info0)),

    exit(SessionPid1, kill),
    timer:sleep(100),
    ?assert(is_process_alive(Pid)),
    Info1 = asobi_match_server:get_info(Pid),
    ?assertEqual(waiting, maps:get(status, Info1)),
    ?assertEqual(1, maps:get(player_count, Info1)),
    ?assertEqual([~"p285_waiting_2"], maps:get(players, Info1)),
    stop(Pid).

%% Regression for widgrensit/asobi#285: paused/3 had no clause for a
%% session DOWN, so it fell through to the catch-all and was silently
%% swallowed. Without a reconnect policy this must behave like running's
%% no-policy branch: an immediate leave.
paused_down_no_policy_leaves() ->
    Pid = start_match(#{min_players => 1, max_players => 2}),
    unlink(Pid),
    Ref = monitor(process, Pid),
    SessionPid = fake_session(~"p285_paused_nopolicy"),
    ok = asobi_match_server:join(Pid, ~"p285_paused_nopolicy"),
    timer:sleep(50),
    ok = asobi_match_server:pause(Pid),
    ?assertMatch(#{status := paused}, asobi_match_server:get_info(Pid)),

    exit(SessionPid, kill),
    %% Single-player match shuts down on last leave, same as running.
    receive
        {'DOWN', Ref, process, Pid, {shutdown, empty}} -> ok
    after 2000 ->
        ?assert(false)
    end.

%% Regression for widgrensit/asobi#285: with a reconnect policy active, a
%% session DOWN while paused must start reconnect grace exactly like
%% running's with-policy branch - not be swallowed by the catch-all.
%%
%% paused/3, unlike running/3, still ends in a catch-all, so "player still
%% counted right after the kill" is not proof grace actually started - the
%% catch-all silently dropping the DOWN produces the identical observation.
%% tick_reconnect/2 only runs from running's tick handler, so grace can't
%% progress while paused; resume/1 and let the (short) grace period expire
%% instead - that only happens if asobi_reconnect:disconnect/3 genuinely
%% populated grace state, which only the fixed with-policy clause does.
paused_down_starts_grace() ->
    Pid = start_match(#{
        min_players => 1,
        max_players => 2,
        reconnect => #{
            grace_period => 100,
            during_grace => idle,
            on_reconnect => resume,
            on_expire => remove,
            pause_match => false,
            max_offline_total => infinity
        }
    }),
    unlink(Pid),
    Ref = monitor(process, Pid),
    SessionPid = fake_session(~"p285_paused_policy"),
    ok = asobi_match_server:join(Pid, ~"p285_paused_policy"),
    timer:sleep(50),
    ok = asobi_match_server:pause(Pid),
    ?assertMatch(#{status := paused}, asobi_match_server:get_info(Pid)),

    exit(SessionPid, kill),
    timer:sleep(50),
    %% Grace active - player still counted, match server alive.
    ?assert(is_process_alive(Pid)),
    Info = asobi_match_server:get_info(Pid),
    ?assertEqual(paused, maps:get(status, Info)),
    ?assertEqual(1, maps:get(player_count, Info)),

    %% asobi#292: resuming lets the grace expire, which empties the roster
    %% and must shut the match down (it used to tick on with no players).
    ok = asobi_match_server:resume(Pid),
    receive
        {'DOWN', Ref, process, Pid, {shutdown, empty}} -> ok
    after 2000 ->
        ?assert(false)
    end.

%% Regression for widgrensit/asobi#292: when the last player's reconnect
%% grace expired, handle_reconnect_events/2 removed them from the roster but
%% (unlike handle_leave/2) never checked for an empty roster, so the match
%% kept ticking forever with no players.
grace_expiry_of_last_player_stops_match() ->
    Pid = start_match(#{
        min_players => 1,
        max_players => 2,
        reconnect => #{
            grace_period => 100,
            during_grace => idle,
            on_reconnect => resume,
            on_expire => remove,
            pause_match => false,
            max_offline_total => infinity
        }
    }),
    unlink(Pid),
    Ref = monitor(process, Pid),
    PlayerId = ~"p292_grace_last",
    SessionPid = fake_session(PlayerId),
    ok = asobi_match_server:join(Pid, PlayerId),
    timer:sleep(50),
    ?assertEqual(1, maps:get(player_count, asobi_match_server:get_info(Pid))),

    exit(SessionPid, kill),
    receive
        {'DOWN', Ref, process, Pid, {shutdown, empty}} -> ok
    after 2000 ->
        ?assert(false)
    end.

%% asobi#292: only the *last* player's grace expiry stops the match - the
%% roster still having someone in it must leave the match running.
grace_expiry_with_players_left_keeps_match() ->
    Pid = start_match(#{
        min_players => 1,
        max_players => 2,
        reconnect => #{
            grace_period => 100,
            during_grace => idle,
            on_reconnect => resume,
            on_expire => remove,
            pause_match => false,
            max_offline_total => infinity
        }
    }),
    SessionPid = fake_session(~"p292_grace_gone"),
    ok = asobi_match_server:join(Pid, ~"p292_grace_gone"),
    ok = asobi_match_server:join(Pid, ~"p292_grace_stays"),
    timer:sleep(50),
    ?assertEqual(2, maps:get(player_count, asobi_match_server:get_info(Pid))),

    exit(SessionPid, kill),
    timer:sleep(500),
    ?assert(is_process_alive(Pid)),
    Info = asobi_match_server:get_info(Pid),
    ?assertEqual(1, maps:get(player_count, Info)),
    ?assertEqual([~"p292_grace_stays"], maps:get(players, Info)),
    stop(Pid).

%% Regression for widgrensit/asobi#285: paused/3 had no {call, reconnect}
%% clause, so calling reconnect/2 while paused fell through to the
%% catch-all, which never replies - gen_statem:call/2 defaults to timeout
%% infinity, so the caller would hang forever. Calls gen_statem:call/3
%% directly with a bounded timeout so a regression fails fast here instead
%% of hanging the whole test run.
reconnect_while_paused_succeeds() ->
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
    PlayerId = ~"p285_reconnect_paused",
    SessionPid1 = fake_session(PlayerId),
    ok = asobi_match_server:join(Pid, PlayerId),
    timer:sleep(50),
    ok = asobi_match_server:pause(Pid),
    exit(SessionPid1, kill),
    timer:sleep(100),
    %% Grace active (see paused_down_starts_grace/0) - a real session
    %% arriving now must be able to reconnect before resume/1 is called.
    _SessionPid2 = fake_session(PlayerId),
    ?assertEqual(ok, gen_statem:call(Pid, {reconnect, PlayerId}, 2000)),
    ?assertMatch(#{status := paused}, asobi_match_server:get_info(Pid)),
    ?assertEqual(1, maps:get(player_count, asobi_match_server:get_info(Pid))),
    stop(Pid).

%% Regression for widgrensit/asobi#285: waiting/3 had no {call, reconnect}
%% clause and no catch-all, so calling reconnect/2 while still gathering
%% players crashed the match server with function_clause. Bounded timeout
%% for the same reason as reconnect_while_paused_succeeds/0.
reconnect_while_waiting_does_not_crash() ->
    Pid = start_match(#{min_players => 2, max_players => 2}),
    PlayerId = ~"p285_reconnect_waiting",
    ok = asobi_match_server:join(Pid, PlayerId),
    ?assertEqual(
        {error, no_reconnect_policy}, gen_statem:call(Pid, {reconnect, PlayerId}, 2000)
    ),
    ?assert(is_process_alive(Pid)),
    stop(Pid).

%% Regression for widgrensit/asobi#290: waiting/3 had no {input, _, _} clause
%% and no catch-all, so a client casting input before the last player joined
%% crashed the match with function_clause.
input_while_waiting_is_dropped() ->
    Pid = start_match(#{min_players => 2, max_players => 2}),
    ok = asobi_match_server:join(Pid, ~"p290_waiting_input"),
    asobi_match_server:handle_input(Pid, ~"p290_waiting_input", #{~"action" => ~"move"}),
    timer:sleep(50),
    ?assert(is_process_alive(Pid)),
    ?assertMatch(#{status := waiting}, asobi_match_server:get_info(Pid)),
    stop(Pid).

%% Regression for widgrensit/asobi#290: the vote trio had no clause in
%% waiting/3 either - same function_clause crash. Bounded timeout so a
%% regression fails fast instead of hanging the run.
vote_calls_while_waiting_error() ->
    Pid = start_match(#{min_players => 2, max_players => 2}),
    ok = asobi_match_server:join(Pid, ~"p290_waiting_vote"),
    ?assertEqual(
        {error, match_not_started}, gen_statem:call(Pid, {start_vote, #{}}, 2000)
    ),
    ?assertEqual(
        {error, match_not_started},
        gen_statem:call(Pid, {cast_vote, ~"p290_waiting_vote", ~"v1", ~"o1"}, 2000)
    ),
    ?assertEqual(
        {error, match_not_started},
        gen_statem:call(Pid, {use_veto, ~"p290_waiting_vote", ~"v1"}, 2000)
    ),
    ?assert(is_process_alive(Pid)),
    stop(Pid).

%% Regression for widgrensit/asobi#290: input while paused was swallowed by
%% paused/3's catch-all; it now hits an explicit clause that logs the drop.
%% The observable contract is the same from the client's side - the match
%% survives and stays paused - so this guards the crash/regression case.
input_while_paused_is_dropped() ->
    Pid = start_match(#{min_players => 1, max_players => 2}),
    ok = asobi_match_server:join(Pid, ~"p290_paused_input"),
    timer:sleep(50),
    ok = asobi_match_server:pause(Pid),
    asobi_match_server:handle_input(Pid, ~"p290_paused_input", #{~"action" => ~"move"}),
    timer:sleep(50),
    ?assert(is_process_alive(Pid)),
    ?assertMatch(#{status := paused}, asobi_match_server:get_info(Pid)),
    stop(Pid).

%% Regression for widgrensit/asobi#290: the vote trio fell through to
%% paused/3's catch-all, which never replies - gen_statem:call/2 defaults to
%% timeout infinity, so the caller hung forever.
vote_calls_while_paused_error() ->
    Pid = start_match(#{min_players => 1, max_players => 2}),
    ok = asobi_match_server:join(Pid, ~"p290_paused_vote"),
    timer:sleep(50),
    ok = asobi_match_server:pause(Pid),
    ?assertEqual({error, match_paused}, gen_statem:call(Pid, {start_vote, #{}}, 2000)),
    ?assertEqual(
        {error, match_paused},
        gen_statem:call(Pid, {cast_vote, ~"p290_paused_vote", ~"v1", ~"o1"}, 2000)
    ),
    ?assertEqual(
        {error, match_paused}, gen_statem:call(Pid, {use_veto, ~"p290_paused_vote", ~"v1"}, 2000)
    ),
    ?assert(is_process_alive(Pid)),
    stop(Pid).

%% Regression for widgrensit/asobi#290: join is the fourth call with no
%% paused/3 clause, and hung the caller the same way.
join_while_paused_errors() ->
    Pid = start_match(#{min_players => 1, max_players => 4}),
    ok = asobi_match_server:join(Pid, ~"p290_paused_join1"),
    timer:sleep(50),
    ok = asobi_match_server:pause(Pid),
    ?assertEqual(
        {error, match_paused}, gen_statem:call(Pid, {join, ~"p290_paused_join2", #{}}, 2000)
    ),
    ?assertEqual(1, maps:get(player_count, asobi_match_server:get_info(Pid))),
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

%% --- session notification, joinable, backfill ---

%% asobi#423: the session used to learn its match_pid only from the
%% matchmaker, so a player who found a match with match.list and joined it by
%% id held no match_pid at all - their input was answered `not_in_match` and
%% their leave did nothing.
join_notifies_session() ->
    meck:reset(asobi_presence),
    Pid = start_match(),
    ok = asobi_match_server:join(Pid, ~"p_notify"),
    ?assert(meck:called(asobi_presence, send, [~"p_notify", {match_joined, Pid}])),
    stop(Pid).

leave_notifies_session() ->
    Pid = start_match(),
    ok = asobi_match_server:join(Pid, ~"p_left_a"),
    ok = asobi_match_server:join(Pid, ~"p_left_b"),
    meck:reset(asobi_presence),
    ok = asobi_match_server:leave(Pid, ~"p_left_a"),
    timer:sleep(50),
    ?assert(meck:called(asobi_presence, send, [~"p_left_a", {match_left, Pid}])),
    stop(Pid).

refused_join_notifies_nobody() ->
    meck:reset(asobi_presence),
    Pid = start_match(),
    ?assertMatch(
        {error, {join_refused, ~"not_today"}}, asobi_match_server:join(Pid, ~"refuse_me")
    ),
    ?assertEqual(0, maps:get(player_count, asobi_match_server:get_info(Pid))),
    ?assertNot(meck:called(asobi_presence, send, [~"refuse_me", {match_joined, Pid}])),
    stop(Pid).

joinable_by_default() ->
    Pid = start_match(),
    ?assert(maps:get(joinable, asobi_match_server:get_info(Pid))),
    stop(Pid).

set_joinable_closes() ->
    Pid = start_match(),
    ok = asobi_match_server:join(Pid, ~"p_lock1"),
    ok = asobi_match_server:set_joinable(Pid, false),
    ?assertMatch({error, match_locked}, asobi_match_server:join(Pid, ~"p_lock2")),
    ?assertNot(maps:get(joinable, asobi_match_server:get_info(Pid))),
    stop(Pid).

set_joinable_reopens() ->
    Pid = start_match(),
    ok = asobi_match_server:set_joinable(Pid, false),
    ?assertMatch({error, match_locked}, asobi_match_server:join(Pid, ~"p_reopen1")),
    ok = asobi_match_server:set_joinable(Pid, true),
    ?assertEqual(ok, asobi_match_server:join(Pid, ~"p_reopen2")),
    stop(Pid).

%% A closed match and a full one are different states and a client acts on
%% them differently: full may free a slot on the next leave, locked will not.
locked_reported_before_full() ->
    Pid = start_match(#{min_players => 1, max_players => 1}),
    ok = asobi_match_server:join(Pid, ~"p_lf1"),
    ok = asobi_match_server:set_joinable(Pid, false),
    ?assertMatch({error, match_locked}, asobi_match_server:join(Pid, ~"p_lf2")),
    stop(Pid).

locked_keeps_roster() ->
    Pid = start_match(),
    ok = asobi_match_server:join(Pid, ~"p_keep1"),
    ok = asobi_match_server:join(Pid, ~"p_keep2"),
    ok = asobi_match_server:set_joinable(Pid, false),
    timer:sleep(50),
    Info = asobi_match_server:get_info(Pid),
    ?assertEqual(2, maps:get(player_count, Info)),
    ?assertEqual(running, maps:get(status, Info)),
    stop(Pid).

set_joinable_while_paused() ->
    Pid = start_match(#{min_players => 1}),
    ok = asobi_match_server:join(Pid, ~"p_pause_lock"),
    timer:sleep(50),
    ok = asobi_match_server:pause(Pid),
    ok = asobi_match_server:set_joinable(Pid, false),
    timer:sleep(50),
    ok = asobi_match_server:resume(Pid),
    ?assertMatch({error, match_locked}, asobi_match_server:join(Pid, ~"p_pause_lock2")),
    stop(Pid).

%% started_at is the match clock the persisted record reports a duration
%% from. Stamping it on every join past min_players meant each backfill
%% joiner restarted it.
backfill_keeps_started_at() ->
    Self = self(),
    meck:new(asobi_telemetry, [passthrough, no_link]),
    meck:expect(asobi_telemetry, match_finished, fun(_MatchId, DurationMs, _Result) ->
        Self ! {duration, DurationMs},
        ok
    end),
    try
        Pid = start_match(#{min_players => 1, max_players => 4}),
        ok = asobi_match_server:join(Pid, ~"p_clock1"),
        timer:sleep(120),
        ok = asobi_match_server:join(Pid, ~"p_clock2"),
        ok = asobi_match_server:cancel(Pid),
        receive
            {duration, DurationMs} ->
                ?assert(DurationMs >= 100)
        after 5000 ->
            ?assert(false)
        end,
        stop(Pid)
    after
        meck:unload(asobi_telemetry)
    end.

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

%% --- broadcast reaches players in every live state ---

%% game.broadcast is a self-cast from the Lua callback into the match
%% gen_statem. `waiting` had no clause and no catch-all, so a game telling
%% the room "someone joined" while gathering crashed the match. `finished`
%% had a catch-all, so an end-of-match broadcast was swallowed silently -
%% which reads as a client bug rather than a server one.

broadcast_in_waiting_reaches_players_test() ->
    setup(),
    Pid = start_match(#{min_players => 2, max_players => 4}),
    ok = asobi_match_server:join(Pid, ~"p1"),
    ?assertEqual(waiting, maps:get(status, asobi_match_server:get_info(Pid))),

    asobi_match_server:broadcast_event(Pid, lobby_update, #{waiting_for => 1}),
    %% A crash here would leave the match dead; a working clause leaves it
    %% waiting and responsive.
    ?assertEqual(waiting, maps:get(status, asobi_match_server:get_info(Pid))),
    ?assert(is_process_alive(Pid)),
    cleanup(ok).

broadcast_in_finished_is_not_swallowed_test() ->
    setup(),
    %% Drive the match to `finished` the way a real game does: tick returns
    %% {finished, Result, State}. Without a broadcast clause the catch-all in
    %% `finished` swallows the end-of-match event with no error anywhere.
    meck:new(asobi_test_game, [passthrough, no_link]),
    meck:expect(asobi_test_game, tick, fun(GS) -> {finished, #{winner => ~"p1"}, GS} end),
    Pid = start_match(#{min_players => 1, max_players => 2, tick_rate => 10}),
    ok = asobi_match_server:join(Pid, ~"p1"),
    wait_for_status(Pid, finished, 60),
    ?assertEqual(finished, maps:get(status, asobi_match_server:get_info(Pid))),

    asobi_match_server:broadcast_event(Pid, game_over, #{winner => ~"p1"}),
    timer:sleep(20),
    ?assert(is_process_alive(Pid)),
    %% Still in `finished`, with its 5s state_timeout `cleanup` pending -
    %% stop the process before tearing down mecks, or the timer fires after
    %% unload and crashes the runner (undef in finished/3), aborting the
    %% rest of the eunit suite (asobi#300/#301 review).
    gen_statem:stop(Pid),
    meck:unload(asobi_test_game),
    cleanup(ok).

%% asobi#462: a vote.cast/vote.veto into a finished match landed on
%% finished/3's catch-all, which swallowed the {call, From} with no reply, so
%% the caller (an infinity gen_statem:call) blocked until the ~5s cleanup
%% timeout. The finished-state vote clauses now reply immediately with
%% not_in_match - the same registered code the dead-fabric path returns.
vote_calls_into_finished_match_error_test() ->
    setup(),
    Pid = start_match(#{min_players => 2, max_players => 2}),
    ok = asobi_match_server:join(Pid, ~"pf1"),
    ok = asobi_match_server:join(Pid, ~"pf2"),
    timer:sleep(50),
    ?assertEqual(running, maps:get(status, asobi_match_server:get_info(Pid))),
    asobi_match_server:cancel(Pid),
    wait_for_status(Pid, finished, 60),
    ?assertEqual(
        {error, not_in_match},
        gen_statem:call(Pid, {cast_vote, ~"pf1", ~"v1", ~"o1"}, 2000)
    ),
    ?assertEqual(
        {error, not_in_match},
        gen_statem:call(Pid, {use_veto, ~"pf1", ~"v1"}, 2000)
    ),
    ?assert(is_process_alive(Pid)),
    gen_statem:stop(Pid),
    cleanup(ok).

%% asobi#469: the finished state enumerated a couple of call clauses and then
%% swallowed every other {call, From} on the catch-all, so a call the finished
%% state did not name (here a reconnect) hung the caller until the ~5s cleanup
%% timeout. A single general call catch-all now replies not_in_match to any
%% unexpected call, and votes into a finished match still return not_in_match.
unexpected_call_to_finished_match_replies_not_in_match_test() ->
    setup(),
    Pid = start_match(#{min_players => 2, max_players => 2}),
    ok = asobi_match_server:join(Pid, ~"pf1"),
    ok = asobi_match_server:join(Pid, ~"pf2"),
    timer:sleep(50),
    ?assertEqual(running, maps:get(status, asobi_match_server:get_info(Pid))),
    asobi_match_server:cancel(Pid),
    wait_for_status(Pid, finished, 60),
    ?assertEqual(
        {error, not_in_match},
        gen_statem:call(Pid, {reconnect, ~"pf1"}, 2000)
    ),
    ?assertEqual(
        {error, not_in_match},
        gen_statem:call(Pid, {cast_vote, ~"pf1", ~"v1", ~"o1"}, 2000)
    ),
    ?assert(is_process_alive(Pid)),
    gen_statem:stop(Pid),
    cleanup(ok).

%% asobi#462: a vote.cast with a non-binary option_id (a JSON number/null)
%% missed running/3's is_binary guard and, with no catch-all there, crashed
%% the whole match on function_clause - every player in it - on one malformed
%% frame. It now degrades to {error, invalid_option} and the match survives.
cast_vote_non_binary_option_does_not_crash_match_test() ->
    setup(),
    Pid = start_match(#{min_players => 2, max_players => 2}),
    ok = asobi_match_server:join(Pid, ~"pnb1"),
    ok = asobi_match_server:join(Pid, ~"pnb2"),
    timer:sleep(50),
    ?assertEqual(running, maps:get(status, asobi_match_server:get_info(Pid))),
    ?assertEqual(
        {error, invalid_option},
        gen_statem:call(Pid, {cast_vote, ~"pnb1", ~"v1", 12345}, 2000)
    ),
    ?assert(is_process_alive(Pid)),
    ?assertEqual(running, maps:get(status, asobi_match_server:get_info(Pid))),
    stop(Pid),
    cleanup(ok).

%% asobi#462 regression guard: a valid option_id is a binary OR a list of
%% binaries (approval/ranked - asobi_vote_server:cast_vote accepts
%% binary() | [binary()]). An earlier is_binary(OptionId)-only guard rejected
%% every list vote as invalid_option before it reached the vote server; the
%% widened guard forwards a list through, and asobi_vote_server accepts a valid
%% one and rejects a bad one - neither path crashes the match.
cast_vote_list_option_reaches_vote_server_test() ->
    setup(),
    ensure_vote_sup(),
    Pid = start_match(#{min_players => 2, max_players => 2}),
    ok = asobi_match_server:join(Pid, ~"pl1"),
    ok = asobi_match_server:join(Pid, ~"pl2"),
    timer:sleep(50),
    ?assertEqual(running, maps:get(status, asobi_match_server:get_info(Pid))),
    {ok, VotePid} = asobi_match_server:start_vote(Pid, #{
        vote_id => ~"v1",
        method => approval,
        options => [#{id => ~"a", label => ~"A"}, #{id => ~"b", label => ~"B"}],
        window_ms => 60000
    }),
    ?assertEqual(ok, gen_statem:call(Pid, {cast_vote, ~"pl1", ~"v1", [~"a", ~"b"]}, 2000)),
    ?assertEqual(
        {error, invalid_option},
        gen_statem:call(Pid, {cast_vote, ~"pl1", ~"v1", [~"a", 123]}, 2000)
    ),
    ?assertEqual(
        {error, invalid_option},
        gen_statem:call(Pid, {cast_vote, ~"pl1", ~"v1", 123}, 2000)
    ),
    ?assert(is_process_alive(Pid)),
    gen_statem:stop(VotePid),
    stop(Pid),
    cleanup(ok).

ensure_vote_sup() ->
    case whereis(asobi_vote_sup) of
        undefined ->
            {ok, _} = asobi_vote_sup:start_link(),
            ok;
        _ ->
            ok
    end.

empty_phases_does_not_finish_test() ->
    %% Inject phases/1 that returns []. Before the fix, the match would
    %% transition to `finished` on the first tick because asobi_phase:init([])
    %% returns a state with status=complete. Mirrors
    %% asobi_world_server_tests:empty_phases_does_not_finish/0.
    setup(),
    meck:new(asobi_test_game, [passthrough, non_strict, no_link]),
    meck:expect(asobi_test_game, phases, fun(_GameConfig) -> [] end),
    Pid = start_match(#{min_players => 1, max_players => 2, tick_rate => 10}),
    ok = asobi_match_server:join(Pid, ~"p1"),
    timer:sleep(100),
    ?assertEqual(running, maps:get(status, asobi_match_server:get_info(Pid))),
    gen_statem:stop(Pid),
    meck:unload(asobi_test_game),
    cleanup(ok).

%% --- player stats on match completion (asobi#329) ---

%% player_stats had an insert on signup, a delete on guest reap, and nothing
%% in between: every account's games_played sat at 0 forever because no code
%% path ever issued an UPDATE.

finished_match_counts_each_participant_once_test() ->
    setup(),
    Pid = start_match(#{min_players => 2, max_players => 4, tick_rate => 10}),
    ok = asobi_match_server:join(Pid, ~"p1"),
    ok = asobi_match_server:join(Pid, ~"p2"),
    wait_for_status(Pid, running, 60),
    asobi_match_server:cancel(Pid),
    wait_for_status(Pid, finished, 60),
    gen_statem:stop(Pid),
    %% One row per participant, no more: entering `finished` is the only
    %% place that counts, and it happens once per match.
    ?assertEqual([{~"p1", 0, 0}], ets:lookup(?STATS_TAB, ~"p1")),
    ?assertEqual([{~"p2", 0, 0}], ets:lookup(?STATS_TAB, ~"p2")),
    ?assertEqual(2, ets:info(?STATS_TAB, size)),
    cleanup(ok).

finished_match_records_winner_and_loser_test() ->
    setup(),
    meck:new(asobi_test_game, [passthrough, no_link]),
    meck:expect(asobi_test_game, tick, fun(GS) -> {finished, #{winner => ~"p1"}, GS} end),
    Pid = start_match(#{min_players => 2, max_players => 2, tick_rate => 10}),
    ok = asobi_match_server:join(Pid, ~"p1"),
    ok = asobi_match_server:join(Pid, ~"p2"),
    wait_for_status(Pid, finished, 60),
    gen_statem:stop(Pid),
    meck:unload(asobi_test_game),
    ?assertEqual([{~"p1", 1, 0}], ets:lookup(?STATS_TAB, ~"p1")),
    ?assertEqual([{~"p2", 0, 1}], ets:lookup(?STATS_TAB, ~"p2")),
    cleanup(ok).

%% The match record's primary key is the match id, so a match that already
%% finished loses the insert and must not move the counters a second time.
duplicate_match_record_leaves_stats_alone_test() ->
    setup(),
    meck:expect(asobi_repo, insert, fun(_CS) -> {error, duplicate_key} end),
    Pid = start_match(#{min_players => 2, max_players => 4, tick_rate => 10}),
    ok = asobi_match_server:join(Pid, ~"p1"),
    ok = asobi_match_server:join(Pid, ~"p2"),
    wait_for_status(Pid, running, 60),
    asobi_match_server:cancel(Pid),
    wait_for_status(Pid, finished, 60),
    gen_statem:stop(Pid),
    ?assertEqual(0, ets:info(?STATS_TAB, size)),
    cleanup(ok).

wait_for_status(_Pid, _Status, 0) ->
    error(timeout_waiting_for_status);
wait_for_status(Pid, Status, N) ->
    case maps:get(status, asobi_match_server:get_info(Pid), undefined) of
        Status ->
            ok;
        _ ->
            timer:sleep(20),
            wait_for_status(Pid, Status, N - 1)
    end.
