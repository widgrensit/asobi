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
    ?assert(meck:called(asobi_presence, send, [~"p1", {match_joined, Match}])),
    ?assert(failed_notified(~"p1")),
    ?assert(failed_notified(~"p3")).

live_match_notifies_all() ->
    meck:reset(asobi_presence),
    Match = fake_match(fun
        (get_info) -> {reply, #{match_id => ~"match-2"}};
        ({join, _, _}) -> {reply, ok}
    end),
    ?assertEqual(ok, asobi_matchmaker:join_matched_players(Match, ~"m1", [~"p1", ~"p2"])),
    ?assert(meck:called(asobi_presence, send, [~"p1", {match_joined, Match}])),
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
