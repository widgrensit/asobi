-module(asobi_bot_presence_tests).
-include_lib("eunit/include/eunit.hrl").

%% S5: asobi_bot used to re-define core's ?PG_SCOPE and call pg:join/3
%% itself, so a bot was a delivery target that asobi_presence knew nothing
%% about. Bots now go through asobi_presence:track_bot/2, which joins the
%% delivery group and nothing else: addressable by send/2, never counted by
%% online_count/0.
%%
%% The match-server tests run against the real asobi_presence (no meck) so
%% the producer shapes in asobi_presence:message/0 are exercised end to end:
%% match server -> asobi_presence:send/2 -> pg -> bot.

-define(BASE_CONFIG, #{
    game_module => asobi_test_game,
    min_players => 2,
    max_players => 4,
    tick_rate => 50
}).

presence_tracking_test_() ->
    {foreach, fun setup/0, fun cleanup/1, [
        {"a player session counts toward online_count/0", fun player_counts_online/0},
        {"a bot is addressable but never counted online", fun bot_addressable_not_online/0},
        {"untrack_bot/2 drops the delivery target and leaves the count alone",
            fun untrack_bot_drops_target/0},
        {"a live bot is tracked, uncounted, and found by the match server",
            fun bot_tracked_and_uncounted/0},
        {"match state reaches the bot through presence", fun bot_receives_match_state/0},
        {"shared-state match: the bot reads the state, the session gets the frame",
            fun bot_receives_shared_match_state/0},
        {"send_match_state/3 splits by recipient kind", fun send_match_state_splits/0},
        {"a vote_start match event reaches the bot", fun bot_receives_vote_start/0},
        {"a finished bot leaves the delivery group", fun finished_bot_untracked/0},
        {"bot_pids/1 finds a tracked bot and nothing else", fun bot_pids_resolves/0}
    ]}.

setup() ->
    case ets:whereis(asobi_match_state) of
        undefined -> ets:new(asobi_match_state, [named_table, public, set]);
        _ -> ok
    end,
    case whereis(nova_scope) of
        undefined -> {ok, _} = pg:start(nova_scope);
        _ -> ok
    end,
    meck:new(asobi_repo, [no_link]),
    meck:expect(asobi_repo, insert, fun(_CS) -> {ok, #{}} end),
    meck:expect(asobi_repo, insert, fun(_CS, _Opts) -> {ok, #{}} end),
    ok.

cleanup(_) ->
    meck:unload(asobi_repo),
    ok.

%% --- track/2 vs track_bot/2 ---

player_counts_online() ->
    Before = asobi_presence:online_count(),
    Pid = relay(),
    ok = asobi_presence:track(~"presence_p1", Pid),
    ?assertEqual(Before + 1, asobi_presence:online_count()),
    ?assertEqual(online, asobi_presence:get_status(~"presence_p1")),
    asobi_presence:send(~"presence_p1", {notification, #{~"id" => ~"n1"}}),
    ?assertEqual({asobi_message, {notification, #{~"id" => ~"n1"}}}, next_relayed()),
    stop_relay(Pid),
    wait_until(fun() -> asobi_presence:online_count() =:= Before end).

bot_addressable_not_online() ->
    Before = asobi_presence:online_count(),
    Pid = relay(),
    ok = asobi_presence:track_bot(~"bot_Spark", Pid),
    ?assertEqual(Before, asobi_presence:online_count()),
    ?assertEqual(online, asobi_presence:get_status(~"bot_Spark")),
    asobi_presence:send(~"bot_Spark", {match_state, #{~"tick" => 1}}),
    ?assertEqual({asobi_message, {match_state, #{~"tick" => 1}}}, next_relayed()),
    stop_relay(Pid).

untrack_bot_drops_target() ->
    Before = asobi_presence:online_count(),
    Pid = relay(),
    ok = asobi_presence:track_bot(~"bot_Blitz", Pid),
    ok = asobi_presence:untrack_bot(~"bot_Blitz", Pid),
    ?assertEqual(offline, asobi_presence:get_status(~"bot_Blitz")),
    ?assertEqual([], pg:get_members(nova_scope, {bot, ~"bot_Blitz"})),
    ?assertEqual(Before, asobi_presence:online_count()),
    stop_relay(Pid).

%% asobi_bot_spawner:remove_bot/2 resolves a bot id to the process it has to
%% stop through this. A player id must not resolve - stopping a session
%% because a script asked to remove a bot of the same name would be the worst
%% possible outcome.
bot_pids_resolves() ->
    BotPid = relay(),
    PlayerPid = relay(),
    ok = asobi_presence:track_bot(~"bot_Pulse", BotPid),
    ok = asobi_presence:track(~"bot_Pulse_human", PlayerPid),
    ?assertEqual([BotPid], asobi_presence:bot_pids(~"bot_Pulse")),
    ?assertEqual([], asobi_presence:bot_pids(~"bot_Pulse_human")),
    ?assertEqual([], asobi_presence:bot_pids(~"bot_NeverExisted")),
    ok = asobi_presence:untrack_bot(~"bot_Pulse", BotPid),
    ?assertEqual([], asobi_presence:bot_pids(~"bot_Pulse")),
    stop_relay(BotPid),
    stop_relay(PlayerPid).

%% --- the bot process itself ---

bot_tracked_and_uncounted() ->
    Before = asobi_presence:online_count(),
    MatchPid = start_match(#{}),
    BotId = ~"bot_Volt",
    BotPid = start_bot(MatchPid, BotId),
    ?assertEqual([BotPid], pg:get_members(nova_scope, {player, BotId})),
    ?assertEqual(Before, asobi_presence:online_count()),
    %% asobi_match_server:find_player_pid/1 resolves the roster through the
    %% same pg group, so tracking must happen before the bot's join/2 call.
    ?assertEqual(BotPid, session_pid(MatchPid, BotId)),
    stop_process(BotPid),
    stop_process(MatchPid).

bot_receives_match_state() ->
    MatchPid = start_match(#{min_players => 1}),
    BotPid = start_bot(MatchPid, ~"bot_Neon"),
    wait_until(fun() -> maps:get(game_state, bot_state(BotPid)) =/= #{} end),
    ?assertEqual(#{score => 0}, maps:get(game_state, bot_state(BotPid))),
    stop_process(BotPid),
    stop_process(MatchPid).

%% A mode whose game module exports get_state/1 broadcasts one pre-encoded
%% frame per tick. A bot has no clause for that frame, so before
%% asobi_presence:send_match_state/3 existed its game_state stayed empty for
%% its whole life with no error and no log. The session must still get the
%% pre-encoded frame: bots must not cost the encode-once path.
bot_receives_shared_match_state() ->
    MatchPid = start_match(#{game_module => asobi_test_game_shared, min_players => 1}),
    Session = relay(),
    ok = asobi_presence:track(~"shared_human", Session),
    ok = asobi_match_server:join(MatchPid, ~"shared_human"),
    BotPid = start_bot(MatchPid, ~"bot_Shard"),
    %% after, not a tail of stop calls: a failing assertion here must not
    %% leave a ticking match behind for the next test module to trip over.
    try
        wait_until(fun() -> maps:get(game_state, bot_state(BotPid)) =/= #{} end),
        ?assertMatch(
            #{~"world" := #{npcs := 0}, ~"tick" := _},
            maps:get(game_state, bot_state(BotPid))
        ),
        ?assertMatch(#{~"type" := ~"match.state"}, json:decode(next_raw_frame()))
    after
        stop_relay(Session),
        stop_process(BotPid),
        stop_process(MatchPid)
    end.

send_match_state_splits() ->
    Session = relay(),
    ok = asobi_presence:track(~"split_human", Session),
    ok = asobi_presence:send_match_state(~"split_human", #{~"tick" => 7}, ~"frame"),
    ?assertEqual({asobi_message, {match_state_raw, ~"frame"}}, next_relayed()),
    stop_relay(Session),
    Bot = relay(),
    ok = asobi_presence:track_bot(~"bot_Split", Bot),
    ok = asobi_presence:send_match_state(~"bot_Split", #{~"tick" => 7}, ~"frame"),
    ?assertEqual({asobi_message, {match_state, #{~"tick" => 7}}}, next_relayed()),
    stop_relay(Bot).

bot_receives_vote_start() ->
    %% min_players 2 keeps the match in `waiting`, so no state broadcast
    %% races the phase assertion. An empty option list is deliberate: the
    %% bot then recognises the vote without arming its 1-3s auto-vote timer.
    MatchPid = start_match(#{}),
    BotPid = start_bot(MatchPid, ~"bot_Pulse"),
    ok = asobi_match_server:broadcast_event(MatchPid, vote_start, #{
        vote_id => ~"v1",
        options => [],
        window_ms => 5000,
        method => ~"plurality"
    }),
    wait_until(fun() -> maps:get(phase, bot_state(BotPid)) =:= voting end),
    ?assertEqual(voting, maps:get(phase, bot_state(BotPid))),
    stop_process(BotPid),
    stop_process(MatchPid).

finished_bot_untracked() ->
    MatchPid = start_match(#{}),
    BotId = ~"bot_Ember",
    BotPid = start_bot(MatchPid, BotId),
    Ref = monitor(process, BotPid),
    asobi_presence:send(BotId, {match_event, finished, #{}}),
    receive
        {'DOWN', Ref, process, BotPid, normal} -> ok
    after 2000 ->
        error(bot_still_running)
    end,
    wait_until(fun() -> asobi_presence:get_status(BotId) =:= offline end),
    ?assertEqual(offline, asobi_presence:get_status(BotId)),
    stop_process(MatchPid).

%% --- Helpers ---

start_match(Overrides) ->
    {ok, Pid} = asobi_match_server:start_link(maps:merge(?BASE_CONFIG, Overrides)),
    unlink(Pid),
    Pid.

start_bot(MatchPid, BotId) ->
    {ok, Pid} = asobi_bot:start_link(MatchPid, BotId, undefined),
    unlink(Pid),
    Pid.

bot_state(BotPid) ->
    sys:get_state(BotPid).

session_pid(MatchPid, PlayerId) ->
    {_StateName, #{players := Players}} = sys:get_state(MatchPid),
    maps:get(session_pid, maps:get(PlayerId, Players)).

relay() ->
    Parent = self(),
    spawn(fun Loop() ->
        receive
            stop ->
                ok;
            Msg ->
                Parent ! {relayed, Msg},
                Loop()
        end
    end).

stop_relay(Pid) ->
    Pid ! stop,
    ok.

next_relayed() ->
    receive
        {relayed, Msg} -> Msg
    after 2000 ->
        error(no_message_delivered)
    end.

next_raw_frame() ->
    receive
        {relayed, {asobi_message, {match_state_raw, Frame}}} -> Frame;
        {relayed, _} -> next_raw_frame()
    after 2000 ->
        error(no_raw_frame_delivered)
    end.

stop_process(Pid) ->
    case is_process_alive(Pid) of
        true ->
            Ref = monitor(process, Pid),
            exit(Pid, shutdown),
            receive
                {'DOWN', Ref, process, Pid, _} -> ok
            after 5000 -> ok
            end;
        false ->
            ok
    end.

wait_until(Fun) ->
    wait_until(Fun, 200).

wait_until(_Fun, 0) ->
    error(condition_never_held);
wait_until(Fun, N) ->
    case Fun() of
        true ->
            ok;
        false ->
            timer:sleep(25),
            wait_until(Fun, N - 1)
    end.
