-module(asobi_bot_state_tests).
-include_lib("eunit/include/eunit.hrl").

%% asobi_bot used to call think/2 and throw the Luerl state it got back away,
%% so every tick re-entered the script exactly as it was loaded. A bot script
%% could not remember anything between calls: the per-bot cooldown table the
%% bots guide tells authors to keep silently reset every 100 ms, and the guard
%% built on it fired on every tick. The state is threaded through now.

-define(BASE_CONFIG, #{
    game_module => asobi_bot_input_game,
    min_players => 1,
    max_players => 4,
    tick_rate => 50
}).

bot_state_test_() ->
    {foreach, fun setup/0, fun cleanup/1, [
        {"a bot script's globals survive across think calls", fun globals_persist/0},
        {"a per-bot cooldown gates input as the guide describes", fun cooldown_gates_input/0}
    ]}.

setup() ->
    _ = asobi_bot_input_game:log(),
    true = ets:delete_all_objects(asobi_bot_input_log),
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

globals_persist() ->
    Script = temp_script(
        ~"""
        calls = 0
        function think(_bot, _state)
            calls = calls + 1
            return { n = calls }
        end
        """
    ),
    Ns = run_bot(Script, ~"bot_Counter", fun(Inputs) -> length(Inputs) >= 3 end, ~"n"),
    ?assertMatch([_, _, _ | _], Ns),
    ?assertEqual(lists:sublist([1, 2, 3], 3), lists:sublist(Ns, 3)).

cooldown_gates_input() ->
    %% The pattern guides/lua-bots.md documents: remember the last tick this
    %% bot acted on, keyed by bot id, and stay quiet until the cooldown is up.
    Script = temp_script(
        ~"""
        tick = 0
        next_action = {}
        function think(bot, _state)
            tick = tick + 1
            if (next_action[bot] or 0) > tick then
                return {}
            end
            next_action[bot] = tick + 3
            return { fired = tick }
        end
        """
    ),
    Fired = run_bot(
        Script, ~"bot_Cooldown", fun(Inputs) -> length(Inputs) >= 8 end, ~"fired"
    ),
    %% Every fourth call, not every call.
    ?assertEqual([1, 4, 7], lists:sublist(Fired, 3)).

%% --- helpers ---

run_bot(Script, BotId, Until, Key) ->
    MatchPid = start_match(),
    BotPid = start_bot(MatchPid, BotId, Script),
    try
        wait_until(fun() -> Until(asobi_bot_input_game:inputs()) end),
        [
            round(V)
         || Input <- asobi_bot_input_game:inputs(),
            {ok, V} <- [maps:find(Key, Input)],
            is_number(V)
        ]
    after
        stop_process(BotPid),
        stop_process(MatchPid),
        file:delete(Script)
    end.

start_match() ->
    {ok, Pid} = asobi_match_server:start_link(?BASE_CONFIG),
    unlink(Pid),
    Pid.

start_bot(MatchPid, BotId, Script) ->
    {ok, Pid} = asobi_bot:start_link(MatchPid, BotId, Script),
    unlink(Pid),
    Pid.

temp_script(Code) ->
    Name = "bot_state_" ++ integer_to_list(erlang:unique_integer([positive])) ++ ".lua",
    Path = filename:join([filename:basedir(user_cache, "asobi_lua_tests"), Name]),
    ok = filelib:ensure_dir(Path),
    ok = file:write_file(Path, Code),
    Path.

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
