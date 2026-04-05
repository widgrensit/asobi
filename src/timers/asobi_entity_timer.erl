-module(asobi_entity_timer).

%% Per-entity timers for zone-level objects (crafting, decay, cooldowns).
%%
%% Designed for scale: no individual erlang:send_after per entity.
%% The zone server calls `tick/2` each zone tick, which checks all
%% active timers against wall-clock time. Expired timers fire events.

-export([new/0, start_timer/2, cancel_timer/3, tick/2]).
-export([get_timers/2, active_count/1, info/1]).

-export_type([state/0, entity_timer_event/0]).

-opaque state() :: #{
    timers := #{binary() => #{binary() => timer_entry()}}
}.

-type timer_entry() :: #{
    timer_id := binary(),
    entity_id := binary(),
    owner := binary() | undefined,
    end_at := pos_integer(),
    on_complete := term(),
    category := atom(),
    pause_when_offline := boolean(),
    paused := boolean()
}.

-type entity_timer_event() ::
    {entity_timer_expired, binary(), binary(), term()}.

%% -------------------------------------------------------------------
%% Constructor
%% -------------------------------------------------------------------

-spec new() -> state().
new() ->
    #{timers => #{}}.

%% -------------------------------------------------------------------
%% Start a timer on an entity
%% -------------------------------------------------------------------

-spec start_timer(map(), state()) -> state().
start_timer(Config, #{timers := Timers} = State) ->
    EntityId = maps:get(entity_id, Config),
    TimerId = maps:get(timer_id, Config),
    Duration = maps:get(duration, Config),
    Entry = #{
        timer_id => TimerId,
        entity_id => EntityId,
        owner => maps:get(owner, Config, undefined),
        end_at => erlang:system_time(millisecond) + Duration,
        on_complete => maps:get(on_complete, Config, undefined),
        category => maps:get(category, Config, general),
        pause_when_offline => maps:get(pause_when_offline, Config, false),
        paused => false
    },
    EntityTimers = maps:get(EntityId, Timers, #{}),
    EntityTimers1 = EntityTimers#{TimerId => Entry},
    State#{timers => Timers#{EntityId => EntityTimers1}}.

%% -------------------------------------------------------------------
%% Cancel a timer
%% -------------------------------------------------------------------

-spec cancel_timer(binary(), binary(), state()) -> state().
cancel_timer(EntityId, TimerId, #{timers := Timers} = State) ->
    case maps:get(EntityId, Timers, undefined) of
        undefined ->
            State;
        EntityTimers ->
            EntityTimers1 = maps:remove(TimerId, EntityTimers),
            case map_size(EntityTimers1) of
                0 -> State#{timers => maps:remove(EntityId, Timers)};
                _ -> State#{timers => Timers#{EntityId => EntityTimers1}}
            end
    end.

%% -------------------------------------------------------------------
%% Tick — check all timers, return expired events + updated state
%% -------------------------------------------------------------------

-spec tick(pos_integer(), state()) -> {[entity_timer_event()], state()}.
tick(Now, #{timers := Timers} = State) ->
    {Events, Timers1} = maps:fold(
        fun(EntityId, EntityTimers, {EvtAcc, TAcc}) ->
            {Expired, Remaining} = maps:fold(
                fun(TId, #{end_at := EndAt, paused := Paused} = Entry, {Exp, Rem}) ->
                    case not Paused andalso Now >= EndAt of
                        true ->
                            OnComplete = maps:get(on_complete, Entry),
                            {[{entity_timer_expired, EntityId, TId, OnComplete} | Exp], Rem};
                        false ->
                            {Exp, Rem#{TId => Entry}}
                    end
                end,
                {[], #{}},
                EntityTimers
            ),
            TAcc1 =
                case map_size(Remaining) of
                    0 -> TAcc;
                    _ -> TAcc#{EntityId => Remaining}
                end,
            {Expired ++ EvtAcc, TAcc1}
        end,
        {[], #{}},
        Timers
    ),
    {Events, State#{timers => Timers1}}.

%% -------------------------------------------------------------------
%% Queries
%% -------------------------------------------------------------------

-spec get_timers(binary(), state()) -> [timer_entry()].
get_timers(EntityId, #{timers := Timers}) ->
    case maps:get(EntityId, Timers, undefined) of
        undefined -> [];
        EntityTimers -> maps:values(EntityTimers)
    end.

-spec active_count(state()) -> non_neg_integer().
active_count(#{timers := Timers}) ->
    maps:fold(
        fun(_EntityId, EntityTimers, Acc) -> Acc + map_size(EntityTimers) end,
        0,
        Timers
    ).

-spec info(state()) -> map().
info(State) ->
    #{active_timers => active_count(State)}.
