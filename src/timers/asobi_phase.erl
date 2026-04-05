-module(asobi_phase).

%% Phase engine for match and world servers.
%%
%% A phase list describes the lifecycle of a game session. Each phase
%% has a duration, optional start conditions, and optional timers that
%% are active during that phase. The engine is pure functional — the
%% owning server calls `tick/2` each game tick.

-export([init/1, tick/2]).
-export([notify/2, pause/1, resume/1]).
-export([current/1, remaining/1, config/1, timers_info/1, info/1]).

-export_type([phase_state/0, phase_def/0, phase_event/0]).

-type phase_start() ::
    prev_ended
    | {players, pos_integer()}
    | {players_ratio, float()}
    | all_ready
    | {event, atom()}
    | {timer, pos_integer()}.

-type phase_def() :: #{
    name := binary(),
    start => phase_start(),
    duration => pos_integer() | infinity,
    end_condition => fun((term()) -> boolean()),
    timers => [map()],
    config => map()
}.

-type phase_event() ::
    {phase_started, binary()}
    | {phase_ended, binary()}
    | {all_phases_complete}
    | asobi_timer:timer_event().

-opaque phase_state() :: #{
    phases := [phase_def()],
    current_index := non_neg_integer(),
    current_started := boolean(),
    wait_elapsed := non_neg_integer(),
    active_timers := #{binary() => asobi_timer:timer()},
    paused := boolean(),
    complete := boolean()
}.

%% -------------------------------------------------------------------
%% Init
%% -------------------------------------------------------------------

-spec init([phase_def()]) -> phase_state().
init([]) ->
    #{
        phases => [],
        current_index => 0,
        current_started => true,
        wait_elapsed => 0,
        active_timers => #{},
        paused => false,
        complete => true
    };
init(Phases) ->
    State = #{
        phases => Phases,
        current_index => 0,
        current_started => false,
        wait_elapsed => 0,
        active_timers => #{},
        paused => false,
        complete => false
    },
    Phase = lists:nth(1, Phases),
    case maps:get(start, Phase, prev_ended) of
        prev_ended ->
            %% Auto-start first phase immediately
            {_Events, PS} = start_current_phase(State),
            PS;
        _ ->
            State
    end.

%% -------------------------------------------------------------------
%% Tick — advance by DeltaMs, return {Events, PhaseState1}
%% -------------------------------------------------------------------

-spec tick(pos_integer(), phase_state()) -> {[phase_event()], phase_state()}.
tick(_DeltaMs, #{complete := true} = PS) ->
    {[], PS};
tick(_DeltaMs, #{paused := true} = PS) ->
    {[], PS};
tick(DeltaMs, #{current_started := false} = PS) ->
    tick_waiting(DeltaMs, PS);
tick(DeltaMs, PS) ->
    tick_active(DeltaMs, PS).

%% -------------------------------------------------------------------
%% Notify — feed events for conditional phase/timer starts
%% -------------------------------------------------------------------

-spec notify(term(), phase_state()) -> {[phase_event()], phase_state()}.
notify(_Event, #{complete := true} = PS) ->
    {[], PS};
notify({player_joined, Count}, #{current_started := false} = PS) ->
    Phase = current_phase_def(PS),
    case maps:get(start, Phase, prev_ended) of
        {players, N} when Count >= N ->
            start_current_phase(PS);
        {players_ratio, Ratio} when Count >= Ratio ->
            start_current_phase(PS);
        _ ->
            {[], PS}
    end;
notify({all_ready}, #{current_started := false} = PS) ->
    Phase = current_phase_def(PS),
    case maps:get(start, Phase, prev_ended) of
        all_ready -> start_current_phase(PS);
        _ -> {[], PS}
    end;
notify({event, Name}, #{current_started := false} = PS) ->
    Phase = current_phase_def(PS),
    case maps:get(start, Phase, prev_ended) of
        {event, Name} -> start_current_phase(PS);
        _ -> {[], PS}
    end;
notify(Event, #{active_timers := Timers} = PS) ->
    {AllEvents, Timers1} = maps:fold(
        fun(TId, T, {Evts, Acc}) ->
            {TEvts, T1} = asobi_timer:notify(Event, undefined, T),
            {TEvts ++ Evts, Acc#{TId => T1}}
        end,
        {[], #{}},
        Timers
    ),
    {AllEvents, PS#{active_timers => Timers1}}.

%% -------------------------------------------------------------------
%% Pause / Resume
%% -------------------------------------------------------------------

-spec pause(phase_state()) -> phase_state().
pause(#{active_timers := Timers} = PS) ->
    Timers1 = maps:map(fun(_Id, T) -> asobi_timer:pause(T) end, Timers),
    PS#{paused => true, active_timers => Timers1}.

-spec resume(phase_state()) -> phase_state().
resume(#{active_timers := Timers} = PS) ->
    Timers1 = maps:map(fun(_Id, T) -> asobi_timer:resume(T) end, Timers),
    PS#{paused => false, active_timers => Timers1}.

%% -------------------------------------------------------------------
%% Queries
%% -------------------------------------------------------------------

-spec current(phase_state()) -> binary() | undefined.
current(#{complete := true}) ->
    undefined;
current(PS) ->
    Phase = current_phase_def(PS),
    maps:get(name, Phase).

-spec remaining(phase_state()) -> pos_integer() | infinity.
remaining(#{complete := true}) ->
    0;
remaining(#{current_started := false}) ->
    infinity;
remaining(PS) ->
    Phase = current_phase_def(PS),
    case maps:get(duration, Phase, infinity) of
        infinity -> infinity;
        _Duration -> maps:get(phase_remaining, PS, infinity)
    end.

-spec config(phase_state()) -> map().
config(#{complete := true}) ->
    #{};
config(PS) ->
    Phase = current_phase_def(PS),
    maps:get(config, Phase, #{}).

-spec timers_info(phase_state()) -> #{binary() => map()}.
timers_info(#{active_timers := Timers}) ->
    maps:map(fun(_Id, T) -> asobi_timer:info(T) end, Timers).

-spec info(phase_state()) -> map().
info(#{complete := true}) ->
    #{status => complete, phase => undefined};
info(#{current_started := false} = PS) ->
    Phase = current_phase_def(PS),
    #{
        status => waiting,
        phase => maps:get(name, Phase),
        start_condition => maps:get(start, Phase, prev_ended)
    };
info(PS) ->
    Phase = current_phase_def(PS),
    #{
        status => active,
        phase => maps:get(name, Phase),
        remaining_ms => remaining(PS),
        config => maps:get(config, Phase, #{}),
        timers => timers_info(PS)
    }.

%% -------------------------------------------------------------------
%% Internal — waiting for phase start condition
%% -------------------------------------------------------------------

tick_waiting(DeltaMs, #{wait_elapsed := Elapsed} = PS) ->
    Phase = current_phase_def(PS),
    Elapsed1 = Elapsed + DeltaMs,
    case maps:get(start, Phase, prev_ended) of
        {timer, FallbackMs} when Elapsed1 >= FallbackMs ->
            start_current_phase(PS#{wait_elapsed => Elapsed1});
        _ ->
            {[], PS#{wait_elapsed => Elapsed1}}
    end.

%% -------------------------------------------------------------------
%% Internal — active phase ticking
%% -------------------------------------------------------------------

tick_active(DeltaMs, PS) ->
    %% Tick all active timers
    {TimerEvents, PS1} = tick_timers(DeltaMs, PS),

    %% Check phase duration
    Phase = current_phase_def(PS1),
    case maps:get(duration, Phase, infinity) of
        infinity ->
            {TimerEvents, PS1};
        _Duration ->
            Rem = maps:get(phase_remaining, PS1),
            Rem1 = Rem - DeltaMs,
            case Rem1 =< 0 of
                true ->
                    {TransEvents, PS2} = advance_phase(PS1#{phase_remaining => 0}),
                    {TimerEvents ++ TransEvents, PS2};
                false ->
                    {TimerEvents, PS1#{phase_remaining => Rem1}}
            end
    end.

tick_timers(DeltaMs, #{active_timers := Timers} = PS) ->
    {AllEvents, Timers1} = maps:fold(
        fun(TId, T, {Evts, Acc}) ->
            {TEvts, T1} = asobi_timer:tick(DeltaMs, T),
            {TEvts ++ Evts, Acc#{TId => T1}}
        end,
        {[], #{}},
        Timers
    ),
    {AllEvents, PS#{active_timers => Timers1}}.

%% -------------------------------------------------------------------
%% Internal — phase transitions
%% -------------------------------------------------------------------

start_current_phase(PS) ->
    Phase = current_phase_def(PS),
    PhaseName = maps:get(name, Phase),
    Duration = maps:get(duration, Phase, infinity),
    PhaseTimers = build_timers(maps:get(timers, Phase, [])),
    PS1 = PS#{
        current_started => true,
        wait_elapsed => 0,
        active_timers => PhaseTimers,
        phase_remaining => Duration
    },
    {[{phase_started, PhaseName}], PS1}.

advance_phase(PS) ->
    #{phases := Phases, current_index := Idx} = PS,
    Phase = current_phase_def(PS),
    PhaseName = maps:get(name, Phase),
    EndEvents = [{phase_ended, PhaseName}],

    NextIdx = Idx + 1,
    case NextIdx >= length(Phases) of
        true ->
            {EndEvents ++ [{all_phases_complete}], PS#{complete => true, active_timers => #{}}};
        false ->
            NextPhase = lists:nth(NextIdx + 1, Phases),
            PS1 = PS#{
                current_index => NextIdx,
                current_started => false,
                wait_elapsed => 0,
                active_timers => #{}
            },
            case maps:get(start, NextPhase, prev_ended) of
                prev_ended ->
                    {StartEvents, PS2} = start_current_phase(PS1),
                    {EndEvents ++ StartEvents, PS2};
                _ ->
                    {EndEvents, PS1}
            end
    end.

%% -------------------------------------------------------------------
%% Internal — helpers
%% -------------------------------------------------------------------

current_phase_def(#{phases := Phases, current_index := Idx}) ->
    lists:nth(Idx + 1, Phases).

build_timers(TimerConfigs) ->
    lists:foldl(
        fun(Config, Acc) ->
            Type = maps:get(type, Config),
            Id = maps:get(id, Config),
            Timer =
                case Type of
                    countdown -> asobi_timer:countdown(Config);
                    conditional -> asobi_timer:conditional(Config);
                    cycle -> asobi_timer:cycle(Config);
                    scheduled -> asobi_timer:scheduled(Config)
                end,
            Acc#{Id => Timer}
        end,
        #{},
        TimerConfigs
    ).
