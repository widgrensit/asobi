-module(asobi_zone).
-behaviour(gen_server).

-export([start_link/1]).
-export([tick/2, player_input/3, add_entity/3, remove_entity/2]).
-export([subscribe/2, unsubscribe/2]).
-export([get_entities/1, get_subscriber_count/1]).
-export([start_entity_timer/2, cancel_entity_timer/3]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(PG_SCOPE, nova_scope).

%% --- Public API ---

-spec start_link(map()) -> gen_server:start_ret().
start_link(Config) ->
    gen_server:start_link(?MODULE, Config, []).

-spec tick(pid(), non_neg_integer()) -> ok.
tick(Pid, TickN) ->
    gen_server:cast(Pid, {tick, TickN}).

-spec player_input(pid(), binary(), map()) -> ok.
player_input(Pid, PlayerId, Input) ->
    gen_server:cast(Pid, {input, PlayerId, Input}).

-spec add_entity(pid(), binary(), map()) -> ok.
add_entity(Pid, EntityId, EntityState) ->
    gen_server:cast(Pid, {add_entity, EntityId, EntityState}).

-spec remove_entity(pid(), binary()) -> ok.
remove_entity(Pid, EntityId) ->
    gen_server:cast(Pid, {remove_entity, EntityId}).

-spec subscribe(pid(), {binary(), pid()}) -> ok.
subscribe(Pid, {PlayerId, PlayerPid}) ->
    gen_server:cast(Pid, {subscribe, PlayerId, PlayerPid}).

-spec unsubscribe(pid(), binary()) -> ok.
unsubscribe(Pid, PlayerId) ->
    gen_server:cast(Pid, {unsubscribe, PlayerId}).

-spec get_entities(pid()) -> map().
get_entities(Pid) ->
    gen_server:call(Pid, get_entities).

-spec get_subscriber_count(pid()) -> non_neg_integer().
get_subscriber_count(Pid) ->
    gen_server:call(Pid, get_subscriber_count).

-spec start_entity_timer(pid(), map()) -> ok.
start_entity_timer(Pid, Config) ->
    gen_server:cast(Pid, {start_entity_timer, Config}).

-spec cancel_entity_timer(pid(), binary(), binary()) -> ok.
cancel_entity_timer(Pid, EntityId, TimerId) ->
    gen_server:cast(Pid, {cancel_entity_timer, EntityId, TimerId}).

%% --- gen_server callbacks ---

-spec init(map()) -> {ok, map()}.
init(Config) ->
    WorldId = maps:get(world_id, Config),
    Coords = maps:get(coords, Config),
    TickerPid = maps:get(ticker_pid, Config),
    GameModule = maps:get(game_module, Config),
    ZoneState = maps:get(zone_state, Config, #{}),
    pg:join(?PG_SCOPE, {asobi_zone, WorldId, Coords}, self()),
    %% Recover entity state from ETS backup if available (zone crash recovery)
    RecoveredEntities = recover_zone_state(WorldId, Coords),
    {ok, #{
        world_id => WorldId,
        coords => Coords,
        ticker_pid => TickerPid,
        game_module => GameModule,
        entities => RecoveredEntities,
        prev_entities => #{},
        broadcast_entities => #{},
        broadcast_interval => maps:get(broadcast_interval, Config, 3),
        subscribers => #{},
        zone_state => ZoneState,
        input_queue => [],
        entity_timers => asobi_entity_timer:new(),
        tick => 0
    }}.

-spec handle_call(term(), gen_server:from(), map()) -> {reply, term(), map()}.
handle_call(get_entities, _From, #{entities := Entities} = State) ->
    {reply, Entities, State};
handle_call(get_subscriber_count, _From, #{subscribers := Subs} = State) ->
    {reply, map_size(Subs), State};
handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

-spec handle_cast(term(), map()) -> {noreply, map()}.
handle_cast({tick, TickN}, State) ->
    State1 = do_tick(TickN, State),
    {noreply, State1};
handle_cast({input, PlayerId, Input}, #{input_queue := Queue} = State) ->
    {noreply, State#{input_queue => [{PlayerId, Input} | Queue]}};
handle_cast({add_entity, EntityId, EntityState}, #{entities := Entities} = State) ->
    {noreply, State#{entities => Entities#{EntityId => EntityState}}};
handle_cast({remove_entity, EntityId}, #{entities := Entities} = State) ->
    {noreply, State#{entities => maps:remove(EntityId, Entities)}};
handle_cast({subscribe, PlayerId, PlayerPid}, #{subscribers := Subs, entities := Entities} = State) ->
    MonRef = monitor(process, PlayerPid),
    %% Send immediate snapshot so new subscribers see all current entities
    _ =
        case map_size(Entities) of
            0 ->
                ok;
            _ ->
                Snapshot = [E#{~"op" => ~"a", ~"id" => Id} || {Id, E} <- maps:to_list(Entities)],
                PlayerPid ! {asobi_message, {zone_delta, 0, Snapshot}}
        end,
    {noreply, State#{subscribers => Subs#{PlayerId => {PlayerPid, MonRef}}}};
handle_cast({unsubscribe, PlayerId}, #{subscribers := Subs} = State) ->
    case maps:get(PlayerId, Subs, undefined) of
        undefined ->
            {noreply, State};
        {_Pid, MonRef} ->
            demonitor(MonRef, [flush]),
            {noreply, State#{subscribers => maps:remove(PlayerId, Subs)}}
    end;
handle_cast({start_entity_timer, Config}, #{entity_timers := ET} = State) ->
    {noreply, State#{entity_timers => asobi_entity_timer:start_timer(Config, ET)}};
handle_cast({cancel_entity_timer, EntityId, TimerId}, #{entity_timers := ET} = State) ->
    {noreply, State#{entity_timers => asobi_entity_timer:cancel_timer(EntityId, TimerId, ET)}};
handle_cast(_Msg, State) ->
    {noreply, State}.

-spec handle_info(term(), map()) -> {noreply, map()}.
handle_info({'DOWN', _Ref, process, DownPid, _Reason}, #{subscribers := Subs} = State) ->
    Subs1 = maps:filter(
        fun(_PlayerId, {Pid, _MonRef}) -> Pid =/= DownPid end,
        Subs
    ),
    {noreply, State#{subscribers => Subs1}};
handle_info(_Info, State) ->
    {noreply, State}.

-spec terminate(term(), map()) -> ok.
terminate(normal, #{world_id := WorldId, coords := Coords}) ->
    clear_zone_backup(WorldId, Coords),
    pg:leave(?PG_SCOPE, {asobi_zone, WorldId, Coords}, self()),
    ok;
terminate({shutdown, _}, #{world_id := WorldId, coords := Coords}) ->
    clear_zone_backup(WorldId, Coords),
    pg:leave(?PG_SCOPE, {asobi_zone, WorldId, Coords}, self()),
    ok;
terminate(_Reason, #{world_id := WorldId, coords := Coords, entities := Entities}) ->
    %% Abnormal termination — save state for recovery
    backup_zone_state(WorldId, Coords, Entities),
    pg:leave(?PG_SCOPE, {asobi_zone, WorldId, Coords}, self()),
    ok.

%% --- Internal ---

do_tick(
    TickN,
    #{
        world_id := WorldId,
        coords := Coords,
        game_module := GameMod,
        entities := Entities,
        prev_entities := _PrevEntities,
        broadcast_entities := BroadcastEntities,
        broadcast_interval := BroadcastInterval,
        zone_state := ZoneState,
        input_queue := Queue,
        subscribers := Subs,
        ticker_pid := TickerPid,
        entity_timers := ET
    } = State
) ->
    Entities1 = apply_inputs(GameMod, Queue, Entities),
    ZoneStateWithTick = ZoneState#{tick => TickN},
    {Entities2, ZoneState1} = GameMod:zone_tick(Entities1, ZoneStateWithTick),
    Now = erlang:system_time(millisecond),
    {TimerEvents, ET1} = asobi_entity_timer:tick(Now, ET),
    Entities3 = apply_timer_events(TimerEvents, Entities2),
    %% Only broadcast every Nth tick to reduce network traffic
    State1 =
        case TickN rem BroadcastInterval of
            0 ->
                Deltas = compute_deltas(BroadcastEntities, Entities3),
                broadcast_deltas(TickN, Deltas, Subs),
                State#{broadcast_entities => Entities3};
            _ ->
                State
        end,
    asobi_world_ticker:tick_done(TickerPid, self(), TickN),
    %% Periodic backup for crash recovery (every 20 ticks ≈ 1 second)
    case TickN rem 20 of
        0 -> backup_zone_state(WorldId, Coords, Entities3);
        _ -> ok
    end,
    State1#{
        entities => Entities3,
        prev_entities => Entities3,
        zone_state => ZoneState1,
        input_queue => [],
        entity_timers => ET1,
        tick => TickN
    }.

apply_timer_events([], Entities) ->
    Entities;
apply_timer_events([{entity_timer_expired, EntityId, _TimerId, OnComplete} | Rest], Entities) ->
    Entities1 =
        case maps:get(EntityId, Entities, undefined) of
            undefined ->
                Entities;
            EntityState ->
                Timers = maps:get(~"completed_timers", EntityState, []),
                Entities#{EntityId => EntityState#{~"completed_timers" => [OnComplete | Timers]}}
        end,
    apply_timer_events(Rest, Entities1).

apply_inputs(_GameMod, [], Entities) ->
    Entities;
apply_inputs(GameMod, [{PlayerId, Input} | Rest], Entities) ->
    case GameMod:handle_input(PlayerId, Input, Entities) of
        {ok, Entities1} ->
            apply_inputs(GameMod, Rest, Entities1);
        {error, Reason} ->
            logger:warning(#{
                msg => ~"zone input rejected",
                player_id => PlayerId,
                reason => Reason
            }),
            apply_inputs(GameMod, Rest, Entities)
    end.

-spec compute_deltas(map(), map()) -> [term()].
compute_deltas(OldEntities, NewEntities) ->
    Updates = maps:fold(
        fun(Id, NewState, Acc) ->
            case maps:find(Id, OldEntities) of
                {ok, NewState} ->
                    Acc;
                {ok, OldState} ->
                    Diff = maps:filter(
                        fun(K, V) -> maps:get(K, OldState, undefined) =/= V end,
                        NewState
                    ),
                    case map_size(Diff) of
                        0 -> Acc;
                        _ -> [{updated, Id, Diff} | Acc]
                    end;
                error ->
                    [{added, Id, NewState} | Acc]
            end
        end,
        [],
        NewEntities
    ),
    Removed = [
        {removed, Id}
     || Id <- maps:keys(OldEntities), not maps:is_key(Id, NewEntities)
    ],
    Updates ++ Removed.

broadcast_deltas(_TickN, [], _Subs) ->
    ok;
broadcast_deltas(TickN, Deltas, Subs) ->
    Msg = {asobi_message, {zone_delta, TickN, encode_deltas(Deltas)}},
    maps:foreach(
        fun(_PlayerId, {Pid, _MonRef}) -> Pid ! Msg end,
        Subs
    ).

encode_deltas(Deltas) ->
    [encode_delta(D) || D <- Deltas].

encode_delta({updated, Id, Diff}) ->
    Diff#{~"op" => ~"u", ~"id" => Id};
encode_delta({added, Id, FullState}) ->
    FullState#{~"op" => ~"a", ~"id" => Id};
encode_delta({removed, Id}) ->
    #{~"op" => ~"r", ~"id" => Id}.

%% --- Zone State Backup/Recovery ---

backup_zone_state(WorldId, Coords, Entities) ->
    case ets:info(asobi_world_state) of
        undefined -> ok;
        _ -> ets:insert(asobi_world_state, {{WorldId, Coords}, Entities})
    end.

recover_zone_state(WorldId, Coords) ->
    case ets:info(asobi_world_state) of
        undefined ->
            #{};
        _ ->
            case ets:lookup(asobi_world_state, {WorldId, Coords}) of
                [{{WorldId, Coords}, Entities}] ->
                    ets:delete(asobi_world_state, {WorldId, Coords}),
                    Entities;
                [] ->
                    #{}
            end
    end.

clear_zone_backup(WorldId, Coords) ->
    case ets:info(asobi_world_state) of
        undefined -> ok;
        _ -> ets:delete(asobi_world_state, {WorldId, Coords})
    end.
