-module(asobi_zone).
-behaviour(gen_server).

-export([start_link/1]).
-export([tick/2, player_input/3, add_entity/3, remove_entity/2]).
-export([spawn_entity/3, spawn_entity/4, spawn_entities/2, despawn_entity/2]).
-export([subscribe/2, unsubscribe/2]).
-export([get_entities/1, get_subscriber_count/1]).
-export([start_entity_timer/2, cancel_entity_timer/3]).
-export([query_radius/3, query_rect/3]).
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
    case gen_server:call(Pid, get_entities) of
        M when is_map(M) -> M
    end.

-spec get_subscriber_count(pid()) -> non_neg_integer().
get_subscriber_count(Pid) ->
    case gen_server:call(Pid, get_subscriber_count) of
        N when is_integer(N), N >= 0 -> N
    end.

-spec start_entity_timer(pid(), map()) -> ok.
start_entity_timer(Pid, Config) ->
    gen_server:cast(Pid, {start_entity_timer, Config}).

-spec cancel_entity_timer(pid(), binary(), binary()) -> ok.
cancel_entity_timer(Pid, EntityId, TimerId) ->
    gen_server:cast(Pid, {cancel_entity_timer, EntityId, TimerId}).

-spec spawn_entity(pid(), binary(), {number(), number()}) -> ok.
spawn_entity(Pid, TemplateId, Pos) ->
    spawn_entity(Pid, TemplateId, Pos, #{}).

-spec spawn_entity(pid(), binary(), {number(), number()}, map()) -> ok.
spawn_entity(Pid, TemplateId, Pos, Overrides) ->
    gen_server:cast(Pid, {spawn_entity, TemplateId, Pos, Overrides}).

-spec spawn_entities(pid(), [{binary(), {number(), number()}, map()}]) -> ok.
spawn_entities(Pid, Spawns) ->
    gen_server:cast(Pid, {spawn_entities, Spawns}).

-spec despawn_entity(pid(), binary()) -> ok.
despawn_entity(Pid, EntityId) ->
    gen_server:cast(Pid, {despawn_entity, EntityId}).

-spec query_radius(pid(), {number(), number()}, number()) -> [{binary(), {number(), number()}}].
query_radius(Pid, Center, Radius) ->
    narrow_id_pos_list(gen_server:call(Pid, {query_radius, Center, Radius})).

-spec query_rect(pid(), {number(), number()}, {number(), number()}) ->
    [{binary(), {number(), number()}}].
query_rect(Pid, TopLeft, BottomRight) ->
    narrow_id_pos_list(gen_server:call(Pid, {query_rect, TopLeft, BottomRight})).

-spec narrow_id_pos_list(term()) -> [{binary(), {number(), number()}}].
narrow_id_pos_list([]) ->
    [];
narrow_id_pos_list([{Id, {X, Y}} | Rest]) when
    is_binary(Id), is_number(X), is_number(Y)
->
    [{Id, {X, Y}} | narrow_id_pos_list(Rest)].

%% --- gen_server callbacks ---

-spec init(map()) -> {ok, map()}.
init(Config) ->
    WorldId = maps:get(world_id, Config),
    Coords = maps:get(coords, Config),
    TickerPid = maps:get(ticker_pid, Config),
    GameModule = maps:get(game_module, Config),
    ZoneState = maps:get(zone_state, Config, #{}),
    ZoneManagerPid = maps:get(zone_manager_pid, Config, undefined),
    TerrainStorePid = maps:get(terrain_store_pid, Config, undefined),
    pg:join(?PG_SCOPE, {asobi_zone, WorldId, Coords}, self()),
    %% Recover entity state from ETS backup if available (zone crash recovery)
    RecoveredEntities = recover_zone_state(WorldId, Coords),
    Templates = maps:get(spawn_templates, Config, #{}),
    SpawnerInit = maps:get(spawner_state, Config, undefined),
    Spawner =
        case SpawnerInit of
            undefined ->
                asobi_zone_spawner:new(Templates);
            S when is_map(S) ->
                asobi_zone_spawner:set_templates(
                    Templates, asobi_zone_spawner:deserialise(S)
                )
        end,
    Persistence = maps:get(persistence, Config, false),
    SnapshotInterval = maps:get(snapshot_interval, Config, 600),
    SpatialGrid =
        case maps:get(spatial_grid_cell_size, Config, undefined) of
            undefined -> undefined;
            CellSize -> asobi_spatial_grid:new(CellSize)
        end,
    {ok, #{
        world_id => WorldId,
        coords => Coords,
        ticker_pid => TickerPid,
        game_module => GameModule,
        zone_manager_pid => ZoneManagerPid,
        terrain_store_pid => TerrainStorePid,
        entities => RecoveredEntities,
        prev_entities => #{},
        broadcast_entities => #{},
        broadcast_interval => maps:get(broadcast_interval, Config, 3),
        subscribers => #{},
        zone_state => ZoneState,
        input_queue => [],
        entity_timers => asobi_entity_timer:new(),
        spawner => Spawner,
        persistence => Persistence,
        snapshot_interval => SnapshotInterval,
        spatial_grid => SpatialGrid,
        tick => 0
    }}.

-spec handle_call(term(), gen_server:from(), map()) -> {reply, term(), map()}.
handle_call(get_entities, _From, #{entities := Entities} = State) ->
    {reply, Entities, State};
handle_call(get_subscriber_count, _From, #{subscribers := Subs} = State) ->
    {reply, map_size(Subs), State};
handle_call(
    {query_radius, {CX, CY} = Center, Radius},
    _From,
    #{spatial_grid := Grid, entities := Entities} = State
) when is_number(CX), is_number(CY), is_number(Radius) ->
    Result =
        case Grid of
            undefined ->
                [
                    {Id, {maps:get(x, E), maps:get(y, E)}}
                 || {Id, E, _Dist} <- asobi_spatial:query_radius(Entities, Center, Radius)
                ];
            _ ->
                asobi_spatial_grid:query_radius(Center, Radius, Grid)
        end,
    {reply, Result, State};
handle_call(
    {query_rect, {TLX, TLY} = TopLeft, {BRX, BRY} = BottomRight},
    _From,
    #{spatial_grid := Grid, entities := Entities} = State
) when is_number(TLX), is_number(TLY), is_number(BRX), is_number(BRY) ->
    Result =
        case Grid of
            undefined ->
                [
                    {Id, {maps:get(x, E), maps:get(y, E)}}
                 || {Id, E} <- asobi_spatial:query_rect(Entities, TopLeft, BottomRight)
                ];
            _ ->
                asobi_spatial_grid:query_rect(TopLeft, BottomRight, Grid)
        end,
    {reply, Result, State};
handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

-spec handle_cast(term(), map()) -> {noreply, map()} | {noreply, map(), hibernate}.
handle_cast({tick, TickN}, State) ->
    State1 = do_tick(TickN, State),
    State2 = transfer_out_of_bounds_npcs(State1),
    #{subscribers := Subs, entities := Ents, zone_manager_pid := ZMPid, coords := Coords} = State2,
    case map_size(Subs) of
        0 ->
            case has_tickable_entities(Ents) of
                false -> {noreply, State2, hibernate};
                true -> {noreply, State2}
            end;
        _ ->
            case ZMPid of
                undefined -> ok;
                _ -> asobi_zone_manager:touch_zone(ZMPid, Coords)
            end,
            {noreply, State2}
    end;
handle_cast({input, PlayerId, Input}, #{input_queue := Queue} = State) ->
    {noreply, State#{input_queue => [{PlayerId, Input} | Queue]}};
handle_cast(
    {add_entity, EntityId, EntityState}, #{entities := Entities, spatial_grid := Grid} = State
) ->
    Grid1 = spatial_grid_insert(EntityId, EntityState, Grid),
    {noreply, State#{entities => Entities#{EntityId => EntityState}, spatial_grid => Grid1}};
handle_cast({remove_entity, EntityId}, #{entities := Entities, spatial_grid := Grid} = State) ->
    Grid1 = spatial_grid_remove(EntityId, Grid),
    {noreply, State#{entities => maps:remove(EntityId, Entities), spatial_grid => Grid1}};
handle_cast(
    {subscribe, PlayerId, PlayerPid},
    #{subscribers := Subs, entities := Entities, coords := Coords} = State
) when is_binary(PlayerId), is_pid(PlayerPid) ->
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
    _ =
        case maps:get(terrain_store_pid, State, undefined) of
            undefined ->
                ok;
            StorePid ->
                case asobi_terrain_store:get_chunk(StorePid, Coords) of
                    {ok, Data} ->
                        PlayerPid ! {asobi_message, {terrain_chunk, Coords, Data}};
                    _ ->
                        ok
                end
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
handle_cast({start_entity_timer, Config}, #{entity_timers := ET} = State) when is_map(Config) ->
    {noreply, State#{entity_timers => asobi_entity_timer:start_timer(Config, ET)}};
handle_cast({cancel_entity_timer, EntityId, TimerId}, #{entity_timers := ET} = State) when
    is_binary(EntityId), is_binary(TimerId)
->
    {noreply, State#{entity_timers => asobi_entity_timer:cancel_timer(EntityId, TimerId, ET)}};
handle_cast(
    {spawn_entity, TemplateId, {PX, PY} = Pos, Overrides},
    #{entities := Entities, spawner := Spawner, spatial_grid := Grid} = State
) when is_binary(TemplateId), is_number(PX), is_number(PY), is_map(Overrides) ->
    case asobi_zone_spawner:spawn_entity(TemplateId, Pos, Overrides, Spawner) of
        {ok, {EntityId, Entity}, Spawner1} ->
            Grid1 = spatial_grid_insert(EntityId, Entity, Grid),
            {noreply, State#{
                entities => Entities#{EntityId => Entity},
                spawner => Spawner1,
                spatial_grid => Grid1
            }};
        {error, _} ->
            {noreply, State}
    end;
handle_cast({spawn_entities, Spawns}, State) when is_list(Spawns) ->
    {noreply, apply_spawns(Spawns, State)};
handle_cast(
    {despawn_entity, EntityId},
    #{entities := Entities, spawner := Spawner, spatial_grid := Grid} = State
) when is_binary(EntityId) ->
    Now = erlang:system_time(millisecond),
    Spawner1 = asobi_zone_spawner:entity_removed(EntityId, Now, Spawner),
    Grid1 = spatial_grid_remove(EntityId, Grid),
    {noreply, State#{
        entities => maps:remove(EntityId, Entities), spawner => Spawner1, spatial_grid => Grid1
    }};
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
terminate(normal, #{world_id := WorldId, coords := Coords} = State) ->
    maybe_final_snapshot(State),
    clear_zone_backup(WorldId, Coords),
    notify_zone_manager_terminated(State),
    pg:leave(?PG_SCOPE, {asobi_zone, WorldId, Coords}, self()),
    ok;
terminate({shutdown, _}, #{world_id := WorldId, coords := Coords} = State) ->
    maybe_final_snapshot(State),
    clear_zone_backup(WorldId, Coords),
    notify_zone_manager_terminated(State),
    pg:leave(?PG_SCOPE, {asobi_zone, WorldId, Coords}, self()),
    ok;
terminate(_Reason, #{world_id := WorldId, coords := Coords, entities := Entities} = State) ->
    %% Abnormal termination — save state for recovery
    maybe_final_snapshot(State),
    backup_zone_state(WorldId, Coords, Entities),
    notify_zone_manager_terminated(State),
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
    %% Tick spawner — process respawn queue
    Spawner = maps:get(spawner, State),
    {Respawns, Spawner1} = asobi_zone_spawner:tick(Now, Spawner),
    Entities4 = apply_respawns(Respawns, Entities3),
    %% Only broadcast every Nth tick to reduce network traffic
    State1 =
        case TickN rem BroadcastInterval of
            0 ->
                Deltas = compute_deltas(BroadcastEntities, Entities4),
                broadcast_deltas(TickN, Deltas, Subs),
                State#{broadcast_entities => Entities4};
            _ ->
                State
        end,
    asobi_world_ticker:tick_done(TickerPid, self(), TickN),
    %% Periodic backup for crash recovery (every 20 ticks ≈ 1 second)
    case TickN rem 20 of
        0 -> backup_zone_state(WorldId, Coords, Entities4);
        _ -> ok
    end,
    %% Periodic DB snapshot for persistence
    SnapshotInterval = maps:get(snapshot_interval, State1),
    Persistence = maps:get(persistence, State1),
    case Persistence andalso SnapshotInterval > 0 andalso TickN rem SnapshotInterval =:= 0 of
        true ->
            asobi_zone_snapshotter:snapshot(#{
                world_id => WorldId,
                coords => Coords,
                entities => snapshot_entities(Entities4),
                zone_state => ZoneState1,
                entity_timers => asobi_entity_timer:info(ET1),
                spawner_state => asobi_zone_spawner:serialise(Spawner1),
                tick => TickN
            });
        false ->
            ok
    end,
    Grid = maps:get(spatial_grid, State1),
    Grid1 = sync_spatial_grid(Entities, Entities4, Grid),
    State1#{
        entities => Entities4,
        prev_entities => Entities4,
        zone_state => ZoneState1,
        input_queue => [],
        entity_timers => ET1,
        spawner => Spawner1,
        spatial_grid => Grid1,
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
    EncodedDeltas = encode_deltas(Deltas),
    Payload = #{
        ~"type" => ~"world.tick", ~"payload" => #{~"tick" => TickN, ~"updates" => EncodedDeltas}
    },
    PreEncoded = iolist_to_binary(json:encode(Payload)),
    RawMsg = {asobi_message, {zone_delta_raw, PreEncoded}},
    maps:foreach(
        fun(_PlayerId, {Pid, _MonRef}) -> Pid ! RawMsg end,
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

%% --- NPC Zone Crossing ---

transfer_out_of_bounds_npcs(
    #{
        entities := Entities,
        zone_state := ZS,
        world_id := WorldId,
        coords := {ZX, ZY}
    } = State
) ->
    Zs = maps:get(zone_size, ZS, 1200) * 1.0,
    {ToRemove, ToTransfer} = maps:fold(
        fun
            (Id, #{type := ~"npc", x := X, y := Y} = Entity, {Rem, Trans}) ->
                NewZX = trunc(X / Zs),
                NewZY = trunc(Y / Zs),
                case {NewZX, NewZY} =/= {ZX, ZY} of
                    true -> {[Id | Rem], [{Id, {NewZX, NewZY}, Entity} | Trans]};
                    false -> {Rem, Trans}
                end;
            (_, _, Acc) ->
                Acc
        end,
        {[], []},
        Entities
    ),
    %% Transfer each NPC to the target zone
    lists:foreach(
        fun({Id, TargetCoords, Entity}) ->
            case pg:get_members(?PG_SCOPE, {asobi_zone, WorldId, TargetCoords}) of
                [TargetPid | _] ->
                    gen_server:cast(TargetPid, {add_entity, Id, Entity});
                [] ->
                    %% Target zone doesn't exist, NPC disappears
                    ok
            end
        end,
        ToTransfer
    ),
    %% Remove transferred NPCs from this zone
    Entities1 = maps:without(ToRemove, Entities),
    Grid = maps:get(spatial_grid, State, undefined),
    Grid1 = remove_from_grid(ToRemove, Grid),
    State#{entities => Entities1, spatial_grid => Grid1};
transfer_out_of_bounds_npcs(State) ->
    State.

%% --- Snapshot Helpers ---

snapshot_entities(Entities) ->
    maps:filter(
        fun(_Id, E) ->
            maps:get(type, E, ~"unknown") =/= ~"player" andalso
                maps:get(persistent, E, true)
        end,
        Entities
    ).

maybe_final_snapshot(#{persistence := true} = State) ->
    #{
        world_id := WorldId,
        coords := Coords,
        entities := Entities,
        zone_state := ZoneState,
        entity_timers := ET,
        spawner := Spawner,
        tick := Tick
    } = State,
    try
        asobi_zone_snapshotter:snapshot_sync(#{
            world_id => WorldId,
            coords => Coords,
            entities => snapshot_entities(Entities),
            zone_state => ZoneState,
            entity_timers => asobi_entity_timer:info(ET),
            spawner_state => asobi_zone_spawner:serialise(Spawner),
            tick => Tick
        })
    catch
        _:_ -> ok
    end;
maybe_final_snapshot(_) ->
    ok.

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

notify_zone_manager_terminated(#{zone_manager_pid := ZMPid, coords := Coords}) when is_pid(ZMPid) ->
    asobi_zone_manager:zone_terminated(ZMPid, Coords);
notify_zone_manager_terminated(_) ->
    ok.

has_tickable_entities(Entities) ->
    maps:fold(
        fun
            (_, #{type := ~"npc"}, _) -> true;
            (_, _, Acc) -> Acc
        end,
        false,
        Entities
    ).

%% --- Spatial Grid Helpers ---

spatial_grid_insert(_EntityId, _EntityState, undefined) ->
    undefined;
spatial_grid_insert(EntityId, #{x := X, y := Y}, Grid) ->
    asobi_spatial_grid:insert(EntityId, {X, Y}, Grid);
spatial_grid_insert(_EntityId, _EntityState, Grid) ->
    Grid.

spatial_grid_remove(_EntityId, undefined) ->
    undefined;
spatial_grid_remove(EntityId, Grid) ->
    asobi_spatial_grid:remove(EntityId, Grid).

-spec apply_spawns([term()], map()) -> map().
apply_spawns([], State) ->
    State;
apply_spawns(
    [{TemplateId, {PX, PY} = Pos, Overrides} | Rest],
    #{entities := Ents, spawner := Sp, spatial_grid := Gr} = State
) when is_binary(TemplateId), is_number(PX), is_number(PY), is_map(Overrides) ->
    State1 =
        case asobi_zone_spawner:spawn_entity(TemplateId, Pos, Overrides, Sp) of
            {ok, {EntityId, Entity}, Sp1} ->
                Gr1 = spatial_grid_insert(EntityId, Entity, Gr),
                State#{
                    entities => Ents#{EntityId => Entity},
                    spawner => Sp1,
                    spatial_grid => Gr1
                };
            {error, _} ->
                State
        end,
    apply_spawns(Rest, State1);
apply_spawns([_ | Rest], State) ->
    apply_spawns(Rest, State).

-spec apply_respawns([{binary(), map(), {number(), number()}}], map()) -> map().
apply_respawns([], Entities) ->
    Entities;
apply_respawns([{EntityId, EntityState, _Pos} | Rest], Entities) when is_binary(EntityId) ->
    apply_respawns(Rest, Entities#{EntityId => EntityState}).

-spec remove_from_grid([term()], asobi_spatial_grid:grid() | undefined) ->
    asobi_spatial_grid:grid() | undefined.
remove_from_grid(_Ids, undefined) ->
    undefined;
remove_from_grid(Ids, Grid) ->
    remove_from_grid_do(Ids, Grid).

-spec remove_from_grid_do([term()], asobi_spatial_grid:grid()) -> asobi_spatial_grid:grid().
remove_from_grid_do([], Grid) ->
    Grid;
remove_from_grid_do([Id | Rest], Grid) when is_binary(Id) ->
    remove_from_grid_do(Rest, asobi_spatial_grid:remove(Id, Grid));
remove_from_grid_do([_ | Rest], Grid) ->
    remove_from_grid_do(Rest, Grid).

sync_spatial_grid(_OldEntities, _NewEntities, undefined) ->
    undefined;
sync_spatial_grid(OldEntities, NewEntities, Grid) when is_map(Grid) ->
    %% Remove entities that no longer exist
    Removed = maps:keys(OldEntities) -- maps:keys(NewEntities),
    Grid1 = remove_from_grid_do(Removed, Grid),
    %% Update/insert entities with changed or new positions
    maps:fold(
        fun
            (Id, #{x := X, y := Y}, G) ->
                case maps:find(Id, OldEntities) of
                    {ok, #{x := X, y := Y}} -> G;
                    _ -> asobi_spatial_grid:update(Id, {X, Y}, G)
                end;
            (_Id, _Entity, G) ->
                G
        end,
        Grid1,
        NewEntities
    ).
