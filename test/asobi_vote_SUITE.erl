-module(asobi_vote_SUITE).

-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([
    vote_lifecycle_plurality/1,
    vote_tie_random/1,
    vote_window_expires/1,
    vote_ineligible_voter/1,
    vote_invalid_option/1,
    vote_change_during_window/1,
    vote_veto/1,
    vote_veto_disabled/1,
    vote_approval_method/1,
    vote_via_match_server/1,
    vote_hidden_visibility/1,
    vote_no_votes_cast/1
]).

all() ->
    [
        vote_lifecycle_plurality,
        vote_tie_random,
        vote_window_expires,
        vote_ineligible_voter,
        vote_invalid_option,
        vote_change_during_window,
        vote_veto,
        vote_veto_disabled,
        vote_approval_method,
        vote_via_match_server,
        vote_hidden_visibility,
        vote_no_votes_cast
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(asobi),
    Config.

end_per_suite(Config) ->
    Config.

%% --- Tests ---

vote_lifecycle_plurality(_Config) ->
    Options = [
        #{id => ~"opt_a", label => ~"Path A"},
        #{id => ~"opt_b", label => ~"Path B"},
        #{id => ~"opt_c", label => ~"Path C"}
    ],
    {ok, MatchPid} = start_test_match(),
    {ok, VotePid} = asobi_vote_sup:start_vote(#{
        match_id => asobi_id:generate(),
        match_pid => MatchPid,
        options => Options,
        eligible => [~"p1", ~"p2", ~"p3"],
        window_ms => 5000,
        method => ~"plurality",
        visibility => ~"live"
    }),
    ?assert(is_pid(VotePid)),
    ok = asobi_vote_server:cast_vote(VotePid, ~"p1", ~"opt_a"),
    ok = asobi_vote_server:cast_vote(VotePid, ~"p2", ~"opt_a"),
    ok = asobi_vote_server:cast_vote(VotePid, ~"p3", ~"opt_b"),
    Info = asobi_vote_server:get_state(VotePid),
    ?assertMatch(#{status := open, total_votes := 3}, Info),
    ?assertMatch(#{tallies := #{~"opt_a" := 2, ~"opt_b" := 1, ~"opt_c" := 0}}, Info).

vote_tie_random(_Config) ->
    Options = [
        #{id => ~"opt_a", label => ~"A"},
        #{id => ~"opt_b", label => ~"B"}
    ],
    {ok, MatchPid} = start_test_match(),
    {ok, VotePid} = asobi_vote_sup:start_vote(#{
        match_id => asobi_id:generate(),
        match_pid => MatchPid,
        options => Options,
        eligible => [~"p1", ~"p2"],
        window_ms => 200,
        method => ~"plurality",
        tie_breaker => ~"random"
    }),
    ok = asobi_vote_server:cast_vote(VotePid, ~"p1", ~"opt_a"),
    ok = asobi_vote_server:cast_vote(VotePid, ~"p2", ~"opt_b"),
    Ref = monitor(process, VotePid),
    receive
        {'DOWN', Ref, process, VotePid, normal} -> ok
    after 2000 ->
        error(vote_did_not_resolve)
    end,
    %% Vote resolved — winner is one of the tied options
    %% We can't check directly since the process is dead, but it didn't crash
    ok.

vote_window_expires(_Config) ->
    Options = [#{id => ~"opt_a", label => ~"A"}],
    {ok, MatchPid} = start_test_match(),
    {ok, VotePid} = asobi_vote_sup:start_vote(#{
        match_id => asobi_id:generate(),
        match_pid => MatchPid,
        options => Options,
        eligible => [~"p1"],
        window_ms => 100
    }),
    Ref = monitor(process, VotePid),
    receive
        {'DOWN', Ref, process, VotePid, normal} -> ok
    after 2000 ->
        error(vote_did_not_expire)
    end.

vote_ineligible_voter(_Config) ->
    Options = [#{id => ~"opt_a", label => ~"A"}],
    {ok, MatchPid} = start_test_match(),
    {ok, VotePid} = asobi_vote_sup:start_vote(#{
        match_id => asobi_id:generate(),
        match_pid => MatchPid,
        options => Options,
        eligible => [~"p1"],
        window_ms => 5000
    }),
    ?assertMatch(
        {error, not_eligible}, asobi_vote_server:cast_vote(VotePid, ~"outsider", ~"opt_a")
    ).

vote_invalid_option(_Config) ->
    Options = [#{id => ~"opt_a", label => ~"A"}],
    {ok, MatchPid} = start_test_match(),
    {ok, VotePid} = asobi_vote_sup:start_vote(#{
        match_id => asobi_id:generate(),
        match_pid => MatchPid,
        options => Options,
        eligible => [~"p1"],
        window_ms => 5000
    }),
    ?assertMatch(
        {error, invalid_option}, asobi_vote_server:cast_vote(VotePid, ~"p1", ~"nonexistent")
    ).

vote_change_during_window(_Config) ->
    Options = [
        #{id => ~"opt_a", label => ~"A"},
        #{id => ~"opt_b", label => ~"B"}
    ],
    {ok, MatchPid} = start_test_match(),
    {ok, VotePid} = asobi_vote_sup:start_vote(#{
        match_id => asobi_id:generate(),
        match_pid => MatchPid,
        options => Options,
        eligible => [~"p1"],
        window_ms => 5000,
        visibility => ~"live"
    }),
    ok = asobi_vote_server:cast_vote(VotePid, ~"p1", ~"opt_a"),
    Info1 = asobi_vote_server:get_state(VotePid),
    ?assertMatch(#{tallies := #{~"opt_a" := 1, ~"opt_b" := 0}}, Info1),
    %% Change vote
    ok = asobi_vote_server:cast_vote(VotePid, ~"p1", ~"opt_b"),
    Info2 = asobi_vote_server:get_state(VotePid),
    ?assertMatch(#{tallies := #{~"opt_a" := 0, ~"opt_b" := 1}}, Info2).

vote_veto(_Config) ->
    Options = [#{id => ~"opt_a", label => ~"A"}],
    {ok, MatchPid} = start_test_match(),
    {ok, VotePid} = asobi_vote_sup:start_vote(#{
        match_id => asobi_id:generate(),
        match_pid => MatchPid,
        options => Options,
        eligible => [~"p1", ~"p2"],
        window_ms => 5000,
        veto_enabled => true
    }),
    Ref = monitor(process, VotePid),
    ok = asobi_vote_server:cast_veto(VotePid, ~"p1"),
    receive
        {'DOWN', Ref, process, VotePid, normal} -> ok
    after 1000 ->
        error(veto_did_not_stop)
    end.

vote_veto_disabled(_Config) ->
    Options = [#{id => ~"opt_a", label => ~"A"}],
    {ok, MatchPid} = start_test_match(),
    {ok, VotePid} = asobi_vote_sup:start_vote(#{
        match_id => asobi_id:generate(),
        match_pid => MatchPid,
        options => Options,
        eligible => [~"p1"],
        window_ms => 5000,
        veto_enabled => false
    }),
    ?assertMatch({error, veto_disabled}, asobi_vote_server:cast_veto(VotePid, ~"p1")).

vote_approval_method(_Config) ->
    Options = [
        #{id => ~"opt_a", label => ~"A"},
        #{id => ~"opt_b", label => ~"B"},
        #{id => ~"opt_c", label => ~"C"}
    ],
    {ok, MatchPid} = start_test_match(),
    {ok, VotePid} = asobi_vote_sup:start_vote(#{
        match_id => asobi_id:generate(),
        match_pid => MatchPid,
        options => Options,
        eligible => [~"p1", ~"p2"],
        window_ms => 200,
        method => ~"approval"
    }),
    %% Approval voting: vote value is a list of approved options
    ok = asobi_vote_server:cast_vote(VotePid, ~"p1", [~"opt_a", ~"opt_b"]),
    ok = asobi_vote_server:cast_vote(VotePid, ~"p2", [~"opt_b", ~"opt_c"]),
    Ref = monitor(process, VotePid),
    receive
        {'DOWN', Ref, process, VotePid, normal} -> ok
    after 2000 ->
        error(vote_did_not_resolve)
    end.

vote_via_match_server(_Config) ->
    Options = [
        #{id => ~"opt_a", label => ~"A"},
        #{id => ~"opt_b", label => ~"B"}
    ],
    {ok, MatchPid} = asobi_match_sup:start_match(#{
        game_module => asobi_test_game,
        min_players => 2,
        max_players => 4,
        tick_rate => 50
    }),
    ok = asobi_match_server:join(MatchPid, ~"p1"),
    ok = asobi_match_server:join(MatchPid, ~"p2"),
    timer:sleep(100),
    VoteId = asobi_id:generate(),
    {ok, _VotePid} = asobi_match_server:start_vote(MatchPid, #{
        vote_id => VoteId,
        options => Options,
        window_ms => 500,
        template => ~"path_choice"
    }),
    ok = asobi_match_server:cast_vote(MatchPid, ~"p1", VoteId, ~"opt_a"),
    ok = asobi_match_server:cast_vote(MatchPid, ~"p2", VoteId, ~"opt_a"),
    %% Wait for vote to resolve
    timer:sleep(700),
    %% Match should still be running
    Info = asobi_match_server:get_info(MatchPid),
    ?assertMatch(#{status := running}, Info).

vote_hidden_visibility(_Config) ->
    Options = [
        #{id => ~"opt_a", label => ~"A"},
        #{id => ~"opt_b", label => ~"B"}
    ],
    {ok, MatchPid} = start_test_match(),
    {ok, VotePid} = asobi_vote_sup:start_vote(#{
        match_id => asobi_id:generate(),
        match_pid => MatchPid,
        options => Options,
        eligible => [~"p1"],
        window_ms => 5000,
        visibility => ~"hidden"
    }),
    ok = asobi_vote_server:cast_vote(VotePid, ~"p1", ~"opt_a"),
    Info = asobi_vote_server:get_state(VotePid),
    %% Hidden visibility should not include tallies
    ?assertNot(maps:is_key(tallies, Info)),
    ?assertMatch(#{total_votes := 1}, Info).

vote_no_votes_cast(_Config) ->
    Options = [
        #{id => ~"opt_a", label => ~"A"},
        #{id => ~"opt_b", label => ~"B"}
    ],
    {ok, MatchPid} = start_test_match(),
    {ok, VotePid} = asobi_vote_sup:start_vote(#{
        match_id => asobi_id:generate(),
        match_pid => MatchPid,
        options => Options,
        eligible => [~"p1"],
        window_ms => 100
    }),
    Ref = monitor(process, VotePid),
    %% Don't cast any votes, let it expire
    receive
        {'DOWN', Ref, process, VotePid, normal} -> ok
    after 2000 ->
        error(vote_did_not_expire)
    end.

%% --- Helpers ---

start_test_match() ->
    asobi_match_sup:start_match(#{
        game_module => asobi_test_game,
        min_players => 1,
        max_players => 4,
        tick_rate => 50
    }).
