-module(asobi_ws_vote_tests).

-include_lib("eunit/include/eunit.hrl").

%% #447: world votes were unreachable from clients. asobi_ws_handler resolved
%% vote.cast / vote.veto from the session's match_pid only, but a world join
%% sets world_pid/zone_pid and never match_pid, so a world-mode script could
%% start a vote that no client could ever cast or veto in. These tests drive
%% the frozen vote.cast / vote.veto frames through websocket_handle/2 and prove
%% a world-context session now reaches asobi_world_server while the
%% match-context path still reaches asobi_match_server unchanged.

vote_routing_test_() ->
    {foreach, fun setup/0, fun cleanup/1, [
        fun world_vote_cast_reaches_world_server/1,
        fun world_vote_veto_reaches_world_server/1,
        fun match_vote_cast_still_reaches_match_server/1,
        fun match_vote_veto_still_reaches_match_server/1,
        fun world_vote_cast_error_is_reported/1,
        fun world_vote_veto_error_is_reported/1,
        fun no_fabric_vote_cast_is_not_in_match/1
    ]}.

setup() ->
    meck:new(asobi_player_session, [passthrough]),
    meck:new(asobi_world_server, [passthrough]),
    meck:new(asobi_match_server, [passthrough]),
    meck:expect(asobi_world_server, cast_vote, fun(_Pid, _PlayerId, _VoteId, _OptionId) -> ok end),
    meck:expect(asobi_world_server, use_veto, fun(_Pid, _PlayerId, _VoteId) -> ok end),
    meck:expect(asobi_match_server, cast_vote, fun(_Pid, _PlayerId, _VoteId, _OptionId) -> ok end),
    meck:expect(asobi_match_server, use_veto, fun(_Pid, _PlayerId, _VoteId) -> ok end),
    ok.

cleanup(_) ->
    meck:unload(asobi_match_server),
    meck:unload(asobi_world_server),
    meck:unload(asobi_player_session),
    ok.

world_vote_cast_reaches_world_server(_) ->
    mock_session(#{player_id => ~"p1", world_pid => self(), zone_pid => self()}),
    Decoded = handle(~"vote.cast", ~"vc1", #{~"vote_id" => ~"v1", ~"option_id" => ~"a"}),
    [
        ?_assertMatch(
            #{~"type" := ~"vote.cast_ok", ~"cid" := ~"vc1", ~"payload" := #{~"success" := true}},
            Decoded
        ),
        %% '_' for the vote target pid: eunit runs a deferred ?_assert in a
        %% different process than the one that recorded the meck call, so a
        %% literal self() here would never match. The other three args pin the
        %% authenticated player and the payload's vote/option ids.
        ?_assertEqual(1, meck:num_calls(asobi_world_server, cast_vote, ['_', ~"p1", ~"v1", ~"a"])),
        ?_assertEqual(0, meck:num_calls(asobi_match_server, cast_vote, '_'))
    ].

world_vote_veto_reaches_world_server(_) ->
    mock_session(#{player_id => ~"p1", world_pid => self(), zone_pid => self()}),
    Decoded = handle(~"vote.veto", ~"vv1", #{~"vote_id" => ~"v1"}),
    [
        ?_assertMatch(
            #{~"type" := ~"vote.veto_ok", ~"cid" := ~"vv1", ~"payload" := #{~"success" := true}},
            Decoded
        ),
        ?_assertEqual(1, meck:num_calls(asobi_world_server, use_veto, ['_', ~"p1", ~"v1"])),
        ?_assertEqual(0, meck:num_calls(asobi_match_server, use_veto, '_'))
    ].

match_vote_cast_still_reaches_match_server(_) ->
    mock_session(#{player_id => ~"p1", match_pid => self()}),
    Decoded = handle(~"vote.cast", ~"vc2", #{~"vote_id" => ~"v1", ~"option_id" => ~"a"}),
    [
        ?_assertMatch(#{~"type" := ~"vote.cast_ok", ~"payload" := #{~"success" := true}}, Decoded),
        ?_assertEqual(1, meck:num_calls(asobi_match_server, cast_vote, ['_', ~"p1", ~"v1", ~"a"])),
        ?_assertEqual(0, meck:num_calls(asobi_world_server, cast_vote, '_'))
    ].

match_vote_veto_still_reaches_match_server(_) ->
    mock_session(#{player_id => ~"p1", match_pid => self()}),
    Decoded = handle(~"vote.veto", ~"vv2", #{~"vote_id" => ~"v1"}),
    [
        ?_assertMatch(#{~"type" := ~"vote.veto_ok", ~"payload" := #{~"success" := true}}, Decoded),
        ?_assertEqual(1, meck:num_calls(asobi_match_server, use_veto, ['_', ~"p1", ~"v1"])),
        ?_assertEqual(0, meck:num_calls(asobi_world_server, use_veto, '_'))
    ].

world_vote_cast_error_is_reported(_) ->
    mock_session(#{player_id => ~"p1", world_pid => self(), zone_pid => self()}),
    meck:expect(asobi_world_server, cast_vote, fun(_Pid, _PlayerId, _VoteId, _OptionId) ->
        {error, vote_not_found}
    end),
    Decoded = handle(~"vote.cast", ~"vc3", #{~"vote_id" => ~"gone", ~"option_id" => ~"a"}),
    ?_assertMatch(
        #{~"type" := ~"error", ~"payload" := #{~"reason" := ~"vote_not_found"}}, Decoded
    ).

world_vote_veto_error_is_reported(_) ->
    mock_session(#{player_id => ~"p1", world_pid => self(), zone_pid => self()}),
    meck:expect(asobi_world_server, use_veto, fun(_Pid, _PlayerId, _VoteId) ->
        {error, no_veto_tokens}
    end),
    Decoded = handle(~"vote.veto", ~"vv3", #{~"vote_id" => ~"v1"}),
    ?_assertMatch(
        #{~"type" := ~"error", ~"payload" := #{~"reason" := ~"no_veto_tokens"}}, Decoded
    ).

no_fabric_vote_cast_is_not_in_match(_) ->
    mock_session(#{player_id => ~"p1"}),
    Decoded = handle(~"vote.cast", ~"vc4", #{~"vote_id" => ~"v1", ~"option_id" => ~"a"}),
    [
        ?_assertMatch(
            #{~"type" := ~"error", ~"payload" := #{~"reason" := ~"not_in_match"}}, Decoded
        ),
        ?_assertEqual(0, meck:num_calls(asobi_world_server, cast_vote, '_')),
        ?_assertEqual(0, meck:num_calls(asobi_match_server, cast_vote, '_'))
    ].

mock_session(SState) ->
    meck:expect(asobi_player_session, get_state, fun(_Pid) -> SState end).

handle(Type, Cid, Payload) ->
    Raw = iolist_to_binary(
        json:encode(#{~"type" => Type, ~"cid" => Cid, ~"payload" => Payload})
    ),
    {reply, {text, Frame}, _State} = asobi_ws_handler:websocket_handle({text, Raw}, state()),
    json:decode(iolist_to_binary(Frame)).

state() ->
    #{
        session => self(),
        ws_msg_count => 0,
        ws_msg_window_start => erlang:system_time(millisecond)
    }.
