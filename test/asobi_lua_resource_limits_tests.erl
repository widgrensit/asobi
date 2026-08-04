-module(asobi_lua_resource_limits_tests).
-include_lib("eunit/include/eunit.hrl").

%% Resource-limit tests: every Lua callback EXCEPT handle_input runs in
%% a child process with a wall-clock budget. handle_input is hot-path
%% (2k+ inputs/sec at scale) and the spawn cost dominated real work; per
%% ADR 0002 it now runs directly. tick/init/get_state/join/leave still
%% spawn-isolate. We assert that the wrapped callbacks terminate within
%% a known bound, AND that handle_input does NOT (intentionally).

-spec fixture(string()) -> file:filename_all().
fixture(Name) ->
    {ok, LibDir} = safe_lib_dir(),
    filename:absname(filename:join([LibDir, "test", "fixtures", "lua", Name])).

-spec safe_lib_dir() -> {ok, string()}.
safe_lib_dir() ->
    case code:lib_dir(asobi) of
        {error, bad_name} -> error(asobi_not_loaded);
        Dir -> {ok, Dir}
    end.

%% --- Loader-level timeout always enforced ---

infinite_loop_call_is_terminated_test() ->
    %% asobi_lua_loader:call/4 must kill the child and return an error
    %% rather than blocking the parent. Which bound trips first depends on
    %% how fast this machine interprets Lua - the CPU budget usually gets
    %% there before the 100ms deadline - so assert the contract that
    %% matters: killed, with a resource reason, inside the window.
    {ok, St} = asobi_lua_loader:new(temp_script(infinite_loop_script())),
    Cfg = encode_map(#{}, St),
    Start = erlang:monotonic_time(millisecond),
    Result = asobi_lua_loader:call(tick, [Cfg], St, 100),
    Elapsed = erlang:monotonic_time(millisecond) - Start,
    ?assert(lists:member(Result, [{error, timeout}, {error, reductions_exhausted}])),
    %% Wall-clock should be roughly the timeout; certainly under 1s.
    ?assert(Elapsed < 1000).

%% --- #348: reduction budget ---

%% The wall-clock timeout bounds latency, not work. Without a CPU bound a
%% spinning callback is killed at its deadline and simply does it again on the
%% next tick, holding a scheduler for its full budget forever.
reduction_budget_kills_spin_before_deadline_test() ->
    with_reductions_per_ms(1, fun() ->
        {ok, St} = asobi_lua_loader:new(temp_script(infinite_loop_script())),
        Cfg = encode_map(#{}, St),
        Start = erlang:monotonic_time(millisecond),
        %% Budget is 1 reduction per ms of the callback's own window, so a
        %% 5s window buys 5000 reductions - gone almost immediately, while
        %% the deadline is nowhere near.
        Result = asobi_lua_loader:call(tick, [Cfg], St, 5000),
        Elapsed = erlang:monotonic_time(millisecond) - Start,
        ?assertEqual({error, reductions_exhausted}, Result),
        ?assert(Elapsed < 1000)
    end).

%% Setting the rate to 0 restores the pre-#348 behaviour exactly: one receive
%% for the whole window, and the deadline is the only thing that fires.
reduction_budget_disabled_falls_back_to_timeout_test() ->
    with_reductions_per_ms(0, fun() ->
        {ok, St} = asobi_lua_loader:new(temp_script(infinite_loop_script())),
        Cfg = encode_map(#{}, St),
        Start = erlang:monotonic_time(millisecond),
        Result = asobi_lua_loader:call(tick, [Cfg], St, 200),
        Elapsed = erlang:monotonic_time(millisecond) - Start,
        ?assertEqual({error, timeout}, Result),
        %% Ran the full window rather than being cut short by a budget.
        ?assert(Elapsed >= 200)
    end).

%% The budget must not fire on work a game legitimately does. A tick that
%% builds and sums 200 entity tables costs ~24k reductions; the default rate
%% gives a 500ms tick 25,000,000.
reduction_budget_passes_normal_callback_test() ->
    {ok, St} = asobi_lua_loader:new(temp_script(entity_tick_script())),
    Cfg = encode_map(#{}, St),
    ?assertMatch({ok, [_ | _], _}, asobi_lua_loader:call(tick, [Cfg], St, 500)).

%% The three resource failures must be distinguishable in a log line, or an
%% operator cannot tell a script that burned CPU from one that was merely slow.
reduction_exhaustion_renders_distinctly_test() ->
    ?assertEqual(
        ~"callback exhausted its CPU budget",
        asobi_lua_game_error:format_reason(reductions_exhausted)
    ),
    ?assertNotEqual(
        asobi_lua_game_error:format_reason(timeout),
        asobi_lua_game_error:format_reason(reductions_exhausted)
    ),
    ?assertNotEqual(
        asobi_lua_game_error:format_reason(heap_exhausted),
        asobi_lua_game_error:format_reason(reductions_exhausted)
    ).

with_reductions_per_ms(Rate, Fun) ->
    Prev = application:get_env(asobi, max_reductions_per_ms),
    application:set_env(asobi, max_reductions_per_ms, Rate),
    try
        Fun()
    after
        case Prev of
            {ok, Old} -> application:set_env(asobi, max_reductions_per_ms, Old);
            undefined -> application:unset_env(asobi, max_reductions_per_ms)
        end
    end.

stack_overflow_does_not_crash_parent_test() ->
    %% Lua-level stack overflow must not propagate as an Erlang error
    %% — call/4 catches it and returns {error, _}.
    {ok, St} = asobi_lua_loader:new(temp_script(stack_overflow_script())),
    Cfg = encode_map(#{}, St),
    Result = asobi_lua_loader:call(tick, [Cfg], St, 1000),
    ?assertMatch({error, _}, Result).

%% --- Bridge-level timeouts: every callback wrapped ---

%% The matrix below is the contract: every callback the bridge calls
%% out to is wrapped with call/4. The match.lua bridge uses INIT_TIMEOUT
%% / TICK_TIMEOUT / etc.; these tests inject infinite-loop callbacks
%% and assert the wrapper kills them.

match_init_timeout_test() ->
    %% A `while true do end` inside init/1 used to wedge the match
    %% gen_server forever (call/3 ran in-process). Now init runs under
    %% INIT_TIMEOUT and the bridge surfaces an error.
    Path = temp_script(
        ~"""
        match_size = 1
        function init(_) while true do end end
        function join(id, s) return s end
        function leave(id, s) return s end
        function handle_input(_, _, s) return s end
        function tick(s) return s end
        function get_state(_, s) return s end
        """
    ),
    %% asobi_lua_match:init/1 calls erlang:error/1 on lua failure, so
    %% the test process should see the error rather than hang.
    Self = self(),
    Pid = spawn(fun() ->
        try asobi_lua_match:init(#{lua_script => Path}) of
            R -> Self ! {result, R}
        catch
            Class:Reason -> Self ! {error, Class, Reason}
        end
    end),
    Result =
        receive
            {result, _} = R -> R;
            {error, _, _} = E -> E
        after 3000 ->
            exit(Pid, kill),
            {timeout_blocked}
        end,
    ?assertNotEqual({timeout_blocked}, Result).

world_handle_input_no_wall_clock_timeout_test() ->
    %% Same contract as the match bridge — see ADR 0002. World's
    %% handle_input runs directly in the calling process; an
    %% infinite-loop input does not self-terminate.
    Path = temp_script(
        ~"""
        match_size = 1
        game_type = "world"
        function init(_) return {} end
        function generate_world(_, _) return { ["0,0"] = {} } end
        function on_zone_loaded(_, _, s) return s, {} end
        function zone_tick(ents, s) return ents, s end
        function handle_input(_, _, _) while true do end end
        """
    ),
    Config = #{game_config => #{lua_script => Path}},
    {ok, ZoneStates} = asobi_lua_world:generate_world(0, Config),
    Zone0 = asobi_lua_world:init_zone_state(Config, maps:get({0, 0}, ZoneStates)),
    Self = self(),
    %% Process dictionary doesn't inherit across spawns — set it inside
    %% the child so handle_input enters the Lua call path.
    {Pid, Ref} = spawn_monitor(fun() ->
        erlang:put({asobi_lua_world, zone_state}, Zone0),
        Result = asobi_lua_world:handle_input(~"p1", #{~"x" => 1}, #{}),
        Self ! {result, Result}
    end),
    receive
        {result, _} ->
            ?assert(false, "world handle_input must not self-terminate; ADR 0002")
    after 500 ->
        ?assert(is_process_alive(Pid)),
        exit(Pid, kill),
        receive
            {'DOWN', Ref, process, Pid, _} -> ok
        after 1000 ->
            ok
        end
    end.

match_handle_input_no_wall_clock_timeout_test() ->
    %% Per ADR 0002, handle_input intentionally has NO wall-clock budget.
    %% spawn-overhead at 2k inputs/sec dominated real Lua work, so the
    %% input path runs directly in the calling process. The trade is
    %% explicit: a runaway handle_input now hangs the match server until
    %% its gen_server timeout trips. This test pins the new contract:
    %% an infinite-loop handle_input does NOT return on its own.
    Path = temp_script(
        ~"""
        match_size = 1
        function init(_) return { n = 0 } end
        function join(id, s) return s end
        function leave(id, s) return s end
        function handle_input(_, _, _) while true do end end
        function tick(s) s.n = s.n + 1; return s end
        function get_state(_, s) return s end
        """
    ),
    {ok, S0} = asobi_lua_match:init(#{lua_script => Path}),
    Self = self(),
    {Pid, Ref} = spawn_monitor(fun() ->
        Result = asobi_lua_match:handle_input(~"p1", #{~"x" => 1}, S0),
        Self ! {result, Result}
    end),
    receive
        {result, _} ->
            ?assert(false, "handle_input must not self-terminate; ADR 0002 removed bounded_eval")
    after 500 ->
        ?assert(is_process_alive(Pid)),
        exit(Pid, kill),
        receive
            {'DOWN', Ref, process, Pid, _} -> ok
        after 1000 ->
            ok
        end
    end.

match_get_state_timeout_test() ->
    Path = temp_script(
        ~"""
        match_size = 1
        function init(_) return { n = 0 } end
        function join(id, s) return s end
        function leave(id, s) return s end
        function handle_input(_, _, s) return s end
        function tick(s) s.n = s.n + 1; return s end
        function get_state(_, _) while true do end end
        """
    ),
    {ok, S0} = asobi_lua_match:init(#{lua_script => Path}),
    Self = self(),
    Pid = spawn(fun() ->
        View = asobi_lua_match:get_state(~"p1", S0),
        Self ! {result, View}
    end),
    Result =
        receive
            {result, R} -> R
        after 3000 ->
            exit(Pid, kill),
            timeout_blocked
        end,
    ?assertNotEqual(timeout_blocked, Result),
    %% on timeout the bridge returns an empty map
    ?assertEqual(#{}, Result).

match_join_timeout_test() ->
    Path = temp_script(
        ~"""
        match_size = 1
        function init(_) return { n = 0 } end
        function join(_, _) while true do end end
        function leave(id, s) return s end
        function handle_input(_, _, s) return s end
        function tick(s) return s end
        function get_state(_, s) return s end
        """
    ),
    {ok, S0} = asobi_lua_match:init(#{lua_script => Path}),
    Self = self(),
    Pid = spawn(fun() ->
        Self ! {result, asobi_lua_match:join(~"p1", S0)}
    end),
    Result =
        receive
            {result, R} -> R
        after 3000 ->
            exit(Pid, kill),
            timeout_blocked
        end,
    ?assertNotEqual(timeout_blocked, Result),
    ?assertMatch({error, _}, Result).

%% --- Sandbox keeps the BEAM alive ---

os_exit_does_not_halt_beam_test() ->
    %% Even if a script tries to call os.exit (which used to halt the
    %% whole BEAM via erlang:halt/1), os.exit is nil after sandboxing
    %% — so calling it is just an error, not a node-killer. We assert
    %% the test process is still alive after the attempt.
    {ok, St} = asobi_lua_loader:new(fixture("test_match.lua")),
    %% pcall traps the nil-call error; we just need it to not halt.
    {ok, _, _} = luerl:do("pcall(function() return os.exit(0) end)\nreturn 1", St),
    ?assert(is_pid(self())),
    ?assert(is_process_alive(self())).

%% --- Helpers ---

infinite_loop_script() ->
    ~"""
    function tick(_) while true do end end
    function init(_) return {} end
    function join(id, s) return s end
    function leave(id, s) return s end
    function handle_input(_, _, s) return s end
    function get_state(_, s) return s end
    """.

entity_tick_script() ->
    ~"""
    function tick(s)
      local t = {}
      for i = 1, 200 do t[i] = { x = i * 1.5, y = i * 2.5, hp = 100 } end
      local sum = 0
      for i = 1, 200 do sum = sum + t[i].x end
      s.sum = sum
      return s
    end
    function init(_) return {} end
    function join(id, s) return s end
    function leave(id, s) return s end
    function handle_input(_, _, s) return s end
    function get_state(_, s) return s end
    """.

stack_overflow_script() ->
    ~"""
    function tick(_) local function r() return r() end return r() end
    function init(_) return {} end
    function join(id, s) return s end
    function leave(id, s) return s end
    function handle_input(_, _, s) return s end
    function get_state(_, s) return s end
    """.

-spec temp_script(binary()) -> file:filename_all().
temp_script(Code) ->
    Name = "resource_" ++ integer_to_list(erlang:unique_integer([positive])) ++ ".lua",
    Path = filename:join([filename:basedir(user_cache, "asobi_lua_tests"), Name]),
    ok = filelib:ensure_dir(Path),
    ok = file:write_file(Path, Code),
    Path.

-spec encode_map(map(), dynamic()) -> dynamic().
encode_map(Map, St) ->
    {Enc, _} = luerl:encode(Map, St),
    Enc.
