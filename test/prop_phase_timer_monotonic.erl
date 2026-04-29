-module(prop_phase_timer_monotonic).
-include_lib("eunit/include/eunit.hrl").
-undef(LET).
-include_lib("proper/include/proper.hrl").

%% PropEr: a random list of `prev_ended` phases with random durations,
%% advanced by random tick deltas, satisfies these invariants:
%%
%%   - Each phase fires `phase_started` then `phase_ended` exactly once.
%%   - The fire order matches the declared phase order (no skipping ahead,
%%     no re-entering a previous phase).
%%   - After total elapsed >= sum(durations), `all_phases_complete` fires
%%     exactly once, after which `complete := true` and further ticks emit
%%     no new events.
%%
%% Catches regressions where a phase boundary is skipped under a coarse
%% tick delta or where a paused/notify path leaks events.

-define(NUMTESTS, list_to_integer(os:getenv("PROPER_NUMTESTS", "50"))).

phase_timer_monotonic_test_() ->
    {timeout, 60,
        ?_assert(
            proper:quickcheck(prop_phase_timer_monotonic(), [
                {numtests, ?NUMTESTS}, {to_file, user}
            ])
        )}.

%% --- Property ---

prop_phase_timer_monotonic() ->
    ?FORALL(
        {Phases, Ticks},
        {phases(), proper_types:list(tick_delta())},
        run_iteration(narrow_phases(Phases), narrow_ticks(Ticks))
    ).

phases() ->
    ?LET(N, proper_types:integer(1, 5), gen_phases(N)).

gen_phases(N) ->
    proper_types:vector(N, phase_def()).

phase_def() ->
    ?LET(
        {Name, Duration},
        {phase_name(), proper_types:integer(50, 500)},
        #{name => Name, duration => Duration, start => prev_ended}
    ).

phase_name() ->
    proper_types:elements([~"alpha", ~"beta", ~"gamma", ~"delta", ~"epsilon"]).

tick_delta() ->
    proper_types:integer(1, 200).

%% --- Runner ---

-spec run_iteration([map()], [pos_integer()]) -> boolean().
run_iteration(PhaseDefs, Ticks) ->
    Names = [maps:get(name, P) || P <- PhaseDefs],
    {InitEvents, State0} = asobi_phase:init(PhaseDefs),
    {Events, Final} = run_ticks(Ticks, InitEvents, State0),
    %% Drain any remaining phases regardless of the random budget so the
    %% property covers full lifecycles even when Ticks is short.
    {DrainEvents, _Done} = drain_phases(Final),
    AllEvents = Events ++ DrainEvents,
    check_invariants(Names, AllEvents).

-spec run_ticks([pos_integer()], [term()], asobi_phase:phase_state()) ->
    {[term()], asobi_phase:phase_state()}.
run_ticks([], Acc, State) ->
    {Acc, State};
run_ticks([D | Rest], Acc, State) ->
    {Es, State1} = asobi_phase:tick(D, State),
    run_ticks(Rest, Acc ++ Es, State1).

drain_phases(State) ->
    drain_phases(State, [], 200).

drain_phases(State, Acc, 0) ->
    {Acc, State};
drain_phases(State, Acc, Steps) ->
    case asobi_phase:info(State) of
        #{status := complete} ->
            {Acc, State};
        _ ->
            {Events, State1} = asobi_phase:tick(1000, State),
            drain_phases(State1, Acc ++ Events, Steps - 1)
    end.

check_invariants(Names, Events) ->
    PhaseEvents = [E || E <- Events, is_phase_event(E)],
    StartEnd = [E || E <- PhaseEvents, started_or_ended(E)],
    StartEndSeq = [normalize(E) || E <- StartEnd],
    %% Engine contract: each phase fires phase_started then phase_ended
    %% exactly once, in declared order.
    Expected = lists:flatmap(fun(N) -> [{started, N}, {ended, N}] end, Names),
    AllPhasesCompleteCount = length([1 || {all_phases_complete} <- PhaseEvents]),
    case {StartEndSeq =:= Expected, AllPhasesCompleteCount =:= 1} of
        {true, true} ->
            true;
        Other ->
            io:format(
                user,
                "~ninvariant violated: ~p~n  expected: ~p~n  got: ~p~n  complete: ~p~n",
                [Other, Expected, StartEndSeq, AllPhasesCompleteCount]
            ),
            false
    end.

is_phase_event({phase_started, _}) -> true;
is_phase_event({phase_ended, _}) -> true;
is_phase_event({all_phases_complete}) -> true;
is_phase_event(_) -> false.

started_or_ended({phase_started, _}) -> true;
started_or_ended({phase_ended, _}) -> true;
started_or_ended(_) -> false.

normalize({phase_started, N}) -> {started, N};
normalize({phase_ended, N}) -> {ended, N}.

-spec narrow_phases(term()) -> [map()].
narrow_phases(L) when is_list(L) -> [P || P <- L, is_map(P)].

-spec narrow_ticks(term()) -> [pos_integer()].
narrow_ticks(L) when is_list(L) -> [T || T <- L, is_integer(T), T > 0].
