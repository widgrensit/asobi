-module(asobi_match_lobby_tests).
-include_lib("eunit/include/eunit.hrl").

-define(GAME, asobi_test_game).
-define(BASE_CONFIG, #{game_module => ?GAME, min_players => 2, max_players => 4, tick_rate => 50}).

setup() ->
    case ets:whereis(asobi_match_state) of
        undefined -> ets:new(asobi_match_state, [named_table, public, set]);
        _ -> ok
    end,
    case whereis(nova_scope) of
        undefined -> pg:start_link(nova_scope);
        _ -> ok
    end,
    meck:new(asobi_repo, [no_link]),
    meck:expect(asobi_repo, insert, fun(_CS) -> {ok, #{}} end),
    meck:expect(asobi_repo, insert, fun(_CS, _Opts) -> {ok, #{}} end),
    meck:new(asobi_presence, [non_strict, no_link]),
    meck:expect(asobi_presence, send, fun(_PlayerId, _Msg) -> ok end),
    ok.

cleanup(_) ->
    meck:unload(asobi_presence),
    meck:unload(asobi_repo),
    ok.

start_match(Overrides) ->
    {ok, Pid} = asobi_match_server:start_link(maps:merge(?BASE_CONFIG, Overrides)),
    Pid.

stop_match(Pid) ->
    unlink(Pid),
    exit(Pid, kill),
    wait_gone(Pid, 50).

wait_gone(_Pid, 0) ->
    ok;
wait_gone(Pid, N) ->
    case is_process_alive(Pid) of
        false ->
            ok;
        true ->
            timer:sleep(10),
            wait_gone(Pid, N - 1)
    end.

match_lobby_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        {"matches are unlisted by default", fun unlisted_by_default/0},
        {"listed => true opts a match into discovery", fun listed_opts_in/0},
        {"listing drops the roster and the flag", fun listing_drops_roster/0},
        {"filters by mode", fun filters_by_mode/0},
        {"has_capacity excludes a full match", fun filters_by_capacity/0}
    ]}.

unlisted_by_default() ->
    Pid = start_match(#{mode => ~"unlisted_mode"}),
    ?assertEqual(
        [],
        asobi_match_lobby:list_matches(#{listed => true, mode => ~"unlisted_mode"}),
        "a matchmaker-spawned match must not appear in a browser by default"
    ),
    ?assertEqual(1, length(asobi_match_lobby:list_matches(#{mode => ~"unlisted_mode"}))),
    stop_match(Pid).

listed_opts_in() ->
    Pid = start_match(#{mode => ~"listed_mode", listed => true}),
    [M] = asobi_match_lobby:list_matches(#{listed => true, mode => ~"listed_mode"}),
    ?assertEqual(~"listed_mode", maps:get(mode, M)),
    ?assertEqual(waiting, maps:get(status, M)),
    stop_match(Pid).

listing_drops_roster() ->
    Pid = start_match(#{mode => ~"roster_mode", listed => true}),
    ok = asobi_match_server:join(Pid, ~"p1"),
    [M] = asobi_match_lobby:list_matches(#{listed => true, mode => ~"roster_mode"}),
    ?assertEqual(
        lists:sort([match_id, status, player_count, max_players, mode]),
        lists:sort(maps:keys(M)),
        "listing key set is a security contract - widen it deliberately"
    ),
    ?assertEqual(1, maps:get(player_count, M)),
    ?assert(maps:is_key(players, asobi_match_server:get_info(Pid))),
    stop_match(Pid).

filters_by_mode() ->
    A = start_match(#{mode => ~"mode_a", listed => true}),
    B = start_match(#{mode => ~"mode_b", listed => true}),
    [MA] = asobi_match_lobby:list_matches(#{listed => true, mode => ~"mode_a"}),
    ?assertEqual(~"mode_a", maps:get(mode, MA)),
    stop_match(A),
    stop_match(B).

filters_by_capacity() ->
    Pid = start_match(#{mode => ~"cap_mode", listed => true, min_players => 1, max_players => 1}),
    ok = asobi_match_server:join(Pid, ~"p1"),
    ?assertEqual(
        [],
        asobi_match_lobby:list_matches(#{
            listed => true, mode => ~"cap_mode", has_capacity => true
        })
    ),
    ?assertEqual(
        1, length(asobi_match_lobby:list_matches(#{listed => true, mode => ~"cap_mode"}))
    ),
    stop_match(Pid).
