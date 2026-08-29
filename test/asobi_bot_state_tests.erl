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
        {"a per-bot cooldown gates input as the guide describes", fun cooldown_gates_input/0},
        {"a bare `return` keeps state and falls back only on the input",
            fun bare_return_keeps_state/0},
        {"a state past the ceiling is reloaded and its globals are gone",
            fun oversized_state_reloads/0},
        {"a self-referencing table costs the tick, not the bot", fun cyclic_result_survives/0},
        {"a returned function never reaches the match script", fun callable_input_dropped/0}
    ]}.

setup() ->
    ok = asobi_bot_input_game:reset(),
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
    ?assertEqual([1, 2, 3], lists:sublist(Ns, 3)).

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

bare_return_keeps_state() ->
    %% `return {}` is one value and takes the ordinary path; only a bare `return`
    %% yields none. Without the {ok, [], _} clause the odd call's increment is
    %% rolled back and `calls` never reaches an even number.
    Script = temp_script(
        ~"""
        calls = 0
        function think(_bot, _state)
            calls = calls + 1
            if calls % 2 == 1 then return end
            return { n = calls }
        end
        """
    ),
    Ns = run_bot(Script, ~"bot_Bare", fun(Inputs) -> length(Inputs) >= 7 end, ~"n"),
    ?assertEqual([2, 4, 6], lists:sublist(Ns, 3)).

oversized_state_reloads() ->
    %% Luerl collects garbage, not what a script keeps live, so a hoarding script
    %% grows without bound and the collector gives up on it. Past the ceiling the
    %% script is reloaded, which is observable as `calls` restarting from 1.
    application:set_env(asobi, max_bot_state_words, 6000),
    Script = temp_script(
        ~"""
        calls = 0
        hoard = {}
        function think(_bot, _state)
            calls = calls + 1
            for i = 1, 50 do
                hoard[#hoard + 1] = { i, i, i, i }
            end
            return { n = calls }
        end
        """
    ),
    try
        Ns = run_bot(Script, ~"bot_Hoarder", fun(Inputs) -> length(Inputs) >= 8 end, ~"n"),
        ?assert(lists:max(Ns) < length(Ns))
    after
        application:unset_env(asobi, max_bot_state_words)
    end.

cyclic_result_survives() ->
    %% luerl:decode/2 raises on a table that references itself. Uncaught that
    %% kills a `temporary` child and the match loses the bot for good, so the
    %% bot must stay alive and keep sending.
    Script = temp_script(
        ~"""
        calls = 0
        function think(_bot, _state)
            calls = calls + 1
            local t = { n = calls }
            t.self = t
            return t
        end
        """
    ),
    MatchPid = start_match(),
    BotPid = start_bot(MatchPid, ~"bot_Cyclic", Script),
    try
        wait_until(fun() -> length(asobi_bot_input_game:inputs()) >= 3 end),
        ?assert(is_process_alive(BotPid))
    after
        stop_process(BotPid),
        stop_process(MatchPid),
        file:delete(Script)
    end.

callable_input_dropped() ->
    %% An input crosses into the match script's own Luerl state, so it carries
    %% only what a client could have sent.
    Script = temp_script(
        ~"""
        function think(_bot, _state)
            return { shoot = true, aim = { x = 1 }, evil = function() return 1 end }
        end
        """
    ),
    MatchPid = start_match(),
    BotPid = start_bot(MatchPid, ~"bot_Callable", Script),
    try
        wait_until(fun() -> asobi_bot_input_game:inputs() =/= [] end),
        [Input | _] = asobi_bot_input_game:inputs(),
        %% The nested table survives - a bot may send what a player can.
        ?assertEqual([~"aim", ~"shoot"], lists:sort(maps:keys(Input)))
    after
        stop_process(BotPid),
        stop_process(MatchPid),
        file:delete(Script)
    end.

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
