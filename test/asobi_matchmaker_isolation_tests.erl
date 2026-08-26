-module(asobi_matchmaker_isolation_tests).
-include_lib("eunit/include/eunit.hrl").

setup() ->
    {ok, _} = application:ensure_all_started(telemetry),
    meck:new(asobi_presence, [non_strict, no_link]),
    meck:expect(asobi_presence, send, fun(_PlayerId, _Msg) -> ok end),
    ok.

cleanup(_) ->
    meck:unload(asobi_presence),
    ok.

join_isolation_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        {"a match gone before the fan-out never raises", fun match_gone_before_fanout/0},
        {"a match that exits mid fan-out never raises", fun match_exits_mid_fanout/0},
        {"a live match joins and notifies every player", fun live_match_notifies_all/0}
    ]}.

match_gone_before_fanout() ->
    meck:reset(asobi_presence),
    Dead = spawn(fun() -> ok end),
    wait_gone(Dead, 50),
    ?assertEqual(
        ok, asobi_matchmaker:join_matched_players(Dead, ~"m1", [~"p1", ~"p2"])
    ),
    ?assert(failed_notified(~"p1")),
    ?assert(failed_notified(~"p2")).

match_exits_mid_fanout() ->
    meck:reset(asobi_presence),
    Match = fake_match(fun
        (get_info) -> {reply, #{match_id => ~"match-1"}};
        ({join, ~"p2", _}) -> die;
        ({join, _, _}) -> {reply, ok}
    end),
    ?assertEqual(
        ok, asobi_matchmaker:join_matched_players(Match, ~"m1", [~"p1", ~"p2", ~"p3"])
    ),
    %% `match_joined` is the match server's to send, on the join it accepted.
    %% What the fan-out owns is the `matched` event, so that is what is
    %% asserted here - a fake match never sends the other half.
    ?assert(
        meck:called(asobi_presence, send, [
            ~"p1", {match_event, matched, '_'}
        ])
    ),
    ?assert(failed_notified(~"p1")),
    ?assert(failed_notified(~"p3")).

live_match_notifies_all() ->
    meck:reset(asobi_presence),
    Match = fake_match(fun
        (get_info) -> {reply, #{match_id => ~"match-2"}};
        ({join, _, _}) -> {reply, ok}
    end),
    ?assertEqual(ok, asobi_matchmaker:join_matched_players(Match, ~"m1", [~"p1", ~"p2"])),
    %% `match_joined` is the match server's to send, on the join it accepted.
    %% What the fan-out owns is the `matched` event, so that is what is
    %% asserted here - a fake match never sends the other half.
    ?assert(
        meck:called(asobi_presence, send, [
            ~"p1", {match_event, matched, '_'}
        ])
    ),
    ?assert(
        meck:called(asobi_presence, send, [
            ~"p2", {match_event, matched, #{match_id => ~"match-2", players => [~"p1", ~"p2"]}}
        ])
    ),
    ?assertNot(failed_notified(~"p1")),
    exit(Match, kill).

failed_notified(PlayerId) ->
    meck:called(asobi_presence, send, [
        PlayerId, {match_event, matchmaker_failed, #{reason => ~"match_start_failed"}}
    ]).

fake_match(Fun) ->
    spawn(fun() -> fake_loop(Fun) end).

fake_loop(Fun) ->
    receive
        {'$gen_call', From, Req} ->
            case Fun(Req) of
                {reply, Reply} ->
                    gen_statem:reply(From, Reply),
                    fake_loop(Fun);
                die ->
                    exit(shutdown)
            end
    end.

wait_gone(_Pid, 0) ->
    ok;
wait_gone(Pid, N) ->
    case is_process_alive(Pid) of
        false ->
            ok;
        true ->
            timer:sleep(5),
            wait_gone(Pid, N - 1)
    end.

%% A player who disconnects between taking a ticket and the group forming used
%% to be seated in the world anyway, with `session_pid => undefined` and no
%% monitor - and could then never leave, because `find_player_by_pid/2` matches
%% on `session_pid =:= Pid` and `undefined` is never a pid. No DOWN, so no
%% `handle_leave/2`, so `map_size(Players)` never reached 0 and the world
%% ticked forever around someone who was not there. World-side twin of
%% widgrensit/asobi#280.
phantom_player_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        {"an offline matched player is not seated", fun offline_player_not_seated/0},
        {"an offline matched player is counted", fun offline_player_is_counted/0},
        {"an online matched player is seated", fun online_player_seated/0}
    ]}.

with_world_server(Fun) ->
    %% `passthrough`, not `non_strict`: a non_strict mock accepts an expectation
    %% for a function that does not exist, so a rename or an arity change would
    %% break join_if_present/3 in production while these tests stayed green
    %% against a stub of a function that is gone.
    meck:new(asobi_world_server, [passthrough, no_link]),
    Self = self(),
    meck:expect(asobi_world_server, join, fun(_WorldPid, PlayerId) ->
        Self ! {joined, PlayerId},
        ok
    end),
    try
        Fun()
    after
        meck:unload(asobi_world_server)
    end.

joined(PlayerId) ->
    receive
        {joined, PlayerId} -> true
    after 100 -> false
    end.

offline_player_not_seated() ->
    meck:expect(asobi_presence, get_status, fun(_PlayerId) -> offline end),
    with_world_server(fun() ->
        ?assertEqual(
            offline,
            asobi_matchmaker:join_if_present(self(), ~"gone_p1", ~"m1")
        ),
        ?assertNot(joined(~"gone_p1"))
    end).

offline_player_is_counted() ->
    meck:expect(asobi_presence, get_status, fun(_PlayerId) -> offline end),
    Handler = ?FUNCTION_NAME,
    Self = self(),
    %% `[asobi, matchmaker, dropped]`, not `[asobi, error]`: disconnecting while
    %% queued is routine on mobile, and counting it as an error would make the
    %% node's error rate track connection churn.
    ok = telemetry:attach(
        Handler,
        [asobi, matchmaker, dropped],
        fun(_E, _M, Meta, _C) -> Self ! {dropped, Meta} end,
        undefined
    ),
    try
        with_world_server(fun() ->
            offline = asobi_matchmaker:join_if_present(self(), ~"gone_p2", ~"m1")
        end),
        receive
            {dropped, #{mode := ~"m1", reason := no_live_session}} -> ok
        after 500 ->
            ?assert(false)
        end
    after
        telemetry:detach(Handler)
    end.

online_player_seated() ->
    meck:expect(asobi_presence, get_status, fun(_PlayerId) -> online end),
    with_world_server(fun() ->
        ?assertEqual(ok, asobi_matchmaker:join_if_present(self(), ~"live_p1", ~"m1")),
        ?assert(joined(~"live_p1"))
    end).

%% The world is built BEFORE anyone joins, and asobi_world_server decides it is
%% empty in exactly one place - handle_leave/2, reachable only from an explicit
%% leave or a session DOWN. A world whose roster was never populated therefore
%% never arms empty_grace and never reaches `finished`: it ticks its whole zone
%% grid forever. Screening the departed players out of the join turns one
%% unremovable seat into zero seats, which is the same terminal state - so the
%% count has to be acted on.
unoccupied_world_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        {"a world nobody was seated in is discarded", fun unoccupied_world_discarded/0},
        {"a world with someone in it is kept", fun occupied_world_kept/0}
    ]}.

with_instance_sup(Fun) ->
    meck:new(supervisor, [unstick, passthrough, no_link]),
    Self = self(),
    try
        meck:expect(supervisor, terminate_child, fun
            (asobi_world_instance_sup, Pid) ->
                Self ! {terminated, Pid},
                ok;
            (Sup, Pid) ->
                meck:passthrough([Sup, Pid])
        end),
        Fun()
    after
        meck:unload(supervisor)
    end.

terminated(Pid) ->
    receive
        {terminated, Pid} -> true
    after 200 -> false
    end.

unoccupied_world_discarded() ->
    Instance = spawn(fun() ->
        receive
            stop -> ok
        end
    end),
    with_instance_sup(fun() ->
        ok = asobi_matchmaker:discard_unoccupied(0, Instance, ~"m1", ~"w1"),
        ?assert(terminated(Instance))
    end),
    exit(Instance, kill).

occupied_world_kept() ->
    Instance = spawn(fun() ->
        receive
            stop -> ok
        end
    end),
    with_instance_sup(fun() ->
        ok = asobi_matchmaker:discard_unoccupied(1, Instance, ~"m1", ~"w1"),
        ?assertNot(terminated(Instance))
    end),
    exit(Instance, kill).
