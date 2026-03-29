-module(asobi_match_SUITE).

-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([
    match_lifecycle/1,
    match_join_leave/1,
    match_full/1,
    match_waiting_timeout/1,
    match_invalid_input_survives/1,
    match_tick_executes/1
]).

all() ->
    [
        match_lifecycle,
        match_join_leave,
        match_full,
        match_waiting_timeout,
        match_invalid_input_survives,
        match_tick_executes
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(asobi),

    Config.

end_per_suite(Config) ->
    Config.

%% --- Tests ---

match_lifecycle(Config) ->
    {ok, Pid} = asobi_match_sup:start_match(#{
        game_module => asobi_test_game,
        min_players => 2,
        max_players => 4,
        tick_rate => 50
    }),
    ?assert(is_pid(Pid)),
    Info = asobi_match_server:get_info(Pid),
    ?assertMatch(#{status := waiting, player_count := 0}, Info),
    ok = asobi_match_server:join(Pid, ~"player1"),
    ok = asobi_match_server:join(Pid, ~"player2"),
    timer:sleep(100),
    Info2 = asobi_match_server:get_info(Pid),
    ?assertMatch(#{status := running, player_count := 2}, Info2),
    Config.

match_join_leave(Config) ->
    {ok, Pid} = asobi_match_sup:start_match(#{
        game_module => asobi_test_game,
        min_players => 2,
        max_players => 4
    }),
    ok = asobi_match_server:join(Pid, ~"player1"),
    ok = asobi_match_server:join(Pid, ~"player2"),
    asobi_match_server:leave(Pid, ~"player1"),
    timer:sleep(50),
    Info = asobi_match_server:get_info(Pid),
    ?assertMatch(#{player_count := 1}, Info),
    Config.

match_full(Config) ->
    {ok, Pid} = asobi_match_sup:start_match(#{
        game_module => asobi_test_game,
        min_players => 1,
        max_players => 2
    }),
    ok = asobi_match_server:join(Pid, ~"player1"),
    ok = asobi_match_server:join(Pid, ~"player2"),
    ?assertMatch({error, match_full}, asobi_match_server:join(Pid, ~"player3")),
    Config.

match_waiting_timeout(_Config) ->
    {ok, Pid} = asobi_match_sup:start_match(#{
        game_module => asobi_test_game,
        min_players => 10
    }),
    Ref = monitor(process, Pid),
    ok = asobi_match_server:join(Pid, ~"player1"),
    receive
        {'DOWN', Ref, process, Pid, {shutdown, timeout}} -> ok
    after 65000 ->
        error(timeout_not_triggered)
    end.

match_invalid_input_survives(_Config) ->
    {ok, Pid} = asobi_match_sup:start_match(#{
        game_module => asobi_test_game,
        min_players => 2,
        max_players => 2,
        tick_rate => 50
    }),
    ok = asobi_match_server:join(Pid, ~"player1"),
    ok = asobi_match_server:join(Pid, ~"player2"),
    timer:sleep(100),
    %% Send invalid input — should be rejected without crashing
    asobi_match_server:handle_input(Pid, ~"player1", #{~"action" => ~"invalid"}),
    timer:sleep(100),
    %% Match should still be running
    Info = asobi_match_server:get_info(Pid),
    ?assertMatch(#{status := running}, Info).

match_tick_executes(_Config) ->
    {ok, Pid} = asobi_match_sup:start_match(#{
        game_module => asobi_test_game,
        min_players => 1,
        max_players => 2,
        tick_rate => 50
    }),
    ok = asobi_match_server:join(Pid, ~"player1"),
    timer:sleep(300),
    Info = asobi_match_server:get_info(Pid),
    ?assertMatch(#{status := running}, Info).
