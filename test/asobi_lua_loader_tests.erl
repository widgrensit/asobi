-module(asobi_lua_loader_tests).
-include_lib("eunit/include/eunit.hrl").

-spec fixture(string()) -> file:filename_all().
fixture(Name) ->
    {ok, LibDir} = safe_lib_dir(),
    filename:absname(
        filename:join([LibDir, "test", "fixtures", "lua", Name])
    ).

-spec safe_lib_dir() -> {ok, string()}.
safe_lib_dir() ->
    case code:lib_dir(asobi) of
        {error, bad_name} -> error(asobi_not_loaded);
        Dir -> {ok, Dir}
    end.

%% --- Loader tests ---

loader_test_() ->
    [
        {"loads valid script", fun loads_valid_script/0},
        {"returns error for missing file", fun missing_file_error/0},
        {"returns error for syntax error", fun syntax_error/0},
        {"call executes lua function", fun call_function/0},
        {"call with atom name", fun call_atom_name/0},
        {"call returns error for undefined function", fun call_undefined_function/0},
        {"require loads submodule", fun require_loads_submodule/0},
        {"call with timeout succeeds", fun call_with_timeout_ok/0},
        {"call with timeout returns error on slow script", fun call_with_timeout_slow/0},
        {"call with heap cap returns error on heap bomb", fun call_heap_bomb/0},
        {"max_heap_words honors application env override", fun max_heap_env_override/0},
        {"math.random works", fun math_random_works/0},
        {"math.random with range works", fun math_random_range/0},
        {"math.random negative range works", fun math_random_negative_range/0},
        {"math.random single-element range", fun math_random_single_element_range/0},
        {"math.sqrt works", fun math_sqrt_works/0},
        {"math.random no args returns float", fun math_random_no_args/0},
        {"new/3 PreInstall runs before script eval", fun new3_pre_install_before_script/0},
        {"new/2 backwards-compat (no PreInstall)", fun new2_no_pre_install/0},
        {"is_defined true for a real global function", fun is_defined_true_for_real_function/0},
        {"is_defined false for an absent global", fun is_defined_false_for_absent_global/0},
        {"is_defined true for a non-function global (checks nil, not callability)",
            fun is_defined_true_for_non_function_global/0}
    ].

%% --- #536: the eval's heap budget bounds the callback, not the state ---
%%
%% The state is copied into the eval worker by the spawn itself, so an
%% absolute `max_heap_size` set at spawn bounded the persistent Luerl state
%% instead of the callback's own allocation: a handler that allocated nothing
%% was killed once the state behind it was large enough, and killed again on
%% every tick until the collector next ran. The budget is now measured from
%% the worker's heap after the copy, so the same callback under the same
%% budget gets the same verdict whatever it was handed.

heap_budget_test_() ->
    {foreach, fun reset_heap_env/0, fun(_) -> reset_heap_env() end, [
        {"the verdict does not depend on the size of the state", fun verdict_ignores_state_size/0},
        {"a runaway callback is still killed", fun runaway_still_killed/0},
        {"the configured budget decides the verdict", fun budget_gates_the_verdict/0},
        {"the state size is measured for free", fun state_words_measured/0}
    ]}.

reset_heap_env() ->
    {ok, _} = application:ensure_all_started(telemetry),
    application:unset_env(asobi_lua, max_heap_words),
    application:unset_env(asobi, max_heap_words),
    ok.

verdict_ignores_state_size() ->
    application:set_env(asobi, max_heap_words, 2_000_000),
    Small = churn_state(500),
    Large = churn_state(60_000),
    ?assert(erts_debug:flat_size(Large) > 2_000_000),
    ?assertMatch({ok, _, _}, asobi_lua_loader:call(churn, [3_000], Small, 5_000)),
    ?assertMatch({ok, _, _}, asobi_lua_loader:call(churn, [3_000], Large, 5_000)).

runaway_still_killed() ->
    application:set_env(asobi, max_heap_words, 500_000),
    St = churn_state(500),
    ?assertEqual({error, heap_exhausted}, asobi_lua_loader:call(churn, [400_000], St, 30_000)).

%% One state, one callback, two budgets. Without this the runaway test above
%% passes just as happily against a cap a hundred times too wide - it pins
%% "eventually killed", not "killed near the number an operator configured".
budget_gates_the_verdict() ->
    St = churn_state(500),
    application:set_env(asobi, max_heap_words, 5_000_000),
    ?assertMatch({ok, _, _}, asobi_lua_loader:call(churn, [8_000], St, 30_000)),
    application:set_env(asobi, max_heap_words, 200_000),
    ?assertEqual({error, heap_exhausted}, asobi_lua_loader:call(churn, [8_000], St, 30_000)).

state_words_measured() ->
    Small = churn_state(500),
    Large = churn_state(60_000),
    {ok, _, _} = asobi_lua_loader:call(churn, [1], Small, 5_000),
    SmallWords = asobi_lua_loader:state_words(),
    {ok, _, _} = asobi_lua_loader:call(churn, [1], Large, 5_000),
    LargeWords = asobi_lua_loader:state_words(),
    ?assert(SmallWords > 0),
    ?assert(LargeWords > 10 * SmallWords),
    %% The worker's heap after the copy is the state, so the measurement
    %% tracks what walking the term would have cost to find out.
    ?assert(LargeWords >= erts_debug:flat_size(Large)).

churn_state(Rows) ->
    {ok, St} = asobi_lua_loader:new(fixture("gc_zone.lua")),
    {ok, [_ | _], St1} = asobi_lua_loader:call(big_state, [Rows], St),
    St1.

%% --- #426: the periodic Luerl collector ---
%%
%% Luerl never collects a long-lived state on its own, so every per-tick
%% `luerl:encode/2` accumulated in it forever and `call/4` copied the lot into
%% its eval worker twice per tick. These pin the three properties that make
%% collecting safe: it actually reclaims, the caller's `game_state` survives
%% it, and it stops collecting rather than freezing a zone whose live set is
%% too large for Luerl's quadratic mark.

collector_test_() ->
    {foreach, fun unset_gc_env/0, fun(_) -> unset_gc_env() end, [
        {"collecting reclaims the per-tick encode garbage", fun collect_reclaims/0},
        {"game_state survives a collection", fun game_state_survives/0},
        {"the anchor is invisible to the script", fun anchor_is_not_left_behind/0},
        {"a collected state keeps ticking", fun collected_state_keeps_ticking/0},
        {"the state reaches a steady size", fun steady_state_size/0},
        {"a state with no lua_state is untouched", fun no_lua_state_is_untouched/0},
        {"lua_gc=false disables the collector", fun env_disables_collector/0},
        {"the interval adapts to measured collection cost", fun interval_adapts_to_cost/0},
        {"an uncollectable live set abandons the collector", fun huge_live_set_abandons/0},
        {"the collection budget scales with the state", fun budget_scales_with_state/0},
        {"the back-off stays reachable at a huge state",
            fun backoff_stays_reachable_at_a_huge_state/0},
        {"the state size is reported", fun state_size_is_reported/0}
    ]}.

unset_gc_env() ->
    {ok, _} = application:ensure_all_started(telemetry),
    application:unset_env(asobi_lua, lua_gc),
    application:unset_env(asobi, lua_gc),
    ok.

collect_reclaims() ->
    S0 = gc_zone_state(),
    Ticked = tick_n(S0, 200),
    Uncollected = erts_debug:flat_size(maps:get(lua_state, Ticked)),
    Collected = erts_debug:flat_size(maps:get(lua_state, collect(Ticked))),
    ?assert(Collected * 4 < Uncollected).

%% The collector frees anything the Lua root set cannot reach. game_state is
%% held only by asobi between callbacks, so without the anchor this decode
%% crashes on a freed table - the failure mode that makes a naive `luerl:gc/1`
%% here worse than the leak.
game_state_survives() ->
    S = collect(tick_n(gc_zone_state(), 50)),
    #{lua_state := St, game_state := GS} = S,
    ?assertEqual([{~"n", 50}], luerl:decode(GS, St)).

anchor_is_not_left_behind() ->
    #{lua_state := St} = collect(tick_n(gc_zone_state(), 20)),
    ?assertMatch({ok, nil, _}, luerl:get_table_keys([~"__asobi_gc_anchor"], St)).

collected_state_keeps_ticking() ->
    S = tick_n(collect(tick_n(gc_zone_state(), 50)), 25),
    #{lua_state := St, game_state := GS} = S,
    ?assertEqual([{~"n", 75}], luerl:decode(GS, St)).

%% The point of the fix: size stops tracking total ticks taken. Without the
%% collector this grows without bound for as long as the zone is occupied.
steady_state_size() ->
    S1 = collect_every_tick(gc_zone_state(), 300),
    S2 = collect_every_tick(S1, 300),
    Size1 = erts_debug:flat_size(maps:get(lua_state, S1)),
    Size2 = erts_debug:flat_size(maps:get(lua_state, S2)),
    ?assert(Size2 < Size1 * 2).

no_lua_state_is_untouched() ->
    ?assertEqual(#{some => thing}, asobi_lua_loader:collect_state(#{some => thing})).

env_disables_collector() ->
    application:set_env(asobi, lua_gc, false),
    Ticked = tick_n(gc_zone_state(), 200),
    Before = erts_debug:flat_size(maps:get(lua_state, Ticked)),
    Collected = collect(Ticked),
    ?assertEqual(Before, erts_debug:flat_size(maps:get(lua_state, Collected))),
    ?assertMatch(#{lua_gc := #{enabled := false}}, Collected).

%% Luerl's mark phase is an ordsets list insert per live object, so collecting
%% a large persistent table is quadratic. Collecting one of those every
%% interval is worse than the leak, so the interval has to grow when a
%% collection turns out to be expensive. Driven directly rather than through a
%% live set sized to overrun the budget, which would make the assertion a bet
%% on how fast the machine running it is.
interval_adapts_to_cost() ->
    Gc = #{interval => 64, countdown => 0, enabled => true},
    B = 5_000,
    Doubled = asobi_lua_loader:next_gc(20_000, B, 64, Gc),
    ?assertMatch(#{interval := 128, countdown := 128, enabled := true}, Doubled),
    Halved = asobi_lua_loader:next_gc(100, B, 64, Gc),
    ?assertMatch(#{interval := 32, countdown := 32}, Halved),
    ?assertMatch(#{interval := 64}, asobi_lua_loader:next_gc(3_000, B, 64, Gc)),
    %% Both ends are clamped, so a cheap state does not collect every tick and
    %% an expensive one still collects eventually.
    ?assertMatch(
        #{interval := 8}, asobi_lua_loader:next_gc(1, B, 8, Gc#{interval => 8})
    ),
    ?assertMatch(
        #{interval := 1024},
        asobi_lua_loader:next_gc(20_000, B, 1024, Gc#{interval => 1024})
    ).

%% #536: the same 20ms collection is a backoff against a small state and a
%% bargain against a large one, because what it is really competing with is
%% call/4's copy of that state on every callback. A flat budget backed the
%% interval off hardest on the states that could least afford it.
budget_scales_with_state() ->
    ?assertEqual(5_000, asobi_lua_loader:gc_budget_us(undefined)),
    ?assertEqual(5_000, asobi_lua_loader:gc_budget_us(1_000)),
    Big = asobi_lua_loader:gc_budget_us(8_000_000),
    ?assert(Big > 5_000),
    Gc = #{interval => 64, countdown => 0, enabled => true},
    ?assertMatch(
        #{interval := 128},
        asobi_lua_loader:next_gc(20_000, asobi_lua_loader:gc_budget_us(1_000), 64, Gc)
    ),
    ?assertMatch(
        #{interval := 32},
        asobi_lua_loader:next_gc(20_000, Big, 64, Gc)
    ).

%% The scaled budget must stay below the abandon ceiling, because that clause
%% is tested first. A budget above it makes "this collection overran, back off"
%% unreachable: everything that would have tripped it abandons instead, and
%% everything that does not abandon looks cheap, so the interval falls to its
%% minimum on precisely the largest states. 500 MB is inside the range #536
%% reports, so that is where this is pinned.
backoff_stays_reachable_at_a_huge_state() ->
    Words = 62_500_000,
    Budget = asobi_lua_loader:gc_budget_us(Words),
    ?assert(Budget < 500_000),
    Gc = #{interval => 64, countdown => 0, enabled => true},
    %% Costs more than the budget but not enough to abandon: must back off.
    ?assertMatch(
        #{interval := 128, enabled := true},
        asobi_lua_loader:next_gc(Budget + 1, Budget, 64, Gc)
    ),
    %% And the abandon path is still the one that catches a real overrun.
    ?assertMatch(
        #{enabled := false},
        asobi_lua_loader:next_gc(600_000, Budget, 64, Gc)
    ).

%% Past the abandon ceiling a single collection costs more than the leak it
%% prevents, so the collector stops rather than freezing the zone for seconds
%% at a time. The state is left exactly as the collection found it.
huge_live_set_abandons() ->
    S = collect(big_state(20000)),
    ?assertMatch(#{lua_gc := #{enabled := false}}, S),
    ?assert(is_list(gs_world(S))).

%% #536: the size of the state is what decides what a Lua tick costs, and
%% before this there was no way to see it short of walking the term by hand in
%% a remote shell. It rides on collect_state/1 rather than on a collection,
%% because the collector's interval is adaptive and can be off entirely.
state_size_is_reported() ->
    Handler = {?MODULE, make_ref()},
    Self = self(),
    ok = telemetry:attach(
        Handler,
        [asobi, lua, state],
        fun(_E, Measurements, Meta, _) -> Self ! {sample, Measurements, Meta} end,
        undefined
    ),
    try
        S0 = gc_zone_state(),
        Bridge = #{kind => zone, world_id => ~"w1", coords => {2, 3}},
        S1 = tick_n(S0#{script => ~"gc_zone.lua", lua_bridge => Bridge}, 1),
        _ = asobi_lua_loader:collect_state(S1),
        receive
            {sample, #{words := Words, bytes := Bytes}, Meta} ->
                ?assert(Words > 0),
                ?assertEqual(Words * erlang:system_info(wordsize), Bytes),
                %% Without the bridge identity every zone in a world reports
                %% under one label set and the series is unusable.
                ?assertEqual(
                    #{
                        script => ~"gc_zone.lua",
                        kind => zone,
                        world_id => ~"w1",
                        coords => {2, 3}
                    },
                    Meta
                )
        after 1000 ->
            ?assert(false)
        end
    after
        telemetry:detach(Handler)
    end.

big_state(Rows) ->
    #{lua_state := St0} = S0 = gc_zone_state(),
    {ok, [Big | _], St1} = asobi_lua_loader:call(big_state, [Rows], St0),
    S0#{lua_state => St1, game_state => Big}.

%% Proves the anchor held: the persistent table is still reachable through the
%% ref asobi kept, whether the collection ran or was abandoned.
gs_world(#{lua_state := St, game_state := GS}) ->
    {ok, World, _} = luerl:get_table_key(GS, ~"world", St),
    luerl:decode(World, St).

gc_zone_state() ->
    {ok, St} = asobi_lua_loader:new(fixture("gc_zone.lua")),
    {ok, [GS | _], St1} = asobi_lua_loader:call(init, [nil], St),
    #{lua_state => St1, game_state => GS}.

%% Mirrors what asobi_lua_world:zone_tick/2 does per tick: encode the entity
%% map fresh (this is the garbage) and call into the script.
tick_n(State, 0) ->
    State;
tick_n(#{lua_state := St, game_state := GS} = State, N) ->
    {Enc, St1} = luerl:encode(entities(), St),
    {ok, [_Ents, GS1 | _], St2} = asobi_lua_loader:call(zone_tick, [Enc, GS], St1),
    tick_n(State#{lua_state => St2, game_state => GS1}, N - 1).

collect_every_tick(State, 0) ->
    State;
collect_every_tick(State, N) ->
    collect_every_tick(collect(tick_n(State, 1)), N - 1).

collect(State) ->
    asobi_lua_loader:collect_state(State#{
        lua_gc => #{interval => 1, countdown => 1, enabled => true}
    }).

entities() ->
    #{
        integer_to_binary(I) => #{~"x" => I, ~"y" => I, ~"type" => ~"npc", ~"hp" => 100}
     || I <- lists:seq(1, 20)
    }.

loads_valid_script() ->
    {ok, _St} = asobi_lua_loader:new(fixture("test_match.lua")).

missing_file_error() ->
    {error, {file_error, _, enoent}} = asobi_lua_loader:new(fixture("nonexistent.lua")).

syntax_error() ->
    {error, _} = asobi_lua_loader:new(fixture("bad_script.lua")).

call_function() ->
    {ok, St} = asobi_lua_loader:new(fixture("test_match.lua")),
    Cfg = encode_map(#{}, St),
    {ok, [State | _], _} = asobi_lua_loader:call(init, [Cfg], St),
    ?assert(is_map(State) orelse is_list(State) orelse is_tuple(State)).

call_atom_name() ->
    {ok, St} = asobi_lua_loader:new(fixture("test_match.lua")),
    Cfg = encode_map(#{}, St),
    {ok, [State | _], _} = asobi_lua_loader:call(init, [Cfg], St),
    ?assert(is_map(State) orelse is_list(State) orelse is_tuple(State)).

call_undefined_function() ->
    {ok, St} = asobi_lua_loader:new(fixture("test_match.lua")),
    {error, _} = asobi_lua_loader:call(nonexistent_function, [], St).

require_loads_submodule() ->
    {ok, St} = asobi_lua_loader:new(fixture("test_match.lua")),
    Cfg = encode_map(#{}, St),
    {ok, _, _} = asobi_lua_loader:call(init, [Cfg], St).

call_with_timeout_ok() ->
    {ok, St} = asobi_lua_loader:new(fixture("test_match.lua")),
    Cfg = encode_map(#{}, St),
    {ok, [_ | _], _} = asobi_lua_loader:call(init, [Cfg], St, 5000).

%% slow_tick.lua spins for 100M iterations, so it trips whichever bound comes
%% first on this machine: the 50ms deadline, or #348's CPU budget.
call_with_timeout_slow() ->
    {ok, St} = asobi_lua_loader:new(fixture("slow_tick.lua")),
    Cfg = encode_map(#{}, St),
    Result = asobi_lua_loader:call(tick, [Cfg], St, 50),
    true = lists:member(Result, [{error, timeout}, {error, reductions_exhausted}]).

%% A tick that allocates an unbounded table must be killed by the per-eval
%% heap cap and surface as `heap_exhausted`, not as a timeout. Use a
%% small heap budget so the eval trips quickly even on fast hardware.
call_heap_bomb() ->
    OldEnv = application:get_env(asobi_lua, max_heap_words),
    application:set_env(asobi_lua, max_heap_words, 200_000),
    try
        {ok, St} = asobi_lua_loader:new(fixture("heap_bomb.lua")),
        Cfg = encode_map(#{}, St),
        ?assertEqual(
            {error, heap_exhausted},
            asobi_lua_loader:call(tick, [Cfg], St, 5000)
        )
    after
        case OldEnv of
            {ok, V} -> application:set_env(asobi_lua, max_heap_words, V);
            undefined -> application:unset_env(asobi_lua, max_heap_words)
        end
    end.

%% A normal call still succeeds when an env override is set, proving the
%% override path is read on every eval rather than baked in once.
max_heap_env_override() ->
    OldEnv = application:get_env(asobi_lua, max_heap_words),
    application:set_env(asobi_lua, max_heap_words, 5_000_000),
    try
        {ok, St} = asobi_lua_loader:new(fixture("test_match.lua")),
        Cfg = encode_map(#{}, St),
        {ok, [_ | _], _} = asobi_lua_loader:call(init, [Cfg], St, 5000)
    after
        case OldEnv of
            {ok, V} -> application:set_env(asobi_lua, max_heap_words, V);
            undefined -> application:unset_env(asobi_lua, max_heap_words)
        end
    end.

math_random_works() ->
    {ok, St} = asobi_lua_loader:new(fixture("test_match.lua")),
    {ok, [Result | _], _} = asobi_lua_loader:call(
        [<<"math">>, <<"random">>], [10], St
    ),
    ?assert(is_number(Result)),
    ?assert(Result >= 1 andalso Result =< 10).

math_random_range() ->
    {ok, St} = asobi_lua_loader:new(fixture("test_match.lua")),
    lists:foreach(
        fun(_) ->
            {ok, [Result | _], _} = asobi_lua_loader:call(
                [<<"math">>, <<"random">>], [5, 10], St
            ),
            ?assert(Result >= 5 andalso Result =< 10)
        end,
        lists:seq(1, 50)
    ).

math_random_negative_range() ->
    {ok, St} = asobi_lua_loader:new(fixture("test_match.lua")),
    lists:foreach(
        fun(_) ->
            {ok, [Result | _], _} = asobi_lua_loader:call(
                [<<"math">>, <<"random">>], [-5, -1], St
            ),
            ?assert(Result >= -5 andalso Result =< -1)
        end,
        lists:seq(1, 50)
    ).

math_random_single_element_range() ->
    {ok, St} = asobi_lua_loader:new(fixture("test_match.lua")),
    {ok, [Result | _], _} = asobi_lua_loader:call(
        [<<"math">>, <<"random">>], [7, 7], St
    ),
    ?assertEqual(7, Result).

math_sqrt_works() ->
    {ok, St} = asobi_lua_loader:new(fixture("test_match.lua")),
    {ok, [Result | _], _} = asobi_lua_loader:call(
        [<<"math">>, <<"sqrt">>], [16.0], St
    ),
    ?assertEqual(4.0, Result).

math_random_no_args() ->
    {ok, St} = asobi_lua_loader:new(fixture("test_match.lua")),
    {ok, [Result | _], _} = asobi_lua_loader:call(
        [<<"math">>, <<"random">>], [], St
    ),
    ?assert(is_float(Result)),
    ?assert(Result >= 0.0 andalso Result < 1.0).

new3_pre_install_before_script() ->
    %% Script defines a function that closes over a global the host injects
    %% via PreInstall. If PreInstall runs BEFORE script eval, the closure's
    %% `_ENV` captures the injected value and `probe()` returns it. If it
    %% ran AFTER (the bug fixed by this hook), `probe()` would see nil.
    %% This is the same property that makes `game.*` reachable from
    %% `handle_input` in the world bridge.
    PreInstall = fun(St) ->
        {Enc, St1} = luerl:encode(~"injected_value", St),
        {ok, St2} = luerl:set_table_keys([~"injected"], Enc, St1),
        St2
    end,
    {ok, St} = asobi_lua_loader:new(
        fixture("pre_install_probe.lua"), 2000, PreInstall
    ),
    {ok, [Value | _], _} = asobi_lua_loader:call(probe, [], St),
    ?assertEqual(~"injected_value", Value).

new2_no_pre_install() ->
    %% Without PreInstall, the same script's `probe()` should see nil for
    %% the missing global. Confirms the new/3 hook is opt-in.
    {ok, St} = asobi_lua_loader:new(fixture("pre_install_probe.lua"), 2000),
    {ok, [Value | _], _} = asobi_lua_loader:call(probe, [], St),
    ?assertEqual(nil, Value).

is_defined_true_for_real_function() ->
    {ok, St} = asobi_lua_loader:new(fixture("test_match.lua")),
    ?assert(asobi_lua_loader:is_defined(init, St)).

is_defined_false_for_absent_global() ->
    {ok, St} = asobi_lua_loader:new(fixture("test_match.lua")),
    ?assertNot(asobi_lua_loader:is_defined(nonexistent_function, St)).

is_defined_true_for_non_function_global() ->
    %% is_defined/2 only checks "does this global exist" (nil vs not),
    %% not "is it callable" - a script-level constant global is `nil` if
    %% and only if the script never set it. spawn_world.lua sets
    %% `match_size` as a plain number, which still reads as "defined".
    {ok, St} = asobi_lua_loader:new(fixture("spawn_world.lua")),
    ?assert(asobi_lua_loader:is_defined(match_size, St)),
    ?assertNot(asobi_lua_loader:is_defined(some_field_never_set, St)).

%% --- Helpers ---

-spec encode_map(map(), dynamic()) -> dynamic().
encode_map(Map, St) ->
    {Enc, _} = luerl:encode(Map, St),
    Enc.
