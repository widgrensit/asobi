-module(asobi_entity_timer).

-include_lib("kernel/include/logger.hrl").

%% Per-entity timers for zone-level objects (crafting, decay, cooldowns).
%%
%% Designed for scale: no individual erlang:send_after per entity.
%% The zone server calls `tick/2` each zone tick, which checks all
%% active timers against wall-clock time. Expired timers fire events.
%%
%% Timers survive zone snapshots via serialise/1 + deserialise/1. `end_at`
%% is absolute wall-clock, so a timer that expired while the zone was reaped
%% fires on the first tick after restore. `on_complete` is persisted as-is and
%% so must be JSON-safe (binary / number / boolean / null / map / list); a
%% tuple or atom will not round-trip through the jsonb column.

-export([new/0, start_timer/2, cancel_timer/3, tick/2]).
-export([get_timers/2, active_count/1, info/1]).
-export([serialise/1, deserialise/1]).

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

%% -------------------------------------------------------------------
%% Serialisation (for zone snapshots)
%% -------------------------------------------------------------------

-spec serialise(state()) -> map().
serialise(#{timers := Timers}) ->
    #{
        ~"timers" => maps:map(
            fun(_EntityId, EntityTimers) ->
                maps:map(fun(_TimerId, Entry) -> serialise_entry(Entry) end, EntityTimers)
            end,
            Timers
        )
    }.

-spec deserialise(map()) -> state().
deserialise(#{~"timers" := Timers}) when is_map(Timers) ->
    #{
        timers => maps:fold(
            fun(EntityId, EntityTimers, Acc) ->
                Decoded = deserialise_entity_timers(EntityTimers),
                case map_size(Decoded) of
                    0 -> Acc;
                    _ -> Acc#{EntityId => Decoded}
                end
            end,
            #{},
            Timers
        )
    };
deserialise(_) ->
    %% Pre-persistence snapshots stored only an active-timer count; nothing to
    %% restore.
    new().

deserialise_entity_timers(EntityTimers) when is_map(EntityTimers) ->
    maps:fold(
        fun(TimerId, Entry, Acc) ->
            case deserialise_entry(Entry) of
                skip -> Acc;
                Decoded -> Acc#{TimerId => Decoded}
            end
        end,
        #{},
        EntityTimers
    );
deserialise_entity_timers(_) ->
    #{}.

serialise_entry(#{
    timer_id := TimerId,
    entity_id := EntityId,
    owner := Owner,
    end_at := EndAt,
    on_complete := OnComplete,
    category := Category,
    pause_when_offline := PauseWhenOffline,
    paused := Paused
}) ->
    #{
        ~"timer_id" => TimerId,
        ~"entity_id" => EntityId,
        ~"owner" => owner_to_json(Owner),
        ~"end_at" => EndAt,
        ~"on_complete" => json_safe(OnComplete),
        ~"category" => atom_to_binary(Category, utf8),
        ~"pause_when_offline" => PauseWhenOffline,
        ~"paused" => Paused
    }.

deserialise_entry(
    #{
        ~"timer_id" := TimerId,
        ~"entity_id" := EntityId,
        ~"end_at" := EndAt
    } = Entry
) when is_number(EndAt) ->
    #{
        timer_id => TimerId,
        entity_id => EntityId,
        owner => owner_from_json(maps:get(~"owner", Entry, null)),
        end_at => to_int(EndAt),
        on_complete => maps:get(~"on_complete", Entry, undefined),
        category => category_from_json(maps:get(~"category", Entry, ~"general")),
        pause_when_offline => maps:get(~"pause_when_offline", Entry, false),
        paused => maps:get(~"paused", Entry, false)
    };
deserialise_entry(Entry) ->
    %% A truncated/corrupt row must not abort the whole zone's restore.
    ?LOG_WARNING(#{event => entity_timer_skipped_bad_entry, entry => Entry}),
    skip.

%% on_complete is delivered to game code as-is and persisted verbatim, so it
%% must survive jsonb. Anything json:encode/1 rejects (tuples, pids, refs,
%% funs) is dropped to null rather than crashing the snapshot write.
json_safe(Value) ->
    try
        _ = json:encode(Value),
        Value
    catch
        _:_ ->
            ?LOG_WARNING(#{event => timer_on_complete_not_json_safe, value => Value}),
            null
    end.

owner_to_json(undefined) -> null;
owner_to_json(Owner) -> Owner.

owner_from_json(null) -> undefined;
owner_from_json(Owner) when is_binary(Owner) -> Owner;
owner_from_json(_) -> undefined.

%% Never create atoms from persisted data (atom-table exhaustion). A category
%% in use already exists as an atom; an unknown one falls back to `general`.
category_from_json(Bin) when is_binary(Bin) ->
    try
        binary_to_existing_atom(Bin, utf8)
    catch
        error:badarg -> general
    end;
category_from_json(_) ->
    general.

to_int(N) when is_integer(N) -> N;
to_int(N) when is_float(N) -> trunc(N).
