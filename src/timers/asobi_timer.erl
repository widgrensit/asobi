-module(asobi_timer).

%% Pure functional timer primitives.
%%
%% Timers don't own processes — they are state that the owning server
%% advances each tick by calling `tick/2`. This keeps timer logic
%% testable and avoids per-timer process overhead.

-export([countdown/1, conditional/1, cycle/1]).
-export([tick/2, notify/3, pause/1, resume/1]).
-export([is_expired/1, is_started/1, is_paused/1]).
-export([remaining/1, current_phase/1, info/1]).

-export_type([timer/0, timer_event/0]).

-opaque timer() :: #{
    type := countdown | conditional | cycle,
    id := binary(),
    _ => _
}.

-type timer_event() ::
    {timer_started, binary()}
    | {timer_warning, binary(), pos_integer()}
    | {timer_expired, binary()}
    | {phase_changed, binary(), binary()}.

%% -------------------------------------------------------------------
%% Constructors
%% -------------------------------------------------------------------

-spec countdown(map()) -> timer().
countdown(Config) ->
    Id = maps:get(id, Config),
    Duration = maps:get(duration, Config),
    Warnings = maps:get(warnings, Config, []),
    OnExpire = maps:get(on_expire, Config, timer_expired),
    PauseOnEmpty = maps:get(pause_on_empty, Config, false),
    #{
        type => countdown,
        id => Id,
        duration => Duration,
        remaining => Duration,
        warnings => lists:sort(fun erlang:'>='/2, Warnings),
        warnings_fired => [],
        on_expire => OnExpire,
        pause_on_empty => PauseOnEmpty,
        started_at => erlang:system_time(millisecond),
        paused => false,
        expired => false
    }.

-spec conditional(map()) -> timer().
conditional(Config) ->
    Id = maps:get(id, Config),
    Duration = maps:get(duration, Config),
    Fallback = maps:get(fallback_timeout, Config, infinity),
    Condition = maps:get(start_condition, Config),
    Warnings = maps:get(warnings, Config, []),
    OnExpire = maps:get(on_expire, Config, timer_expired),
    #{
        type => conditional,
        id => Id,
        duration => Duration,
        remaining => Duration,
        fallback_timeout => Fallback,
        fallback_elapsed => 0,
        start_condition => Condition,
        started => false,
        warnings => lists:sort(fun erlang:'>='/2, Warnings),
        warnings_fired => [],
        on_expire => OnExpire,
        paused => false,
        expired => false
    }.

-spec cycle(map()) -> timer().
cycle(Config) ->
    Id = maps:get(id, Config),
    Phases = maps:get(phases, Config),
    Repeat = maps:get(repeat, Config, true),
    StartIndex = maps:get(start_index, Config, 0),
    Phase = lists:nth(StartIndex + 1, Phases),
    PhaseDuration = maps:get(duration, Phase),
    #{
        type => cycle,
        id => Id,
        phases => Phases,
        repeat => Repeat,
        phase_index => StartIndex,
        phase_remaining => PhaseDuration,
        paused => false,
        expired => false
    }.

%% -------------------------------------------------------------------
%% Tick — advance timer by DeltaMs, return {Events, Timer1}
%% -------------------------------------------------------------------

-spec tick(pos_integer(), timer()) -> {[timer_event()], timer()}.
tick(_DeltaMs, #{paused := true} = Timer) ->
    {[], Timer};
tick(_DeltaMs, #{expired := true} = Timer) ->
    {[], Timer};
%% Countdown
tick(DeltaMs, #{type := countdown, id := Id, remaining := Rem} = Timer) ->
    Rem1 = Rem - DeltaMs,
    {WarningEvents, Timer1} = check_warnings(Id, Rem1, Timer),
    case Rem1 =< 0 of
        true ->
            Events = WarningEvents ++ [{timer_expired, Id}],
            {Events, Timer1#{remaining => 0, expired => true}};
        false ->
            {WarningEvents, Timer1#{remaining => Rem1}}
    end;
%% Conditional — not yet started, waiting for condition or fallback
tick(DeltaMs, #{type := conditional, started := false} = Timer) ->
    #{id := Id, fallback_timeout := Fallback, fallback_elapsed := Elapsed} = Timer,
    Elapsed1 = Elapsed + DeltaMs,
    case Fallback =/= infinity andalso Elapsed1 >= Fallback of
        true ->
            Timer1 = Timer#{
                started => true,
                fallback_elapsed => Elapsed1,
                started_at => erlang:system_time(millisecond)
            },
            {[{timer_started, Id}], Timer1};
        false ->
            {[], Timer#{fallback_elapsed => Elapsed1}}
    end;
%% Conditional — started, counting down
tick(DeltaMs, #{type := conditional, started := true, id := Id, remaining := Rem} = Timer) ->
    Rem1 = Rem - DeltaMs,
    {WarningEvents, Timer1} = check_warnings(Id, Rem1, Timer),
    case Rem1 =< 0 of
        true ->
            Events = WarningEvents ++ [{timer_expired, Id}],
            {Events, Timer1#{remaining => 0, expired => true}};
        false ->
            {WarningEvents, Timer1#{remaining => Rem1}}
    end;
%% Cycle
tick(DeltaMs, #{type := cycle} = Timer) ->
    tick_cycle(DeltaMs, Timer, []).

%% -------------------------------------------------------------------
%% Notify — feed events to conditional timers for condition checking
%% -------------------------------------------------------------------

-spec notify(atom(), term(), timer()) -> {[timer_event()], timer()}.
notify(_Event, _Data, #{type := Type} = Timer) when Type =/= conditional ->
    {[], Timer};
notify(_Event, _Data, #{started := true} = Timer) ->
    {[], Timer};
notify(Event, Data, #{id := Id, start_condition := Condition} = Timer) ->
    case check_condition(Event, Data, Condition) of
        true ->
            Timer1 = Timer#{started => true, started_at => erlang:system_time(millisecond)},
            {[{timer_started, Id}], Timer1};
        false ->
            {[], Timer}
    end.

%% -------------------------------------------------------------------
%% Pause / Resume
%% -------------------------------------------------------------------

-spec pause(timer()) -> timer().
pause(Timer) ->
    Timer#{paused => true}.

-spec resume(timer()) -> timer().
resume(Timer) ->
    Timer#{paused => false}.

%% -------------------------------------------------------------------
%% Queries
%% -------------------------------------------------------------------

-spec is_expired(timer()) -> boolean().
is_expired(#{expired := Expired}) -> Expired.

-spec is_started(timer()) -> boolean().
is_started(#{type := conditional, started := Started}) -> Started;
is_started(_Timer) -> true.

-spec is_paused(timer()) -> boolean().
is_paused(#{paused := Paused}) -> Paused.

-spec remaining(timer()) -> pos_integer() | infinity.
remaining(#{type := conditional, started := false}) -> infinity;
remaining(#{type := cycle, phase_remaining := Rem}) -> Rem;
remaining(#{remaining := Rem}) -> max(0, Rem).

-spec current_phase(timer()) -> binary() | undefined.
current_phase(#{type := cycle, phases := Phases, phase_index := Idx}) ->
    Phase = lists:nth(Idx + 1, Phases),
    maps:get(name, Phase);
current_phase(_) ->
    undefined.

-spec info(timer()) -> map().
info(#{type := countdown, id := Id, remaining := Rem, paused := Paused, expired := Expired}) ->
    #{
        type => countdown,
        id => Id,
        remaining_ms => max(0, Rem),
        paused => Paused,
        expired => Expired
    };
info(#{
    type := conditional,
    id := Id,
    started := Started,
    remaining := Rem,
    paused := Paused,
    expired := Expired
}) ->
    #{
        type => conditional,
        id => Id,
        started => Started,
        remaining_ms =>
            case Started of
                true -> max(0, Rem);
                false -> infinity
            end,
        paused => Paused,
        expired => Expired
    };
info(#{
    type := cycle,
    id := Id,
    phases := Phases,
    phase_index := Idx,
    phase_remaining := Rem,
    paused := Paused,
    expired := Expired
}) ->
    Phase = lists:nth(Idx + 1, Phases),
    #{
        type => cycle,
        id => Id,
        current_phase => maps:get(name, Phase),
        phase_remaining_ms => max(0, Rem),
        phase_index => Idx,
        total_phases => length(Phases),
        paused => Paused,
        expired => Expired,
        modifiers => maps:get(modifiers, Phase, #{})
    }.

%% -------------------------------------------------------------------
%% Internal — cycle ticking
%% -------------------------------------------------------------------

tick_cycle(
    DeltaMs,
    #{
        phases := Phases,
        phase_index := Idx,
        phase_remaining := Rem,
        repeat := Repeat,
        id := Id
    } = Timer,
    Events
) ->
    Rem1 = Rem - DeltaMs,
    case Rem1 =< 0 of
        false ->
            {lists:reverse(Events), Timer#{phase_remaining => Rem1}};
        true ->
            Overflow = abs(Rem1),
            NextIdx = Idx + 1,
            case NextIdx >= length(Phases) of
                true when Repeat ->
                    NewPhase = lists:nth(1, Phases),
                    NewDuration = maps:get(duration, NewPhase),
                    PhaseName = maps:get(name, NewPhase),
                    Events1 = [{phase_changed, Id, PhaseName} | Events],
                    Timer1 = Timer#{phase_index => 0, phase_remaining => NewDuration},
                    case Overflow > 0 of
                        true -> tick_cycle(Overflow, Timer1, Events1);
                        false -> {lists:reverse(Events1), Timer1}
                    end;
                true ->
                    Events1 = [{timer_expired, Id} | Events],
                    {lists:reverse(Events1), Timer#{expired => true, phase_remaining => 0}};
                false ->
                    NewPhase = lists:nth(NextIdx + 1, Phases),
                    NewDuration = maps:get(duration, NewPhase),
                    PhaseName = maps:get(name, NewPhase),
                    Events1 = [{phase_changed, Id, PhaseName} | Events],
                    Timer1 = Timer#{phase_index => NextIdx, phase_remaining => NewDuration},
                    case Overflow > 0 of
                        true -> tick_cycle(Overflow, Timer1, Events1);
                        false -> {lists:reverse(Events1), Timer1}
                    end
            end
    end.

%% -------------------------------------------------------------------
%% Internal — warning checks
%% -------------------------------------------------------------------

check_warnings(Id, Remaining, #{warnings := Warnings, warnings_fired := Fired} = Timer) ->
    {NewEvents, NewFired} = lists:foldl(
        fun(Threshold, {Evts, F}) ->
            case Remaining =< Threshold andalso not lists:member(Threshold, F) of
                true ->
                    {[{timer_warning, Id, Threshold} | Evts], [Threshold | F]};
                false ->
                    {Evts, F}
            end
        end,
        {[], Fired},
        Warnings
    ),
    {lists:reverse(NewEvents), Timer#{warnings_fired => NewFired}}.

%% -------------------------------------------------------------------
%% Internal — condition checking
%% -------------------------------------------------------------------

check_condition(player_joined, PlayerCount, {players, N}) when is_integer(PlayerCount) ->
    PlayerCount >= N;
check_condition(player_joined, PlayerCount, {players_ratio, Ratio}) when is_number(PlayerCount) ->
    PlayerCount >= Ratio;
check_condition(all_ready, true, {all_ready}) ->
    true;
check_condition(Event, _Data, {event, Event}) ->
    true;
check_condition(timer_expired, TimerId, {prev_expired, TimerId}) ->
    true;
check_condition(_Event, _Data, _Condition) ->
    false.
