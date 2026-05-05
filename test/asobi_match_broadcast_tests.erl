-module(asobi_match_broadcast_tests).
-include_lib("eunit/include/eunit.hrl").

%% Verifies the broadcast_state/1 dispatch in asobi_match_server: when the
%% game module exports get_state/1, the match server encodes once and sends
%% the same pre-encoded binary to every player. When only get_state/2 is
%% exported, the legacy per-player path runs.

-define(SENT_TAB, asobi_match_broadcast_tests_sent).

setup() ->
    case ets:whereis(asobi_match_state) of
        undefined -> ets:new(asobi_match_state, [named_table, public, set]);
        _ -> ok
    end,
    case ets:whereis(?SENT_TAB) of
        undefined -> ets:new(?SENT_TAB, [named_table, public, duplicate_bag]);
        _ -> ets:delete_all_objects(?SENT_TAB)
    end,
    case whereis(nova_scope) of
        undefined -> pg:start_link(nova_scope);
        _ -> ok
    end,
    meck:new(asobi_repo, [no_link]),
    meck:expect(asobi_repo, insert, fun(_CS) -> {ok, #{}} end),
    meck:expect(asobi_repo, insert, fun(_CS, _Opts) -> {ok, #{}} end),
    meck:new(asobi_presence, [non_strict, no_link]),
    meck:expect(asobi_presence, send, fun(PlayerId, Msg) ->
        ets:insert(?SENT_TAB, {PlayerId, Msg}),
        ok
    end),
    ok.

cleanup(_) ->
    meck:unload(asobi_presence),
    meck:unload(asobi_repo),
    ok.

broadcast_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        {"per-player path delivers match_state per player", fun per_player_path/0},
        {"shared path delivers match_state_raw with same binary", fun shared_path/0}
    ]}.

per_player_path() ->
    ets:delete_all_objects(?SENT_TAB),
    Pid = start_match(asobi_test_game),
    ok = asobi_match_server:join(Pid, ~"p1"),
    ok = asobi_match_server:join(Pid, ~"p2"),
    timer:sleep(200),
    Sent = ets:tab2list(?SENT_TAB),
    PerPlayer = [X || X = {_, {match_state, _}} <- Sent],
    Raw = [X || X = {_, {match_state_raw, _}} <- Sent],
    ?assert(length(PerPlayer) >= 1),
    ?assertEqual([], Raw),
    stop(Pid).

shared_path() ->
    ets:delete_all_objects(?SENT_TAB),
    Pid = start_match(asobi_test_game_shared),
    ok = asobi_match_server:join(Pid, ~"p1"),
    ok = asobi_match_server:join(Pid, ~"p2"),
    timer:sleep(200),
    Sent = ets:tab2list(?SENT_TAB),
    PerPlayer = [X || X = {_, {match_state, _}} <- Sent],
    Raw = [{P, B} || {P, {match_state_raw, B}} <- Sent, is_binary(B)],
    ?assertEqual([], PerPlayer),
    ?assert(length(Raw) >= 2),
    %% In any single tick the binary is identical for every player. Pick
    %% the most-recent binary delivered to each player and compare them.
    LastByPlayer = #{P => B || {P, B} <- Raw},
    case maps:values(LastByPlayer) of
        [B1, B2 | _] ->
            ?assertEqual(B1, B2),
            Decoded = json:decode(B1),
            ?assertMatch(#{~"type" := ~"match.state", ~"payload" := _}, Decoded);
        _ ->
            ?assert(false)
    end,
    stop(Pid).

%% --- Helpers ---

start_match(GameModule) ->
    Config = #{
        game_module => GameModule,
        min_players => 2,
        max_players => 4,
        tick_rate => 30
    },
    {ok, Pid} = asobi_match_server:start_link(Config),
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
