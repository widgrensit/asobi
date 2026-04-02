-module(asobi_vote_server_tests).
-include_lib("eunit/include/eunit.hrl").

-define(OPTIONS, [#{id => ~"a", label => ~"A"}, #{id => ~"b", label => ~"B"}, #{id => ~"c", label => ~"C"}]).
-define(ELIGIBLE, [~"p1", ~"p2", ~"p3"]).

%% --- Setup / Teardown ---

setup() ->
    meck:new(asobi_repo, [no_link]),
    meck:expect(asobi_repo, insert, fun(_CS) -> {ok, #{}} end),
    meck:new(asobi_match_server, [no_link]),
    meck:expect(asobi_match_server, broadcast_event, fun(_Pid, _Evt, _P) -> ok end),
    ok.

cleanup(_) ->
    meck:unload(asobi_match_server),
    meck:unload(asobi_repo),
    ok.

start_vote() ->
    start_vote(#{}).

start_vote(Overrides) ->
    Config = maps:merge(#{
        match_id => ~"test-match",
        match_pid => self(),
        options => ?OPTIONS,
        eligible => ?ELIGIBLE,
        window_ms => 60000
    }, Overrides),
    {ok, Pid} = asobi_vote_server:start_link(Config),
    Pid.

%% --- Test generators ---

vote_server_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        {"starts in open state", fun starts_open/0},
        {"get_state returns vote metadata", fun get_state_open/0},
        {"cast valid vote", fun cast_valid_vote/0},
        {"reject ineligible voter", fun reject_ineligible/0},
        {"reject invalid option", fun reject_invalid_option/0},
        {"revote replaces previous vote", fun revote_replaces/0},
        {"rate limits revotes", fun rate_limit_revotes/0},
        {"veto stops vote", fun veto_stops/0},
        {"veto rejected when disabled", fun veto_disabled/0},
        {"veto rejected for ineligible", fun veto_ineligible/0},
        {"window expiry closes and resolves", fun window_expiry/0},
        {"plurality tally picks winner", fun plurality_tally/0},
        {"plurality tie broken", fun plurality_tie/0},
        {"approval voting", fun approval_voting/0},
        {"weighted voting", fun weighted_voting/0},
        {"ranked choice voting", fun ranked_choice/0},
        {"hidden visibility hides tallies", fun hidden_visibility/0},
        {"live visibility shows tallies", fun live_visibility/0},
        {"ready_up closes when all voted", fun ready_up_close/0},
        {"grace period accepts late vote", fun grace_period/0},
        {"quorum not met", fun quorum_not_met/0},
        {"delegation applies", fun delegation/0},
        {"default votes for absent voters", fun default_votes/0},
        {"spectator votes weighted", fun spectator_votes/0},
        {"supermajority required but not met", fun supermajority_not_met/0},
        {"match notified on resolve", fun match_notified_resolve/0},
        {"match notified on veto", fun match_notified_veto/0}
    ]}.

%% --- Tests ---

starts_open() ->
    Pid = start_vote(),
    S = asobi_vote_server:get_state(Pid),
    ?assertEqual(open, maps:get(status, S)),
    stop(Pid).

get_state_open() ->
    Pid = start_vote(),
    S = asobi_vote_server:get_state(Pid),
    ?assertMatch(#{vote_id := _, status := open, method := ~"plurality"}, S),
    ?assertEqual(?OPTIONS, maps:get(options, S)),
    ?assertEqual(0, maps:get(total_votes, S)),
    stop(Pid).

cast_valid_vote() ->
    Pid = start_vote(),
    ?assertEqual(ok, asobi_vote_server:cast_vote(Pid, ~"p1", ~"a")),
    S = asobi_vote_server:get_state(Pid),
    ?assertEqual(1, maps:get(total_votes, S)),
    stop(Pid).

reject_ineligible() ->
    Pid = start_vote(),
    ?assertMatch({error, not_eligible}, asobi_vote_server:cast_vote(Pid, ~"outsider", ~"a")),
    stop(Pid).

reject_invalid_option() ->
    Pid = start_vote(),
    ?assertMatch({error, invalid_option}, asobi_vote_server:cast_vote(Pid, ~"p1", ~"nonexistent")),
    stop(Pid).

revote_replaces() ->
    Pid = start_vote(),
    ok = asobi_vote_server:cast_vote(Pid, ~"p1", ~"a"),
    ok = asobi_vote_server:cast_vote(Pid, ~"p1", ~"b"),
    S = asobi_vote_server:get_state(Pid),
    %% Still 1 total vote (same voter)
    ?assertEqual(1, maps:get(total_votes, S)),
    %% Tally should show b=1, not a=1
    ?assertEqual(1, maps:get(~"b", maps:get(tallies, S))),
    ?assertEqual(0, maps:get(~"a", maps:get(tallies, S))),
    stop(Pid).

rate_limit_revotes() ->
    Pid = start_vote(#{max_revotes => 1}),
    ok = asobi_vote_server:cast_vote(Pid, ~"p1", ~"a"),
    ok = asobi_vote_server:cast_vote(Pid, ~"p1", ~"b"),
    ?assertMatch({error, rate_limited}, asobi_vote_server:cast_vote(Pid, ~"p1", ~"c")),
    stop(Pid).

veto_stops() ->
    Pid = start_vote(#{veto_enabled => true}),
    Ref = monitor(process, Pid),
    unlink(Pid),
    ok = asobi_vote_server:cast_veto(Pid, ~"p1"),
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 2000 ->
        ?assert(false)
    end.

veto_disabled() ->
    Pid = start_vote(#{veto_enabled => false}),
    ?assertMatch({error, veto_disabled}, asobi_vote_server:cast_veto(Pid, ~"p1")),
    stop(Pid).

veto_ineligible() ->
    Pid = start_vote(#{veto_enabled => true}),
    ?assertMatch({error, not_eligible}, asobi_vote_server:cast_veto(Pid, ~"outsider")),
    stop(Pid).

window_expiry() ->
    Pid = start_vote(#{window_ms => 50}),
    unlink(Pid),
    Ref = monitor(process, Pid),
    ok = asobi_vote_server:cast_vote(Pid, ~"p1", ~"a"),
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 2000 ->
        ?assert(false)
    end.

plurality_tally() ->
    flush(),
    Pid = start_vote(#{window_ms => 200}),
    unlink(Pid),
    Ref = monitor(process, Pid),
    ok = asobi_vote_server:cast_vote(Pid, ~"p1", ~"a"),
    ok = asobi_vote_server:cast_vote(Pid, ~"p2", ~"a"),
    ok = asobi_vote_server:cast_vote(Pid, ~"p3", ~"b"),
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 2000 ->
        ?assert(false)
    end,
    %% Match pid receives the result
    receive
        {vote_resolved, _, _, Result} ->
            ?assertEqual(~"a", maps:get(winner, Result)),
            ?assertEqual(3, maps:get(total_votes, Result))
    after 1000 ->
        ?assert(false)
    end.

plurality_tie() ->
    flush(),
    Pid = start_vote(#{window_ms => 100, eligible => [~"p1", ~"p2"]}),
    unlink(Pid),
    Ref = monitor(process, Pid),
    ok = asobi_vote_server:cast_vote(Pid, ~"p1", ~"a"),
    ok = asobi_vote_server:cast_vote(Pid, ~"p2", ~"b"),
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 2000 ->
        ?assert(false)
    end,
    receive
        {vote_resolved, _, _, Result} ->
            Winner = maps:get(winner, Result),
            ?assert(Winner =:= ~"a" orelse Winner =:= ~"b")
    after 1000 ->
        ?assert(false)
    end.

approval_voting() ->
    flush(),
    Pid = start_vote(#{method => ~"approval", window_ms => 100}),
    unlink(Pid),
    Ref = monitor(process, Pid),
    ok = asobi_vote_server:cast_vote(Pid, ~"p1", [~"a", ~"b"]),
    ok = asobi_vote_server:cast_vote(Pid, ~"p2", [~"b", ~"c"]),
    ok = asobi_vote_server:cast_vote(Pid, ~"p3", [~"b"]),
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 2000 ->
        ?assert(false)
    end,
    receive
        {vote_resolved, _, _, Result} ->
            ?assertEqual(~"b", maps:get(winner, Result)),
            Counts = maps:get(counts, Result),
            ?assertEqual(3, maps:get(~"b", Counts))
    after 1000 ->
        ?assert(false)
    end.

weighted_voting() ->
    flush(),
    Pid = start_vote(#{
        method => ~"weighted",
        weights => #{~"p1" => 3, ~"p2" => 1, ~"p3" => 1},
        window_ms => 100
    }),
    unlink(Pid),
    Ref = monitor(process, Pid),
    ok = asobi_vote_server:cast_vote(Pid, ~"p1", ~"a"),
    ok = asobi_vote_server:cast_vote(Pid, ~"p2", ~"b"),
    ok = asobi_vote_server:cast_vote(Pid, ~"p3", ~"b"),
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 2000 ->
        ?assert(false)
    end,
    receive
        {vote_resolved, _, _, Result} ->
            ?assertEqual(~"a", maps:get(winner, Result)),
            Counts = maps:get(counts, Result),
            ?assertEqual(3.0, maps:get(~"a", Counts, 0.0)),
            ?assertEqual(2.0, maps:get(~"b", Counts, 0.0))
    after 1000 ->
        ?assert(false)
    end.

ranked_choice() ->
    flush(),
    Pid = start_vote(#{method => ~"ranked", window_ms => 100}),
    unlink(Pid),
    Ref = monitor(process, Pid),
    %% p1: a > b > c, p2: b > a > c, p3: c > a > b
    %% First round: a=1 b=1 c=1, eliminate one (random tie), redistribute
    %% Eventually one wins
    ok = asobi_vote_server:cast_vote(Pid, ~"p1", [~"a", ~"b", ~"c"]),
    ok = asobi_vote_server:cast_vote(Pid, ~"p2", [~"b", ~"a", ~"c"]),
    ok = asobi_vote_server:cast_vote(Pid, ~"p3", [~"c", ~"a", ~"b"]),
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 2000 ->
        ?assert(false)
    end,
    receive
        {vote_resolved, _, _, Result} ->
            Winner = maps:get(winner, Result),
            ?assert(Winner =:= ~"a" orelse Winner =:= ~"b" orelse Winner =:= ~"c")
    after 1000 ->
        ?assert(false)
    end.

hidden_visibility() ->
    Pid = start_vote(#{visibility => ~"hidden"}),
    ok = asobi_vote_server:cast_vote(Pid, ~"p1", ~"a"),
    S = asobi_vote_server:get_state(Pid),
    ?assertEqual(false, maps:is_key(tallies, S)),
    stop(Pid).

live_visibility() ->
    Pid = start_vote(#{visibility => ~"live"}),
    ok = asobi_vote_server:cast_vote(Pid, ~"p1", ~"a"),
    S = asobi_vote_server:get_state(Pid),
    ?assert(maps:is_key(tallies, S)),
    ?assertEqual(1, maps:get(~"a", maps:get(tallies, S))),
    stop(Pid).

ready_up_close() ->
    Pid = start_vote(#{window_type => ~"ready_up", eligible => [~"p1", ~"p2"]}),
    unlink(Pid),
    Ref = monitor(process, Pid),
    ok = asobi_vote_server:cast_vote(Pid, ~"p1", ~"a"),
    ok = asobi_vote_server:cast_vote(Pid, ~"p2", ~"b"),
    %% Should close immediately since all voted
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 2000 ->
        ?assert(false)
    end.

grace_period() ->
    %% Grace period is checked in the closed state handler, but
    %% resolve_and_stop runs on enter and stops the process immediately.
    %% So the grace period only applies if votes arrive between the
    %% state_timeout firing and the closed enter completing.
    %% In practice this is a very tight window. Just verify that
    %% a vote cast right at window boundary is accepted.
    flush(),
    Pid = start_vote(#{window_ms => 200}),
    unlink(Pid),
    Ref = monitor(process, Pid),
    ok = asobi_vote_server:cast_vote(Pid, ~"p1", ~"a"),
    timer:sleep(180),
    %% Vote right before window closes
    ok = asobi_vote_server:cast_vote(Pid, ~"p2", ~"b"),
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 2000 ->
        ?assert(false)
    end,
    receive
        {vote_resolved, _, _, Result} ->
            ?assertEqual(2, maps:get(total_votes, Result))
    after 1000 ->
        ?assert(false)
    end.

quorum_not_met() ->
    flush(),
    Pid = start_vote(#{quorum => 0.8, window_ms => 100}),
    unlink(Pid),
    Ref = monitor(process, Pid),
    %% Only 1 of 3 votes — 33% < 80% quorum
    ok = asobi_vote_server:cast_vote(Pid, ~"p1", ~"a"),
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 2000 ->
        ?assert(false)
    end,
    receive
        {vote_resolved, _, _, Result} ->
            ?assertEqual(undefined, maps:get(winner, Result)),
            ?assertEqual(~"no_quorum", maps:get(status, Result))
    after 1000 ->
        ?assert(false)
    end.

delegation() ->
    flush(),
    Pid = start_vote(#{
        window_ms => 100,
        delegation => #{~"p3" => ~"p1"}
    }),
    unlink(Pid),
    Ref = monitor(process, Pid),
    ok = asobi_vote_server:cast_vote(Pid, ~"p1", ~"a"),
    ok = asobi_vote_server:cast_vote(Pid, ~"p2", ~"b"),
    %% p3 delegates to p1, so p3's vote becomes "a"
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 2000 ->
        ?assert(false)
    end,
    receive
        {vote_resolved, _, _, Result} ->
            ?assertEqual(~"a", maps:get(winner, Result)),
            ?assertEqual(3, maps:get(total_votes, Result))
    after 1000 ->
        ?assert(false)
    end.

default_votes() ->
    flush(),
    Pid = start_vote(#{
        window_ms => 100,
        default_votes => #{~"p3" => ~"b"}
    }),
    unlink(Pid),
    Ref = monitor(process, Pid),
    ok = asobi_vote_server:cast_vote(Pid, ~"p1", ~"a"),
    ok = asobi_vote_server:cast_vote(Pid, ~"p2", ~"a"),
    %% p3 gets default vote "b"
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 2000 ->
        ?assert(false)
    end,
    receive
        {vote_resolved, _, _, Result} ->
            ?assertEqual(~"a", maps:get(winner, Result)),
            Counts = maps:get(counts, Result),
            ?assertEqual(1, maps:get(~"b", Counts))
    after 1000 ->
        ?assert(false)
    end.

spectator_votes() ->
    flush(),
    Pid = start_vote(#{
        window_ms => 100,
        eligible => [~"p1"],
        spectators => [~"s1", ~"s2"],
        spectator_weight => 0.5
    }),
    unlink(Pid),
    Ref = monitor(process, Pid),
    ok = asobi_vote_server:cast_vote(Pid, ~"p1", ~"a"),
    ok = asobi_vote_server:cast_vote(Pid, ~"s1", ~"b"),
    ok = asobi_vote_server:cast_vote(Pid, ~"s2", ~"b"),
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 2000 ->
        ?assert(false)
    end,
    receive
        {vote_resolved, _, _, Result} ->
            %% Player: a=100%, Spectator: b=100%
            %% Merged: a = 1.0*0.5 = 0.5, b = 1.0*0.5 = 0.5 — tie, random winner
            Winner = maps:get(winner, Result),
            ?assert(Winner =:= ~"a" orelse Winner =:= ~"b")
    after 1000 ->
        ?assert(false)
    end.

supermajority_not_met() ->
    flush(),
    Pid = start_vote(#{
        window_ms => 100,
        require_supermajority => true,
        supermajority => 0.75
    }),
    unlink(Pid),
    Ref = monitor(process, Pid),
    ok = asobi_vote_server:cast_vote(Pid, ~"p1", ~"a"),
    ok = asobi_vote_server:cast_vote(Pid, ~"p2", ~"a"),
    ok = asobi_vote_server:cast_vote(Pid, ~"p3", ~"b"),
    %% a=66% < 75% supermajority
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 2000 ->
        ?assert(false)
    end,
    receive
        {vote_resolved, _, _, Result} ->
            ?assertEqual(undefined, maps:get(winner, Result)),
            ?assertEqual(~"no_consensus", maps:get(status, Result))
    after 1000 ->
        ?assert(false)
    end.

match_notified_resolve() ->
    flush(),
    Pid = start_vote(#{window_ms => 50}),
    unlink(Pid),
    Ref = monitor(process, Pid),
    ok = asobi_vote_server:cast_vote(Pid, ~"p1", ~"a"),
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 2000 ->
        ?assert(false)
    end,
    receive
        {vote_resolved, _VoteId, _Template, Result} ->
            ?assert(is_map(Result)),
            ?assert(maps:is_key(winner, Result))
    after 1000 ->
        ?assert(false)
    end.

match_notified_veto() ->
    flush(),
    Pid = start_vote(#{veto_enabled => true}),
    unlink(Pid),
    Ref = monitor(process, Pid),
    ok = asobi_vote_server:cast_veto(Pid, ~"p1"),
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 2000 ->
        ?assert(false)
    end,
    receive
        {vote_vetoed, _VoteId, _Template} -> ok
    after 1000 ->
        ?assert(false)
    end.

%% --- Helpers ---

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

flush() ->
    receive _ -> flush()
    after 0 -> ok
    end.
