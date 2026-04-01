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
    vote_no_votes_cast/1,
    vote_weighted_method/1,
    vote_weighted_unequal/1,
    vote_template_from_config/1,
    vote_template_override/1,
    vote_rate_limit/1,
    vote_window_ready_up/1,
    vote_window_ready_up_timeout/1,
    vote_window_hybrid/1,
    vote_window_hybrid_min_enforced/1,
    vote_window_adaptive/1
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
        vote_no_votes_cast,
        vote_weighted_method,
        vote_weighted_unequal,
        vote_template_from_config,
        vote_template_override,
        vote_rate_limit,
        vote_window_ready_up,
        vote_window_ready_up_timeout,
        vote_window_hybrid,
        vote_window_hybrid_min_enforced,
        vote_window_adaptive
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

vote_weighted_method(_Config) ->
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
        method => ~"weighted",
        weights => #{~"p1" => 3, ~"p2" => 1},
        visibility => ~"live"
    }),
    %% p1 votes A (weight 3), p2 votes B (weight 1) — A should win
    ok = asobi_vote_server:cast_vote(VotePid, ~"p1", ~"opt_a"),
    ok = asobi_vote_server:cast_vote(VotePid, ~"p2", ~"opt_b"),
    Ref = monitor(process, VotePid),
    receive
        {'DOWN', Ref, process, VotePid, normal} -> ok
    after 2000 ->
        error(vote_did_not_resolve)
    end.

vote_weighted_unequal(_Config) ->
    Options = [
        #{id => ~"opt_a", label => ~"A"},
        #{id => ~"opt_b", label => ~"B"}
    ],
    {ok, MatchPid} = start_test_match(),
    {ok, VotePid} = asobi_vote_sup:start_vote(#{
        match_id => asobi_id:generate(),
        match_pid => MatchPid,
        options => Options,
        eligible => [~"p1", ~"p2", ~"p3"],
        window_ms => 5000,
        method => ~"weighted",
        weights => #{~"p1" => 10, ~"p2" => 1, ~"p3" => 1},
        visibility => ~"live"
    }),
    %% p2 and p3 vote B (total weight 2), p1 votes A (weight 10) — A wins
    ok = asobi_vote_server:cast_vote(VotePid, ~"p1", ~"opt_a"),
    ok = asobi_vote_server:cast_vote(VotePid, ~"p2", ~"opt_b"),
    ok = asobi_vote_server:cast_vote(VotePid, ~"p3", ~"opt_b"),
    Info = asobi_vote_server:get_state(VotePid),
    ?assertMatch(#{tallies := #{~"opt_a" := 10.0, ~"opt_b" := 2.0}}, Info).

vote_template_from_config(_Config) ->
    %% Set a template in app config
    application:set_env(asobi, vote_templates, #{
        ~"test_tmpl" => #{method => ~"approval", window_ms => 5000, visibility => ~"hidden"}
    }),
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
        template => ~"test_tmpl"
    }),
    Info = asobi_vote_server:get_state(VotePid),
    %% Should have hidden visibility from template
    ?assertNot(maps:is_key(tallies, Info)),
    ?assertMatch(#{method := ~"approval"}, Info),
    application:unset_env(asobi, vote_templates).

vote_template_override(_Config) ->
    %% Template says hidden, but per-call overrides to live
    application:set_env(asobi, vote_templates, #{
        ~"override_tmpl" => #{method => ~"plurality", window_ms => 5000, visibility => ~"hidden"}
    }),
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
        template => ~"override_tmpl",
        visibility => ~"live"
    }),
    ok = asobi_vote_server:cast_vote(VotePid, ~"p1", ~"opt_a"),
    Info = asobi_vote_server:get_state(VotePid),
    %% Per-call override should win
    ?assert(maps:is_key(tallies, Info)),
    application:unset_env(asobi, vote_templates).

vote_rate_limit(_Config) ->
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
        max_revotes => 2
    }),
    %% First vote (count=0, no prior)
    ok = asobi_vote_server:cast_vote(VotePid, ~"p1", ~"opt_a"),
    %% Change 1 (count=1)
    ok = asobi_vote_server:cast_vote(VotePid, ~"p1", ~"opt_b"),
    %% Change 2 (count=2)
    ok = asobi_vote_server:cast_vote(VotePid, ~"p1", ~"opt_a"),
    %% Change 3 — should be rate limited (count=2, limit=2)
    ?assertMatch(
        {error, rate_limited}, asobi_vote_server:cast_vote(VotePid, ~"p1", ~"opt_b")
    ).

vote_window_ready_up(_Config) ->
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
        window_ms => 60000,
        window_type => ~"ready_up"
    }),
    Ref = monitor(process, VotePid),
    ok = asobi_vote_server:cast_vote(VotePid, ~"p1", ~"opt_a"),
    %% Not closed yet — p2 hasn't voted
    ?assert(is_process_alive(VotePid)),
    ok = asobi_vote_server:cast_vote(VotePid, ~"p2", ~"opt_b"),
    %% All voted — should close immediately
    receive
        {'DOWN', Ref, process, VotePid, normal} -> ok
    after 1000 ->
        error(ready_up_did_not_close)
    end.

vote_window_ready_up_timeout(_Config) ->
    Options = [#{id => ~"opt_a", label => ~"A"}],
    {ok, MatchPid} = start_test_match(),
    {ok, VotePid} = asobi_vote_sup:start_vote(#{
        match_id => asobi_id:generate(),
        match_pid => MatchPid,
        options => Options,
        eligible => [~"p1", ~"p2"],
        window_ms => 200,
        window_type => ~"ready_up"
    }),
    Ref = monitor(process, VotePid),
    %% Only p1 votes, p2 never does — should timeout
    ok = asobi_vote_server:cast_vote(VotePid, ~"p1", ~"opt_a"),
    receive
        {'DOWN', Ref, process, VotePid, normal} -> ok
    after 2000 ->
        error(ready_up_did_not_timeout)
    end.

vote_window_hybrid(_Config) ->
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
        window_ms => 60000,
        window_type => ~"hybrid",
        min_window_ms => 50
    }),
    Ref = monitor(process, VotePid),
    %% Wait past min window
    timer:sleep(100),
    ok = asobi_vote_server:cast_vote(VotePid, ~"p1", ~"opt_a"),
    ok = asobi_vote_server:cast_vote(VotePid, ~"p2", ~"opt_b"),
    %% All voted + min elapsed — should close
    receive
        {'DOWN', Ref, process, VotePid, normal} -> ok
    after 1000 ->
        error(hybrid_did_not_close)
    end.

vote_window_hybrid_min_enforced(_Config) ->
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
        window_ms => 60000,
        window_type => ~"hybrid",
        min_window_ms => 5000
    }),
    %% Vote immediately (before min_window_ms)
    ok = asobi_vote_server:cast_vote(VotePid, ~"p1", ~"opt_a"),
    ok = asobi_vote_server:cast_vote(VotePid, ~"p2", ~"opt_b"),
    %% All voted but min_window_ms not elapsed — should still be alive
    timer:sleep(50),
    ?assert(is_process_alive(VotePid)).

vote_window_adaptive(_Config) ->
    Options = [
        #{id => ~"opt_a", label => ~"A"},
        #{id => ~"opt_b", label => ~"B"}
    ],
    {ok, MatchPid} = start_test_match(),
    {ok, VotePid} = asobi_vote_sup:start_vote(#{
        match_id => asobi_id:generate(),
        match_pid => MatchPid,
        options => Options,
        eligible => [~"p1", ~"p2", ~"p3", ~"p4"],
        window_ms => 60000,
        window_type => ~"adaptive",
        supermajority => 0.75
    }),
    Ref = monitor(process, VotePid),
    %% 3 out of 4 vote the same — 75% supermajority triggers shrink to 3s
    ok = asobi_vote_server:cast_vote(VotePid, ~"p1", ~"opt_a"),
    ok = asobi_vote_server:cast_vote(VotePid, ~"p2", ~"opt_a"),
    ok = asobi_vote_server:cast_vote(VotePid, ~"p3", ~"opt_a"),
    %% Should resolve within ~3s (adaptive shrink), not 60s
    receive
        {'DOWN', Ref, process, VotePid, normal} -> ok
    after 5000 ->
        error(adaptive_did_not_shrink)
    end.

%% --- Helpers ---

start_test_match() ->
    asobi_match_sup:start_match(#{
        game_module => asobi_test_game,
        min_players => 1,
        max_players => 4,
        tick_rate => 50
    }).
