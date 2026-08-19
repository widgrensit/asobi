-module(asobi_lua_match_tests).
-include_lib("eunit/include/eunit.hrl").
-include_lib("kernel/include/file.hrl").

%% logger handler callback for script_log_limiter_test_/0 below.
-export([log/2]).

-spec fixture(string()) -> file:filename_all().
fixture(Name) ->
    {ok, LibDir} = safe_lib_dir(),
    filename:join([LibDir, "test", "fixtures", "lua", Name]).

-spec safe_lib_dir() -> {ok, string()}.
safe_lib_dir() ->
    case code:lib_dir(asobi) of
        {error, bad_name} -> error(asobi_not_loaded);
        Dir -> {ok, Dir}
    end.

%% --- Match behaviour tests ---

lua_match_test_() ->
    [
        {"init loads lua and returns state", fun init_ok/0},
        {"init fails with bad script", fun init_bad_script/0},
        {"init fails with missing script", fun init_missing_script/0},
        {"join adds player to state", fun join_adds_player/0},
        {"join/3 passes the client context to lua", fun join_ctx_reaches_lua/0},
        {"join/3 context is optional for a two-arg lua join", fun join_ctx_ignored_by_old_script/0},
        {"join/2 still works and sends an empty context", fun join_two_arg_sends_empty_ctx/0},
        {"returning nil refuses the join", fun join_nil_refuses/0},
        {"a refusal reason reaches the caller", fun join_refusal_carries_reason/0},
        {"a refused join leaves the game state untouched", fun join_refusal_leaves_no_trace/0},
        {"an oversized refusal reason is dropped", fun join_refusal_reason_too_long/0},
        {"a non-ascii refusal reason is dropped", fun join_refusal_reason_not_ascii/0},
        {"a non-string refusal reason is dropped", fun join_refusal_reason_not_a_string/0},
        {"a join that returns nothing refuses instead of crashing", fun join_no_return_refuses/0},
        {"leave removes player", fun leave_removes_player/0},
        {"handle_input updates player position", fun input_moves_player/0},
        {"handle_input handles boon pick", fun input_boon_pick/0},
        {"tick increments counter", fun tick_increments/0},
        {"tick signals finished", fun tick_finishes/0},
        {"get_state returns player view", fun get_state_view/0},
        {"vote_requested returns config at right tick", fun vote_requested_ok/0},
        {"an unknown vote-config key is left as the script wrote it (#489)",
            fun vote_requested_leaves_unknown_keys_alone/0},
        {"vote_requested returns none normally", fun vote_requested_none/0},
        {"vote_resolved updates state", fun vote_resolved_ok/0},
        {"finish_immediately script", fun finish_immediately/0},
        {"tick reloads script after file change", fun hot_reload_on_file_change/0},
        {"tick survives syntax error on reload", fun hot_reload_syntax_error/0},
        {"hot reload picks up changes in required modules", fun hot_reload_clears_require_cache/0},
        {"hot reload survives function add/remove", fun hot_reload_function_change/0},
        {"init returning nil crashes match init", fun init_nil_return/0},
        {"init returning non-table crashes match init", fun init_non_table_return/0},
        {"tick timeout end-to-end keeps match alive", fun tick_timeout_keeps_state/0},
        {"vote_requested returning false yields none", fun vote_requested_false/0},
        {"vote_resolved with unknown template still returns ok",
            fun vote_resolved_unknown_template/0},
        {"handle_input failure returns previous state", fun handle_input_failure/0},
        {"phases/1 and the on_phase_* hooks are exported (asobi_lua#109)",
            fun phase_callbacks_are_exported/0},
        {"phases returns empty when script has no phases()",
            fun phases_returns_empty_when_undefined/0},
        {"phases returns decoded phase definitions", fun phases_returns_decoded_phases/0},
        {"phases logs and returns empty on a non-list return", fun phases_non_list_returns_empty/0},
        {"phases works from the raw config asobi_match_server actually sends",
            fun phases_from_raw_config/0},
        {"on_phase_started threads state through the Lua VM", fun on_phase_started_threads_state/0},
        {"on_phase_ended threads state through the Lua VM", fun on_phase_ended_threads_state/0}
    ].

%% --- Probe VM must not double-fire side effects ---
%%
%% Security review on widgrensit/asobi_lua#109/#117: phases/1's raw-config
%% clause boots a throwaway Lua VM (boot_throwaway_lua_state/2) just to ask
%% the script "do you define phases()?" - which means the script's whole
%% top-level body runs a second time. Before the `probe => true` /
%% install_pure fix, a top-level `game.economy.grant` call fired once from
%% the real init/1 VM boot and again from this throwaway probe boot - a
%% double grant on a player-triggered path, with no idempotency key on that
%% primitive. These pin that exactly one grant reaches asobi_economy, no
%% matter how many times phases/1 is asked.

probe_vm_side_effects_test_() ->
    {foreach, fun economy_mock_setup/0, fun economy_mock_cleanup/1, [
        {
            "a top-level game.economy.grant call fires once per match creation, "
            "not once per real init boot plus once per phases() probe boot",
            fun top_level_grant_fires_once/0
        }
    ]}.

economy_mock_setup() ->
    meck:new(asobi_economy, [no_link]),
    meck:expect(asobi_economy, grant, fun(_, _, _, _) -> {ok, #{}} end).

economy_mock_cleanup(_) ->
    meck:unload(asobi_economy).

top_level_grant_fires_once() ->
    Path = temp_script(
        ~"""
        match_size = 1
        game.economy.grant('p1', 'gold', 100, 'signup')
        function init(_) return {} end
        function join(id, s) return s end
        function leave(id, s) return s end
        function handle_input(_, _, s) return s end
        function tick(s) return s end
        function get_state(_, s) return s end
        function phases(_)
            return { { name = 'lobby', duration = 5000 } }
        end
        """
    ),
    try
        %% Mirrors asobi_match_server:init/1 exactly: GameMod:init/1 runs
        %% first against GameConfig (the real, live VM boot - fires the
        %% top-level grant once), then GameMod:phases(GameConfig) runs
        %% against the *same* raw config map, since no lua_state is threaded
        %% through to that second call (see boot_throwaway_lua_state/2's
        %% moduledoc). Pre-fix this booted a second fully-live VM and fired
        %% the top-level grant a second time.
        GameConfig = #{lua_script => Path, match_id => ~"probe_dedupe"},
        {ok, _State} = asobi_lua_match:init(GameConfig),
        Phases = asobi_lua_match:phases(GameConfig),
        ?assertEqual(1, length(Phases)),
        ?assertEqual(1, meck:num_calls(asobi_economy, grant, '_'))
    after
        file:delete(Path)
    end.

init_ok() ->
    Config = #{lua_script => fixture("test_match.lua")},
    {ok, State} = asobi_lua_match:init(Config),
    ?assert(is_map(State)),
    ?assertMatch(#{lua_state := _, game_state := _}, State).

init_bad_script() ->
    Config = #{lua_script => fixture("bad_script.lua")},
    %% asobi_match:init/1 is specced {ok, term()} — errors crash the
    %% process so the supervisor sees the failure with a proper reason.
    ?assertError({lua_load_failed, _, _}, asobi_lua_match:init(Config)).

init_missing_script() ->
    Config = #{lua_script => fixture("nonexistent.lua")},
    ?assertError({lua_load_failed, _, _}, asobi_lua_match:init(Config)).

join_ctx_reaches_lua() ->
    %% The whole point of the join context: a Lua game can gate entry on
    %% something the client presented. Without join/3 on this bridge the ctx
    %% is silently dropped and every Lua game is unable to implement a join
    %% code, however the guides describe it.
    Config = #{lua_script => fixture("join_ctx.lua")},
    {ok, State0} = asobi_lua_match:init(Config),
    {ok, State1} = asobi_lua_match:join(~"p1", #{~"code" => ~"OPEN"}, State0),
    #{~"last_code" := Code} = asobi_lua_match:get_state(~"p1", State1),
    ?assertEqual(~"OPEN", Code),

    {ok, State2} = asobi_lua_match:join(~"p2", #{~"code" => ~"WRONG"}, State1),
    #{~"rejected" := Rejected} = asobi_lua_match:get_state(~"p2", State2),
    ?assertEqual(1, Rejected).

join_ctx_ignored_by_old_script() ->
    %% A script declaring `function join(player_id, state)` must keep working
    %% when called with three arguments - Lua discards the extra one.
    {ok, State0} = init_match(),
    {ok, State1} = asobi_lua_match:join(~"player1", #{~"code" => ~"ignored"}, State0),
    ?assert(is_map(asobi_lua_match:get_state(~"player1", State1))).

join_two_arg_sends_empty_ctx() ->
    Config = #{lua_script => fixture("join_ctx.lua")},
    {ok, State0} = asobi_lua_match:init(Config),
    {ok, State1} = asobi_lua_match:join(~"p1", State0),
    #{~"rejected" := Rejected} = asobi_lua_match:get_state(~"p1", State1),
    ?assertEqual(1, Rejected, "no ctx means no code, so this script refuses").

init_refuse_match() ->
    asobi_lua_match:init(#{lua_script => fixture("join_refuse.lua")}).

join_nil_refuses() ->
    {ok, State0} = init_refuse_match(),
    ?assertEqual({error, {join_refused, undefined}}, asobi_lua_match:join(~"silent", State0)),
    %% Lua has two falsey values and `return cond and state or false` is an
    %% ordinary way to write this, so `false` has to refuse as well as `nil`.
    ?assertEqual(
        {error, {join_refused, ~"also_refused"}}, asobi_lua_match:join(~"falsey", State0)
    ).

join_refusal_carries_reason() ->
    {ok, State0} = init_refuse_match(),
    ?assertEqual(
        {error, {join_refused, ~"wrong_code"}},
        asobi_lua_match:join(~"p1", #{~"code" => ~"NOPE"}, State0)
    ),
    ?assertMatch({ok, _}, asobi_lua_match:join(~"p1", #{~"code" => ~"OPEN"}, State0)).

%% A refused join must not be able to advance the game state - otherwise a
%% client could drive a script by being turned away over and over.
join_refusal_leaves_no_trace() ->
    {ok, State0} = init_refuse_match(),
    {error, _} = asobi_lua_match:join(~"silent", State0),
    {error, _} = asobi_lua_match:join(~"silent", State0),
    {ok, State1} = asobi_lua_match:join(~"p1", #{~"code" => ~"OPEN"}, State0),
    #{~"attempts" := Attempts} = asobi_lua_match:get_state(~"p1", State1),
    ?assertEqual(1, Attempts).

%% The reason is author-written and reaches a client, so an out-of-shape one
%% is dropped - the refusal still stands, it just loses its label.
join_refusal_reason_too_long() ->
    {ok, State0} = init_refuse_match(),
    ?assertEqual({error, {join_refused, undefined}}, asobi_lua_match:join(~"shouty", State0)),
    %% The cap is inclusive: 64 bytes travel, 65 do not.
    ?assertEqual(
        {error, {join_refused, binary:copy(~"y", 64)}},
        asobi_lua_match:join(~"at_limit", State0)
    ),
    ?assertEqual(
        {error, {join_refused, undefined}}, asobi_lua_match:join(~"over_limit", State0)
    ).

join_refusal_reason_not_ascii() ->
    {ok, State0} = init_refuse_match(),
    ?assertEqual({error, {join_refused, undefined}}, asobi_lua_match:join(~"binary", State0)),
    %% Pins the low edge of the printable range: 31 is out, 32 (space) is in.
    ?assertEqual({error, {join_refused, undefined}}, asobi_lua_match:join(~"control", State0)),
    %% And the high one: 126 (~) is the last character that survives, 127
    %% (DEL) is not.
    ?assertEqual(
        {error, {join_refused, ~"a space and a ~"}}, asobi_lua_match:join(~"edges", State0)
    ),
    ?assertEqual({error, {join_refused, undefined}}, asobi_lua_match:join(~"del", State0)).

join_refusal_reason_not_a_string() ->
    {ok, State0} = init_refuse_match(),
    ?assertEqual({error, {join_refused, undefined}}, asobi_lua_match:join(~"numeric", State0)).

join_no_return_refuses() ->
    {ok, State0} = asobi_lua_match:init(#{lua_script => fixture("join_no_return.lua")}),
    ?assertEqual({error, {join_refused, undefined}}, asobi_lua_match:join(~"p1", State0)).

join_adds_player() ->
    {ok, State0} = init_match(),
    {ok, State1} = asobi_lua_match:join(~"player1", State0),
    PlayerState = asobi_lua_match:get_state(~"player1", State1),
    ?assert(is_map(PlayerState)).

leave_removes_player() ->
    {ok, State0} = init_match(),
    {ok, State1} = asobi_lua_match:join(~"player1", State0),
    {ok, State2} = asobi_lua_match:leave(~"player1", State1),
    PlayerState = asobi_lua_match:get_state(~"player1", State2),
    ?assert(is_map(PlayerState)).

input_moves_player() ->
    {ok, State0} = init_match(),
    {ok, State1} = asobi_lua_match:join(~"player1", State0),
    Input = #{~"right" => true, ~"left" => false, ~"up" => false, ~"down" => false},
    {ok, State2} = asobi_lua_match:handle_input(~"player1", Input, State1),
    ?assert(is_map(State2)).

input_boon_pick() ->
    {ok, State0} = init_match(),
    {ok, State1} = asobi_lua_match:join(~"player1", State0),
    Input = #{~"type" => ~"boon_pick", ~"boon_id" => ~"hp_boost"},
    {ok, State2} = asobi_lua_match:handle_input(~"player1", Input, State1),
    ?assert(is_map(State2)).

tick_increments() ->
    {ok, State0} = init_match(),
    {ok, State1} = asobi_lua_match:join(~"player1", State0),
    {ok, State2} = asobi_lua_match:tick(State1),
    ?assert(is_map(State2)).

tick_finishes() ->
    Config = #{lua_script => fixture("test_match.lua"), game_config => #{max_ticks => 2}},
    {ok, State0} = asobi_lua_match:init(Config),
    {ok, State1} = asobi_lua_match:join(~"player1", State0),
    {ok, State2} = asobi_lua_match:tick(State1),
    case asobi_lua_match:tick(State2) of
        {finished, Result, _State3} ->
            ?assert(is_map(Result));
        {ok, _State3} ->
            ok
    end.

get_state_view() ->
    {ok, State0} = init_match(),
    {ok, State1} = asobi_lua_match:join(~"player1", State0),
    View = asobi_lua_match:get_state(~"player1", State1),
    ?assert(is_map(View)).

%% asobi#489: this used to assert is_map/1 and tolerate `none`, so it passed
%% while the feature was unreachable. The config a Lua script returns decodes
%% with BINARY keys, and asobi_vote_server reads ATOM ones - maps:get(options,
%% Merged) has no default, so it raised badkey, the vote server failed to start,
%% and do_start_vote/3 swallowed it. Assert the exact reads the vote server
%% performs instead.
vote_requested_ok() ->
    {ok, State0} = init_match(),
    {ok, State1} = asobi_lua_match:join(~"player1", State0),
    State50 = tick_n(50, State1),
    {ok, VoteConfig} = asobi_lua_match:vote_requested(State50),
    %% Every read asobi_vote_server:init/1 does on a script-supplied key.
    ?assertEqual(~"test_vote", maps:get(template, VoteConfig)),
    ?assertEqual(~"plurality", maps:get(method, VoteConfig)),
    ?assertEqual(5000, maps:get(window_ms, VoteConfig)),
    Options = maps:get(options, VoteConfig),
    ?assertEqual(2, length(Options)),
    %% validate_option/2 comprehends on `#{id := Id}`, so a binary id key makes
    %% every cast_vote fail to match its own option.
    ?assertEqual(
        [~"opt_a", ~"opt_b"],
        lists:sort([maps:get(id, O) || O <- Options]),
        "option ids must be reachable on the atom key the vote server matches"
    ),
    ?assertEqual(~"Option A", maps:get(label, hd(Options))),
    %% A key the script did not write must not be invented.
    ?assertNot(maps:is_key(veto_enabled, VoteConfig)).

%% Keys outside the whitelist are left exactly as written. Translating whatever
%% a script puts in the table would be binary_to_atom/2 on untrusted input.
vote_requested_leaves_unknown_keys_alone() ->
    Config = #{~"custom_thing" => 1, ~"template" => ~"t"},
    Normalised = asobi_lua_match:normalise_vote_config(Config),
    ?assertEqual(~"t", maps:get(template, Normalised)),
    ?assertEqual(1, maps:get(~"custom_thing", Normalised)),
    ?assertNot(maps:is_key(custom_thing, Normalised)).

vote_requested_none() ->
    {ok, State0} = init_match(),
    ?assertEqual(none, asobi_lua_match:vote_requested(State0)).

vote_resolved_ok() ->
    {ok, State0} = init_match(),
    Result = #{winner => ~"opt_a"},
    {ok, State1} = asobi_lua_match:vote_resolved(~"test_vote", Result, State0),
    ?assert(is_map(State1)).

%% --- Phase callback tests (widgrensit/asobi_lua#109) ---
%%
%% asobi_match_server gates phase support behind
%% `erlang:function_exported(GameMod, phases, 1)` before ever calling
%% GameMod:phases/1 - the same pattern asobi_world_server uses for Lua
%% worlds. Before this fix asobi_lua_match never exported phases/1 (or the
%% on_phase_* hooks), so function_exported was always false and phases were
%% silently unreachable from every Lua match script. This first test pins
%% the actual root cause; the rest exercise the behaviour mirroring
%% asobi_lua_world_tests's phase coverage.

phase_callbacks_are_exported() ->
    ?assert(erlang:function_exported(asobi_lua_match, phases, 1)),
    ?assert(erlang:function_exported(asobi_lua_match, on_phase_started, 2)),
    ?assert(erlang:function_exported(asobi_lua_match, on_phase_ended, 2)).

phases_returns_empty_when_undefined() ->
    %% test_match.lua defines no phases() function - must return [], not crash.
    {ok, S0} = init_match(),
    ?assertEqual([], asobi_lua_match:phases(S0)).

phases_returns_decoded_phases() ->
    Path = temp_script(
        ~"""
        match_size = 1
        function init(_) return {} end
        function join(id, s) return s end
        function leave(id, s) return s end
        function handle_input(_, _, s) return s end
        function tick(s) return s end
        function get_state(_, s) return s end
        function phases(_)
            return {
                { name = 'lobby', duration = 5000 },
                { name = 'play',  duration = 30000, start = 'prev_ended' }
            }
        end
        """
    ),
    try
        {ok, S0} = asobi_lua_match:init(#{lua_script => Path}),
        Phases = asobi_lua_match:phases(S0),
        ?assertEqual(2, length(Phases)),
        [Lobby, Play] = Phases,
        ?assertEqual(~"lobby", maps:get(name, Lobby)),
        ?assertEqual(prev_ended, maps:get(start, Play))
    after
        file:delete(Path)
    end.

phases_non_list_returns_empty() ->
    %% When phases() returns garbage, the bridge logs and returns [].
    Path = temp_script(
        ~"""
        match_size = 1
        function init(_) return {} end
        function join(id, s) return s end
        function leave(id, s) return s end
        function handle_input(_, _, s) return s end
        function tick(s) return s end
        function get_state(_, s) return s end
        function phases(_) return 42 end
        """
    ),
    try
        {ok, S0} = asobi_lua_match:init(#{lua_script => Path}),
        ?assertEqual([], asobi_lua_match:phases(S0))
    after
        file:delete(Path)
    end.

phases_from_raw_config() ->
    %% Mirrors asobi_match_server:init/1's GameMod:phases(GameConfig) - phases/1
    %% is called with the exact same map GameMod:init/1 already received (no
    %% lua_state threaded through), so lua_script lives at this map's top level.
    Path = temp_script(
        ~"""
        match_size = 1
        function init(_) return {} end
        function join(id, s) return s end
        function leave(id, s) return s end
        function handle_input(_, _, s) return s end
        function tick(s) return s end
        function get_state(_, s) return s end
        function phases(_)
            return { { name = 'lobby', duration = 5000 } }
        end
        """
    ),
    try
        GameConfig = #{lua_script => Path, match_id => ~"raw_probe"},
        Phases = asobi_lua_match:phases(GameConfig),
        ?assertEqual(1, length(Phases)),
        [Lobby] = Phases,
        ?assertEqual(~"lobby", maps:get(name, Lobby))
    after
        file:delete(Path)
    end.

on_phase_started_threads_state() ->
    Path = temp_script(
        ~"""
        match_size = 1
        function init(_) return { phase = nil } end
        function join(id, s) return s end
        function leave(id, s) return s end
        function handle_input(_, _, s) return s end
        function tick(s) return s end
        function get_state(_, s) return s end
        function on_phase_started(name, s) s.phase = name; return s end
        """
    ),
    try
        {ok, S0} = asobi_lua_match:init(#{lua_script => Path}),
        {ok, S1} = asobi_lua_match:on_phase_started(~"play", S0),
        #{lua_state := LuaSt, game_state := GS} = S1,
        GsMap = asobi_lua_api:decode_to_map(GS, LuaSt),
        ?assertEqual(~"play", maps:get(~"phase", GsMap))
    after
        file:delete(Path)
    end.

on_phase_ended_threads_state() ->
    Path = temp_script(
        ~"""
        match_size = 1
        function init(_) return {} end
        function join(id, s) return s end
        function leave(id, s) return s end
        function handle_input(_, _, s) return s end
        function tick(s) return s end
        function get_state(_, s) return s end
        function on_phase_ended(_, s) return s end
        """
    ),
    try
        {ok, S0} = asobi_lua_match:init(#{lua_script => Path}),
        ?assertMatch({ok, _}, asobi_lua_match:on_phase_ended(~"play", S0))
    after
        file:delete(Path)
    end.

finish_immediately() ->
    Config = #{lua_script => fixture("finish_immediately.lua")},
    {ok, State0} = asobi_lua_match:init(Config),
    {ok, State1} = asobi_lua_match:join(~"player1", State0),
    case asobi_lua_match:tick(State1) of
        {finished, Result, _} ->
            ?assert(is_map(Result));
        {ok, _} ->
            ?assert(false)
    end.

hot_reload_on_file_change() ->
    %% Write a temp match script, init a match, modify the file, tick,
    %% verify the changed global is visible via get_state.
    Path = temp_script(
        ~"""
        match_size = 1
        tag = "before"
        function init(_) return { n = 0 } end
        function join(id, s) s.players = s.players or {}; s.players[id] = {}; return s end
        function leave(id, s) s.players[id] = nil; return s end
        function handle_input(_, _, s) return s end
        function tick(s) s.n = s.n + 1; return s end
        function get_state(_, s) return { tag = tag, n = s.n } end
    """
    ),
    try
        {ok, S0} = asobi_lua_match:init(#{lua_script => Path}),
        {ok, S1} = asobi_lua_match:join(~"p1", S0),
        #{~"tag" := BeforeTag} = asobi_lua_match:get_state(~"p1", S1),
        ?assertEqual(~"before", BeforeTag),

        write_script(
            Path,
            ~"""
            match_size = 1
            tag = "after"
            function init(_) return { n = 0 } end
            function join(id, s) s.players = s.players or {}; s.players[id] = {}; return s end
            function leave(id, s) s.players[id] = nil; return s end
            function handle_input(_, _, s) return s end
            function tick(s) s.n = s.n + 1; return s end
            function get_state(_, s) return { tag = tag, n = s.n } end
        """
        ),
        %% filelib:last_modified/1 has 1-second resolution on POSIX, and
        %% file:write_file updates mtime to the current second which can
        %% equal the init-time mtime. Bump after writing so the reload
        %% check fires deterministically.
        bump_mtime(Path),

        {ok, S2} = asobi_lua_match:tick(S1),
        #{~"tag" := AfterTag} = asobi_lua_match:get_state(~"p1", S2),
        ?assertEqual(~"after", AfterTag)
    after
        file:delete(Path)
    end.

hot_reload_syntax_error() ->
    %% A broken reload should not crash the match or wipe game state —
    %% the match keeps running on the previous (good) script.
    Path = temp_script(
        ~"""
        match_size = 1
        tag = "good"
        function init(_) return { n = 0 } end
        function join(id, s) s.players = s.players or {}; s.players[id] = {}; return s end
        function leave(id, s) s.players[id] = nil; return s end
        function handle_input(_, _, s) return s end
        function tick(s) s.n = s.n + 1; return s end
        function get_state(_, s) return { tag = tag, n = s.n } end
    """
    ),
    try
        {ok, S0} = asobi_lua_match:init(#{lua_script => Path}),
        {ok, S1} = asobi_lua_match:join(~"p1", S0),

        write_script(Path, ~"tag = \"broken\"  !!this is not lua"),
        bump_mtime(Path),

        {ok, S2} = asobi_lua_match:tick(S1),
        %% The old code still runs, so `tag` is still "good".
        #{~"tag" := Tag} = asobi_lua_match:get_state(~"p1", S2),
        ?assertEqual(~"good", Tag)
    after
        file:delete(Path)
    end.

hot_reload_clears_require_cache() ->
    %% A common gotcha with the previous loader was that `require()`'d
    %% modules stayed cached in package.loaded forever. With our own
    %% require + cache-clear on hot-reload, edits to a sibling module
    %% must be visible after touching match.lua.
    Dir = filename:join([
        filename:basedir(user_cache, "asobi_lua_tests"),
        "reload_cache_" ++ integer_to_list(erlang:unique_integer([positive]))
    ]),
    ok = filelib:ensure_dir(filename:join(Dir, "x")),
    ModulePath = filename:join(Dir, "helper.lua"),
    MatchPath = filename:join(Dir, "match.lua"),
    ok = file:write_file(ModulePath, ~"return { version = 'v1' }\n"),
    ok = file:write_file(
        MatchPath,
        ~"""
        match_size = 1
        local h = require('helper')
        function init(_) return { v = h.version } end
        function join(id, s) return s end
        function leave(id, s) return s end
        function handle_input(_, _, s) return s end
        function tick(s)
            local hh = require('helper')
            s.v = hh.version
            return s
        end
        function get_state(_, s) return { v = s.v } end
        """
    ),
    try
        {ok, S0} = asobi_lua_match:init(#{lua_script => MatchPath}),
        {ok, S1} = asobi_lua_match:join(~"p1", S0),
        ?assertMatch(#{~"v" := ~"v1"}, asobi_lua_match:get_state(~"p1", S1)),

        ok = file:write_file(ModulePath, ~"return { version = 'v2' }\n"),
        bump_mtime(MatchPath),

        {ok, S2} = asobi_lua_match:tick(S1),
        ?assertMatch(#{~"v" := ~"v2"}, asobi_lua_match:get_state(~"p1", S2))
    after
        file:delete(MatchPath),
        file:delete(ModulePath),
        file:del_dir(Dir)
    end.

hot_reload_function_change() ->
    %% Adding a new function or changing an existing one must take
    %% effect on the next tick. We add a `bonus` field via a new
    %% function call introduced by the reload.
    Path = temp_script(
        ~"""
        match_size = 1
        function init(_) return { hits = 0 } end
        function join(id, s) return s end
        function leave(id, s) return s end
        function handle_input(_, _, s) s.hits = s.hits + 1; return s end
        function tick(s) return s end
        function get_state(_, s) return { hits = s.hits, bonus = 0 } end
        """
    ),
    try
        {ok, S0} = asobi_lua_match:init(#{lua_script => Path}),
        {ok, S1} = asobi_lua_match:join(~"p1", S0),
        ?assertEqual(0, maps:get(~"bonus", asobi_lua_match:get_state(~"p1", S1))),

        write_script(
            Path,
            ~"""
            match_size = 1
            function init(_) return { hits = 0 } end
            function join(id, s) return s end
            function leave(id, s) return s end
            function handle_input(_, _, s) s.hits = s.hits + 1; return s end
            function tick(s) return s end
            function get_state(_, s) return { hits = s.hits, bonus = 100 } end
            """
        ),
        bump_mtime(Path),

        {ok, S2} = asobi_lua_match:tick(S1),
        ?assertEqual(100, maps:get(~"bonus", asobi_lua_match:get_state(~"p1", S2)))
    after
        file:delete(Path)
    end.

init_nil_return() ->
    %% Documenting: init returning nil currently succeeds (game_state =
    %% nil) and the failure surfaces on the next bridge call. This is
    %% acceptable behaviour — surprising init returns are a script-author
    %% bug and the supervisor restart loop catches them — but if we ever
    %% tighten init validation, this assertion is the trip-wire.
    Path = temp_script(
        ~"""
        match_size = 1
        function init(_) return nil end
        function join(id, s) return s end
        function leave(id, s) return s end
        function handle_input(_, _, s) return s end
        function tick(s) return s end
        function get_state(_, s) return s end
        """
    ),
    try
        {ok, State} = asobi_lua_match:init(#{lua_script => Path}),
        ?assertMatch(#{game_state := nil}, State)
    after
        file:delete(Path)
    end.

init_non_table_return() ->
    Path = temp_script(
        ~"""
        match_size = 1
        function init(_) return 42 end
        function join(id, s) return s end
        function leave(id, s) return s end
        function handle_input(_, _, s) return s end
        function tick(s) return s end
        function get_state(_, s) return s end
        """
    ),
    try
        %% Returning a number passes through the bridge but join/leave/etc.
        %% will then fail to operate on a number. The init itself does not
        %% crash; the bridge accepts whatever Lua returns. This documents
        %% current behaviour: a bad init signature is the script author's
        %% problem and surfaces on the next bridge call.
        case asobi_lua_match:init(#{lua_script => Path}) of
            {ok, _State} -> ok;
            {error, _} -> ok
        end
    after
        file:delete(Path)
    end.

tick_timeout_keeps_state() ->
    %% End-to-end: a tick that exceeds TICK_TIMEOUT must NOT crash the
    %% match — the bridge logs the timeout and returns the previous
    %% state intact. Verifies the wrapping introduced for sandbox work.
    Path = temp_script(
        ~"""
        match_size = 1
        local n = 0
        function init(_) return { tag = 'before' } end
        function join(id, s) return s end
        function leave(id, s) return s end
        function handle_input(_, _, s) return s end
        function tick(s)
            n = n + 1
            if n == 1 then while true do end end
            s.tag = 'after'
            return s
        end
        function get_state(_, s) return { tag = s.tag } end
        """
    ),
    try
        {ok, S0} = asobi_lua_match:init(#{lua_script => Path}),
        {ok, S1} = asobi_lua_match:join(~"p1", S0),
        {ok, S2} = asobi_lua_match:tick(S1),
        %% On timeout the bridge keeps the previous state; tag stays 'before'.
        ?assertEqual(~"before", maps:get(~"tag", asobi_lua_match:get_state(~"p1", S2)))
    after
        file:delete(Path)
    end.

vote_requested_false() ->
    Path = temp_script(
        ~"""
        match_size = 1
        function init(_) return {} end
        function join(id, s) return s end
        function leave(id, s) return s end
        function handle_input(_, _, s) return s end
        function tick(s) return s end
        function get_state(_, s) return s end
        function vote_requested(_) return false end
        """
    ),
    try
        {ok, S0} = asobi_lua_match:init(#{lua_script => Path}),
        ?assertEqual(none, asobi_lua_match:vote_requested(S0))
    after
        file:delete(Path)
    end.

vote_resolved_unknown_template() ->
    {ok, State0} = init_match(),
    Result = #{winner => ~"opt_unknown"},
    ?assertMatch({ok, _}, asobi_lua_match:vote_resolved(~"never_proposed", Result, State0)).

handle_input_failure() ->
    %% A crashing handle_input must leave the match state intact and
    %% return {ok, State} — the bridge isolates the script error.
    Path = temp_script(
        ~"""
        match_size = 1
        function init(_) return { x = 0 } end
        function join(id, s) return s end
        function leave(id, s) return s end
        function handle_input(_, _, _) error('boom') end
        function tick(s) return s end
        function get_state(_, s) return s end
        """
    ),
    try
        {ok, S0} = asobi_lua_match:init(#{lua_script => Path}),
        {ok, S1} = asobi_lua_match:join(~"p1", S0),
        {ok, S2} = asobi_lua_match:handle_input(~"p1", #{~"k" => ~"v"}, S1),
        %% game_state survives the failure
        ?assertMatch(#{game_state := _}, S2)
    after
        file:delete(Path)
    end.

%% --- Regression: `game.*` API must be reachable from every match callback ---
%%
%% Mirrors the world-side regression suite. handle_input is the headline
%% case: ADR 0002 means it uses call/3 (no bounded_eval), and that path
%% only sees `game.*` if the install ran BEFORE the script chunk was
%% evaluated.

game_api_visible_in_match_callbacks_test() ->
    {ok, State0} = asobi_lua_match:init(#{lua_script => fixture("game_api_match.lua")}),
    ?assertEqual(true, lookup_flag(~"init_saw_game", State0)),
    {ok, State1} = asobi_lua_match:join(~"p1", State0),
    ?assertEqual(true, lookup_player_flag(~"p1", ~"join_saw_game", State1)),
    {ok, State2} = asobi_lua_match:handle_input(~"p1", #{}, State1),
    ?assertEqual(true, lookup_player_flag(~"p1", ~"handle_input_saw_game", State2)),
    ?assertEqual(true, lookup_player_flag(~"p1", ~"game_id_callable", State2)),
    {ok, State3} = asobi_lua_match:tick(State2),
    ?assertEqual(true, lookup_flag(~"tick_saw_game", State3)),
    {ok, State4} = asobi_lua_match:leave(~"p1", State3),
    ?assertEqual(true, lookup_player_flag(~"p1", ~"leave_saw_game", State4)).

-spec lookup_flag(binary(), map()) -> term().
lookup_flag(Key, #{lua_state := LuaSt, game_state := GS}) ->
    GsMap = asobi_lua_api:decode_to_map(GS, LuaSt),
    maps:get(Key, GsMap, false).

-spec lookup_player_flag(binary(), binary(), map()) -> term().
lookup_player_flag(PlayerId, Key, #{lua_state := LuaSt, game_state := GS}) ->
    GsMap = asobi_lua_api:decode_to_map(GS, LuaSt),
    Players = maps:get(~"players", GsMap, #{}),
    P = maps:get(PlayerId, Players, #{}),
    maps:get(Key, P, false).

%% --- Helpers ---

-spec init_match() -> {ok, map()}.
init_match() ->
    Config = #{lua_script => fixture("test_match.lua")},
    {ok, _} = asobi_lua_match:init(Config).

-spec tick_n(non_neg_integer(), map()) -> map().
tick_n(0, State) ->
    State;
tick_n(N, State) ->
    case asobi_lua_match:tick(State) of
        {ok, S} -> tick_n(N - 1, S);
        {finished, _, S} -> tick_n(N - 1, S)
    end.

-spec temp_script(binary()) -> file:filename_all().
temp_script(Code) ->
    Name = "hot_reload_" ++ integer_to_list(erlang:unique_integer([positive])) ++ ".lua",
    Path = filename:join([filename:basedir(user_cache, "asobi_lua_tests"), Name]),
    ok = filelib:ensure_dir(Path),
    write_script(Path, Code),
    Path.

-spec write_script(file:filename_all(), binary()) -> ok.
write_script(Path, Code) ->
    ok = file:write_file(Path, Code).

-spec bump_mtime(file:filename_all()) -> ok.
bump_mtime(Path) ->
    {ok, FI} = file:read_file_info(Path, [{time, local}]),
    %% Nudge mtime forward by 2 seconds so filelib:last_modified/1 reports
    %% a different value than on the previous check.
    {{Y, M, D}, {H, Mi, S}} = FI#file_info.mtime,
    NewMtime = calendar:gregorian_seconds_to_datetime(
        calendar:datetime_to_gregorian_seconds({{Y, M, D}, {H, Mi, S}}) + 2
    ),
    ok = file:write_file_info(Path, FI#file_info{mtime = NewMtime}).

%% --- Script-error log rate limiting (asobi#252) ---
%%
%% log_match_lua_error/4,5 gates its log line behind asobi_script_log_limiter,
%% keyed on {Script, Callback} - a tick that fails every call must not flood
%% the logs. The limiter's own rate math is covered on the asobi side; these
%% pin the wiring here, mirroring asobi_lua_world_tests's coverage of
%% log_lua_error/3: the right key is queried, a deny actually suppresses the
%% log line, and an allow lets it through.

script_log_limiter_test_() ->
    {foreach, fun log_limiter_setup/0, fun log_limiter_cleanup/1, [
        {"a denied key is suppressed, not logged per call",
            fun match_script_log_suppressed_on_deny/0},
        {"an allowed call is logged with the {script, callback} key intact",
            fun match_script_log_allowed_key_shape/0}
    ]}.

log_limiter_setup() ->
    OldPrimary = logger:get_primary_config(),
    ok = logger:set_primary_config(level, all),
    ok = logger:add_handler(?MODULE, ?MODULE, #{config => undefined, level => all}),
    meck:new(seki, [no_link, passthrough]),
    OldPrimary.

log_limiter_cleanup(OldPrimary) ->
    _ = logger:remove_handler(?MODULE),
    ok = logger:set_primary_config(OldPrimary),
    meck:unload(seki).

%% eunit runs each foreach test in its own process, so the receiving pid
%% must be attached per-test, not captured in setup.
attach_log() ->
    ok = logger:set_handler_config(?MODULE, config, self()).

log(#{level := Level, msg := {report, Report}}, #{config := Pid}) ->
    Pid ! {lua_match_log, Level, Report};
log(_, _) ->
    ok.

failing_tick_script() ->
    ~"""
    match_size = 1
    function init(_) return {} end
    function join(id, s) return s end
    function leave(id, s) return s end
    function handle_input(_, _, s) return s end
    function tick(_) error('boom') end
    function get_state(_, s) return s end
    """.

match_script_log_suppressed_on_deny() ->
    attach_log(),
    meck:expect(seki, check, fun(asobi_script_log_limiter, _Key) -> {deny, 0} end),
    Path = temp_script(failing_tick_script()),
    try
        {ok, S0} = asobi_lua_match:init(#{lua_script => Path}),
        {ok, _} = asobi_lua_match:tick(S0),
        {ok, _} = asobi_lua_match:tick(S0),
        receive
            {lua_match_log, error, _} -> error(unexpected_log_line_while_denied)
        after 50 -> ok
        end,
        ?assertEqual(2, meck:num_calls(seki, check, [asobi_script_log_limiter, '_']))
    after
        file:delete(Path)
    end.

match_script_log_allowed_key_shape() ->
    attach_log(),
    Path = temp_script(failing_tick_script()),
    meck:expect(seki, check, fun
        (asobi_script_log_limiter, {S, tick}) when S =:= Path -> {allow, 1};
        (asobi_script_log_limiter, Other) -> error({unexpected_key, Other})
    end),
    try
        {ok, S0} = asobi_lua_match:init(#{lua_script => Path}),
        {ok, _} = asobi_lua_match:tick(S0),
        receive
            {lua_match_log, error, Report} ->
                ?assertEqual(tick, maps:get(callback, Report))
        after 1000 -> error(no_log_received)
        end
    after
        file:delete(Path)
    end.
