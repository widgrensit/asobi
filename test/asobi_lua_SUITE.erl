-module(asobi_lua_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([
    all/0,
    groups/0,
    init_per_suite/1,
    end_per_suite/1,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    lua_match_lifecycle/1,
    lua_match_with_input/1,
    lua_match_finishes/1,
    lua_bot_joins_and_plays/1,
    lua_bot_with_script/1,
    lua_bot_default_ai/1,
    lua_match_server_integration/1,
    lua_match_server_finished/1
]).

all() ->
    [{group, lua_match}, {group, lua_bot}, {group, lua_integration}].

groups() ->
    [
        {lua_match, [sequence], [
            lua_match_lifecycle,
            lua_match_with_input,
            lua_match_finishes
        ]},
        {lua_bot, [sequence], [
            lua_bot_default_ai,
            lua_bot_with_script,
            lua_bot_joins_and_plays
        ]},
        {lua_integration, [sequence], [
            lua_match_server_integration,
            lua_match_server_finished
        ]}
    ].

init_per_suite(Config) ->
    case ets:whereis(asobi_match_state) of
        undefined -> ets:new(asobi_match_state, [named_table, public, set]);
        _ -> ok
    end,
    case whereis(nova_scope) of
        undefined ->
            {ok, Pg} = pg:start_link(nova_scope),
            unlink(Pg);
        _ ->
            ok
    end,
    FixtureDir = filename:absname(
        filename:join([code:lib_dir(asobi), "test", "fixtures", "lua"])
    ),
    [{fixture_dir, FixtureDir} | Config].

end_per_suite(_Config) ->
    ok.

init_per_testcase(_TC, Config) ->
    meck:new(asobi_repo, [no_link]),
    meck:expect(asobi_repo, insert, fun(_CS) -> {ok, #{}} end),
    meck:expect(asobi_repo, insert, fun(_CS, _Opts) -> {ok, #{}} end),
    meck:new(asobi_presence, [non_strict, no_link]),
    meck:expect(asobi_presence, send, fun(_PlayerId, _Msg) -> ok end),
    Config.

end_per_testcase(_TC, _Config) ->
    meck:unload(asobi_presence),
    meck:unload(asobi_repo),
    ok.

%% --- Helpers ---

fixture(Config, Name) ->
    filename:join(?config(fixture_dir, Config), Name).

start_lua_match(Config) ->
    start_lua_match(Config, "test_match.lua", #{}).

start_lua_match(Config, Script, Extra) ->
    ScriptPath = fixture(Config, Script),
    MatchConfig = maps:merge(
        #{
            game_module => asobi_lua_match,
            game_config => #{lua_script => ScriptPath},
            min_players => 2,
            max_players => 4,
            tick_rate => 50,
            mode => ~"test"
        },
        Extra
    ),
    {ok, Pid} = asobi_match_server:start_link(MatchConfig),
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

%% --- lua_match group ---

lua_match_lifecycle(Config) ->
    Pid = start_lua_match(Config),
    %% Starts in waiting
    Info1 = asobi_match_server:get_info(Pid),
    ?assertEqual(waiting, maps:get(status, Info1)),

    %% Join players
    ok = asobi_match_server:join(Pid, ~"p1"),
    ok = asobi_match_server:join(Pid, ~"p2"),
    timer:sleep(100),

    %% Transitions to running
    Info2 = asobi_match_server:get_info(Pid),
    ?assertEqual(running, maps:get(status, Info2)),
    ?assertEqual(2, maps:get(player_count, Info2)),

    %% Leave
    asobi_match_server:leave(Pid, ~"p1"),
    timer:sleep(50),
    Info3 = asobi_match_server:get_info(Pid),
    ?assertEqual(1, maps:get(player_count, Info3)),

    stop(Pid).

lua_match_with_input(Config) ->
    Pid = start_lua_match(Config),
    ok = asobi_match_server:join(Pid, ~"p1"),
    ok = asobi_match_server:join(Pid, ~"p2"),
    timer:sleep(100),

    %% Send movement input
    asobi_match_server:handle_input(Pid, ~"p1", #{
        ~"right" => true, ~"left" => false, ~"up" => false, ~"down" => false
    }),
    timer:sleep(100),

    %% Send shoot input
    asobi_match_server:handle_input(Pid, ~"p1", #{
        ~"shoot" => true, ~"aim_x" => 200.0, ~"aim_y" => 150.0
    }),
    timer:sleep(100),

    %% Still running
    Info = asobi_match_server:get_info(Pid),
    ?assertEqual(running, maps:get(status, Info)),

    stop(Pid).

lua_match_finishes(Config) ->
    Pid = start_lua_match(Config, "finish_immediately.lua", #{}),
    unlink(Pid),
    Ref = monitor(process, Pid),

    ok = asobi_match_server:join(Pid, ~"p1"),
    ok = asobi_match_server:join(Pid, ~"p2"),

    %% Match should finish after first tick
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 10000 ->
        stop(Pid),
        ct:fail(match_did_not_finish)
    end.

%% --- lua_bot group ---

lua_bot_default_ai(Config) ->
    Pid = start_lua_match(Config),
    ok = asobi_match_server:join(Pid, ~"p1"),
    timer:sleep(50),

    %% Start a bot with no Lua script (default AI) — bot join triggers running
    {ok, BotPid} = asobi_bot:start_link(Pid, ~"bot_Test", undefined),
    unlink(BotPid),
    timer:sleep(200),

    %% Bot should have joined
    Info = asobi_match_server:get_info(Pid),
    ?assert(lists:member(~"bot_Test", maps:get(players, Info))),
    ?assertEqual(running, maps:get(status, Info)),

    exit(BotPid, shutdown),
    timer:sleep(50),
    stop(Pid).

lua_bot_with_script(Config) ->
    Pid = start_lua_match(Config),
    ok = asobi_match_server:join(Pid, ~"p1"),
    timer:sleep(50),

    %% Start a bot with Lua AI
    BotScript = fixture(Config, "bots/chaser.lua"),
    {ok, BotPid} = asobi_bot:start_link(Pid, ~"bot_Chaser", BotScript),
    unlink(BotPid),
    timer:sleep(200),

    Info = asobi_match_server:get_info(Pid),
    ?assert(lists:member(~"bot_Chaser", maps:get(players, Info))),
    ?assertEqual(running, maps:get(status, Info)),

    exit(BotPid, shutdown),
    timer:sleep(50),
    stop(Pid).

lua_bot_joins_and_plays(Config) ->
    Pid = start_lua_match(Config),
    ok = asobi_match_server:join(Pid, ~"p1"),
    timer:sleep(50),

    %% Start bot — becomes second player, match starts
    {ok, BotPid} = asobi_bot:start_link(Pid, ~"bot_Active", undefined),
    unlink(BotPid),
    timer:sleep(300),

    %% Bot is still alive and playing
    ?assert(is_process_alive(BotPid)),
    Info = asobi_match_server:get_info(Pid),
    ?assertEqual(running, maps:get(status, Info)),
    ?assertEqual(2, maps:get(player_count, Info)),

    exit(BotPid, shutdown),
    timer:sleep(50),
    stop(Pid).

%% --- lua_integration group ---

lua_match_server_integration(Config) ->
    %% Full lifecycle: start match, join players, send inputs, verify running
    Pid = start_lua_match(Config),

    ok = asobi_match_server:join(Pid, ~"p1"),
    ok = asobi_match_server:join(Pid, ~"p2"),
    timer:sleep(100),

    %% Send several rounds of input
    lists:foreach(
        fun(I) ->
            asobi_match_server:handle_input(Pid, ~"p1", #{
                ~"right" => I rem 2 =:= 0,
                ~"left" => I rem 2 =:= 1,
                ~"up" => false,
                ~"down" => false,
                ~"shoot" => true,
                ~"aim_x" => float(I * 10),
                ~"aim_y" => 100.0
            }),
            timer:sleep(60)
        end,
        lists:seq(1, 10)
    ),

    Info = asobi_match_server:get_info(Pid),
    ?assertEqual(running, maps:get(status, Info)),

    %% Boon pick input
    asobi_match_server:handle_input(Pid, ~"p1", #{
        ~"type" => ~"boon_pick", ~"boon_id" => ~"hp_boost"
    }),
    timer:sleep(100),

    stop(Pid).

lua_match_server_finished(Config) ->
    %% Test match that finishes via Lua _finished flag
    Pid = start_lua_match(Config, "finish_immediately.lua", #{}),
    unlink(Pid),
    Ref = monitor(process, Pid),

    ok = asobi_match_server:join(Pid, ~"p1"),
    ok = asobi_match_server:join(Pid, ~"p2"),

    %% Should finish and send finished event via presence
    receive
        {'DOWN', Ref, process, Pid, normal} ->
            %% Verify presence was notified of finish
            ?assert(meck:called(asobi_presence, send, [~"p1", '_'])),
            ?assert(meck:called(asobi_presence, send, [~"p2", '_']))
    after 10000 ->
        stop(Pid),
        ct:fail(match_did_not_finish)
    end.
