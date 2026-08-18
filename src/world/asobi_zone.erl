-module(asobi_zone).
-moduledoc """
One spatial partition of an `asobi_world_server`. A `gen_server` that owns
the entities in its cell of the grid, ticks their simulation, applies
player input, manages interest (subscribers), and answers spatial queries
via `asobi_spatial`. Zones are created and reaped lazily as players move.
""".
-behaviour(gen_server).

-export([start_link/1, reap/1]).
-export([tick/2, player_input/3, player_input/4, add_entity/3, remove_entity/2]).
-export([spawn_entity/3, spawn_entity/4, spawn_entities/2, despawn_entity/2]).
-export([subscribe/2, unsubscribe/2, resync/2]).
-export([get_entities/1, get_subscriber_count/1, sync/1]).
-export([start_entity_timer/2, cancel_entity_timer/3]).
-export([query_radius/3, query_rect/3]).
-export([init/1, handle_call/3, handle_cast/2, handle_continue/2, handle_info/2, terminate/2]).
-ifdef(TEST).
-export([past_zone_margin/4, classify_crossing/5]).
-endif.

-include_lib("kernel/include/logger.hrl").

-define(PG_SCOPE, nova_scope).
%% Must match asobi_world_server's own defaults of the same name.
-define(DEFAULT_ZONE_SIZE, 200).
-define(DEFAULT_GRID_SIZE, 10).
-define(DEFAULT_REHOME_MARGIN, 0.15).
%% Bound on the per-tick zone-manager call an NPC crossing into an unloaded
%% neighbour makes (widgrensit/asobi#271). The manager's own work there is
%% an ETS lookup plus a supervisor:start_child (the new zone's snapshot load
%% happens in its handle_continue, off the manager), so exceeding this means
%% the manager is saturated - in which case the NPC waits in this zone for a
%% later tick rather than the zone stalling behind a 5s gen_server default.
-define(ENSURE_ZONE_TIMEOUT, 1_000).

%% --- Public API ---

-spec start_link(map()) -> gen_server:start_ret().
start_link(Config) ->
    gen_server:start_link(?MODULE, Config, []).

%% Stop the zone gracefully so terminate/2 runs a final snapshot. The zone
%% child is `transient`, so a normal stop does not respawn. Used by the zone
%% manager when reaping idle zones - unlike a supervisor kill, this preserves
%% the zone's gameplay state.
-spec reap(pid()) -> ok.
reap(Pid) ->
    gen_server:cast(Pid, reap).

-spec tick(pid(), non_neg_integer()) -> ok.
tick(Pid, TickN) ->
    gen_server:cast(Pid, {tick, TickN}).

-spec player_input(pid(), binary(), map()) -> ok.
player_input(Pid, PlayerId, Input) ->
    player_input(Pid, PlayerId, Input, undefined).

-spec player_input(pid(), binary(), map(), non_neg_integer() | undefined) -> ok.
player_input(Pid, PlayerId, Input, Seq) ->
    gen_server:cast(Pid, {input, PlayerId, Input, Seq}).

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

-doc """
Re-send `PlayerId` a keyframe for this zone, on their own request.

The repair half of `frame_seq`: a client that sees a gap asks for a fresh
baseline rather than carrying a corrupted entity table for the life of the
world.

The keyframe goes to the pid in this zone's own subscriber map, never to a pid
the request names, and a player who is not subscribed here gets nothing. That is
what stops the frame being redirected or used to read a zone the requester is
not in.
""".
-spec resync(pid(), binary()) -> ok.
resync(Pid, PlayerId) ->
    gen_server:cast(Pid, {resync, PlayerId}).

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

-doc """
Drain everything this caller has already cast to the zone, reporting whether
the zone is still alive rather than exiting the caller if it is not.

Callers that cast to a zone and then need the cast to have landed (the join
and crossing paths in `asobi_world_server`) must not use a raw
`get_subscriber_count/1` for that: a zone reaped between the caller resolving
its pid and the drain exits the caller with `{normal, {gen_server, call, _}}`,
taking the whole world down over one player's placement
(widgrensit/asobi#283). `ok` means every earlier cast from this process was
processed; `zone_gone` means the zone died and those casts were dropped.
""".
-spec sync(pid()) -> ok | zone_gone.
sync(Pid) ->
    try
        _ = gen_server:call(Pid, get_subscriber_count),
        ok
    catch
        exit:{Reason, {gen_server, call, _}} when
            Reason =:= noproc; Reason =:= normal; Reason =:= shutdown; Reason =:= killed
        ->
            zone_gone;
        exit:{{shutdown, _}, {gen_server, call, _}} ->
            zone_gone
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

-spec init(map()) -> {ok, map(), {continue, init_zone_state}}.
init(Config) ->
    WorldId = maps:get(world_id, Config),
    Coords = maps:get(coords, Config),
    TickerPid = maps:get(ticker_pid, Config),
    GameModule = maps:get(game_module, Config),
    GameConfig = maps:get(game_config, Config, #{}),
    WorldServerPid = maps:get(world_server_pid, Config, undefined),
    ZoneState = maps:get(zone_state, Config, #{}),
    ZoneManagerPid = maps:get(zone_manager_pid, Config, undefined),
    TerrainStorePid = maps:get(terrain_store_pid, Config, undefined),
    ZoneSize = maps:get(zone_size, Config, ?DEFAULT_ZONE_SIZE),
    GridSize = maps:get(grid_size, Config, ?DEFAULT_GRID_SIZE),
    RehomeMargin = maps:get(rehome_margin, Config, ?DEFAULT_REHOME_MARGIN),
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
    {ok,
        #{
            world_id => WorldId,
            coords => Coords,
            ticker_pid => TickerPid,
            game_module => GameModule,
            game_config => GameConfig,
            world_server_pid => WorldServerPid,
            spawn_templates => Templates,
            zone_manager_pid => ZoneManagerPid,
            terrain_store_pid => TerrainStorePid,
            zone_size => ZoneSize,
            grid_size => GridSize,
            rehome_margin => RehomeMargin,
            entities => RecoveredEntities,
            prev_entities => #{},
            broadcast_entities => #{},
            broadcast_interval => maps:get(broadcast_interval, Config, 3),
            %% Counts world.tick frames this zone has BROADCAST, so a client can
            %% tell a lost or reordered frame from a quiet tick. Distinct from
            %% `tick`: the tick number skips on `broadcast_interval` and is
            %% suppressed entirely when a tick produces no deltas, so a gap in it
            %% is ambiguous between "nothing changed" and "you missed one".
            %% frame_seq has no gaps by construction.
            %%
            %% Only the shared broadcast path advances it. Per-connection frames
            %% (a join keyframe) carry the CURRENT value and never advance it, so
            %% they anchor to the shared stream rather than desynchronising every
            %% other subscriber. 53-bit ceiling, matching the inbound bound at
            %% asobi_ws_handler:world_input_seq/1: at 20 Hz that is 14 million
            %% years, so there is no wrap rule to get wrong.
            wire_seq => 0,
            %% Read once at init rather than per tick. A zone that started under
            %% one setting keeps it for its life, which is what makes the two
            %% wires consistent for every subscriber of that zone.
            binary_wire => application:get_env(asobi, binary_wire, false) =:= true,
            slots => asobi_wire_slots:new(),
            subscribers => #{},
            zone_state => ZoneState,
            input_queue => [],
            %% asobi#474: highest input seq the server has consumed per player,
            %% for clients that stamp world.input with a seq. Sent back as
            %% world.ack so a client can reconcile its prediction; pruned to the
            %% current subscribers each tick.
            player_ack => #{},
            entity_timers => asobi_entity_timer:new(),
            spawner => Spawner,
            persistence => Persistence,
            snapshot_interval => SnapshotInterval,
            spatial_grid => SpatialGrid,
            tick => 0
        },
        {continue, init_zone_state}}.

%% Build the zone's runtime state in the zone process (so a per-zone VM binds
%% to self()), regardless of how the zone was created — pre-spawned, lazy, or
%% recovered. Game modules without the callback keep their zone_state as-is.
-spec handle_continue(init_zone_state, map()) -> {noreply, map()}.
handle_continue(init_zone_state, State0) ->
    State = maybe_restore_from_snapshot(State0),
    #{
        game_module := GameMod,
        world_id := WorldId,
        coords := Coords,
        game_config := GameConfig,
        world_server_pid := WorldServerPid,
        zone_state := ZoneState
    } = State,
    ZoneConfig = #{
        world_id => WorldId,
        coords => Coords,
        game_module => GameMod,
        game_config => GameConfig,
        world_server_pid => WorldServerPid
    },
    ZoneState1 = call_optional(GameMod, init_zone_state, [ZoneConfig, ZoneState], ZoneState),
    {noreply, State#{zone_state => ZoneState1}}.

%% Lazy zones (and idle-reaped ones) start with a blank zone_state. For a
%% persistent world, recover the last snapshot here, in the zone process, so
%% the load doesn't block the zone manager. Entities recovered from the ETS
%% crash backup win (they are fresher), but zone_state/spawner/tick live only
%% in the DB snapshot, so we load it whenever zone_state is blank. A pre-spawned
%% zone arrives with a non-blank zone_state from Config and skips the DB.
%% init_zone_state then rebuilds the runtime from the restored zone_state.
-spec maybe_restore_from_snapshot(map()) -> map().
maybe_restore_from_snapshot(
    #{
        persistence := true,
        zone_state := ZoneState,
        world_id := WorldId,
        coords := Coords,
        spawn_templates := Templates
    } = State
) when map_size(ZoneState) =:= 0 ->
    case safe_load_snapshot(WorldId, Coords) of
        {ok, Snapshot} ->
            State#{
                zone_state => maps:get(zone_state, Snapshot, #{}),
                spawner => restore_spawner(maps:get(spawner_state, Snapshot, #{}), Templates),
                entity_timers => asobi_entity_timer:deserialise(
                    maps:get(entity_timers, Snapshot, #{})
                ),
                tick => restore_tick(maps:get(tick, Snapshot, 0))
            };
        not_found ->
            State;
        {error, Reason} ->
            %% A persisted zone whose snapshot we cannot read must NOT start
            %% blank and then overwrite the good row. Suppress persistence for
            %% this instance so the row survives; a later clean restart retries.
            ?LOG_ERROR(#{
                event => zone_snapshot_load_failed,
                world_id => WorldId,
                coords => Coords,
                reason => Reason
            }),
            State#{persistence => false}
    end;
maybe_restore_from_snapshot(State) ->
    State.

-spec safe_load_snapshot(binary(), {integer(), integer()}) ->
    {ok, map()} | not_found | {error, term()}.
safe_load_snapshot(WorldId, Coords) ->
    try asobi_zone_snapshotter:load_snapshot(WorldId, Coords) of
        {ok, _} = Ok -> Ok;
        {error, not_found} -> not_found;
        {error, _} = Err -> Err
    catch
        Class:Reason -> {error, {Class, Reason}}
    end.

-spec restore_spawner(map(), map()) -> asobi_zone_spawner:state().
restore_spawner(SpawnerState, Templates) when is_map(SpawnerState), map_size(SpawnerState) > 0 ->
    asobi_zone_spawner:set_templates(Templates, asobi_zone_spawner:deserialise(SpawnerState));
restore_spawner(_, Templates) ->
    asobi_zone_spawner:new(Templates).

-spec restore_tick(term()) -> non_neg_integer().
restore_tick(N) when is_integer(N), N >= 0 ->
    N;
restore_tick(Other) ->
    ?LOG_WARNING(#{event => zone_snapshot_bad_tick, value => Other}),
    0.

-spec call_optional(module(), atom(), [term()], term()) -> term().
call_optional(GameMod, Fun, Args, Default) ->
    _ = code:ensure_loaded(GameMod),
    case erlang:function_exported(GameMod, Fun, length(Args)) of
        true -> apply(GameMod, Fun, Args);
        false -> Default
    end.

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
                    {Id, entity_pos(E)}
                 || {Id, E, _Dist} <- asobi_spatial:query_radius(Entities, Center, Radius),
                    entity_pos(E) =/= undefined
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
                    {Id, entity_pos(E)}
                 || {Id, E} <- asobi_spatial:query_rect(Entities, TopLeft, BottomRight),
                    entity_pos(E) =/= undefined
                ];
            _ ->
                asobi_spatial_grid:query_rect(TopLeft, BottomRight, Grid)
        end,
    {reply, Result, State};
handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

-spec handle_cast(term(), map()) ->
    {noreply, map()} | {noreply, map(), hibernate} | {stop, normal, map()}.
handle_cast(reap, #{entities := Entities} = State) when map_size(Entities) =:= 0 ->
    %% Graceful stop so terminate/2 writes a final snapshot. Transient restart
    %% means a normal stop is not respawned.
    {stop, normal, State};
handle_cast(reap, #{zone_manager_pid := ZMPid, coords := Coords} = State) ->
    %% asobi#283: the manager decides to reap from its own zone_last_active
    %% bookkeeping, which can lag real occupancy - release_zone backdates it
    %% the moment a zone empties, and nothing re-touches it for an occupied
    %% zone with no live subscribers (this zone's own tick only touches on
    %% the map_size(Subs) > 0 branch). Trusting the cast here would tear down
    %% an occupied zone out from under its entities. This zone is the one
    %% source of truth for its own occupancy at the moment it actually
    %% receives the cast, so decline and re-touch instead of stopping.
    case ZMPid of
        undefined -> ok;
        _ -> asobi_zone_manager:touch_zone(ZMPid, Coords)
    end,
    {noreply, State};
handle_cast({tick, TickN}, State) ->
    State1 = do_tick(TickN, State),
    State2 = resolve_zone_crossings(State1),
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
handle_cast({input, PlayerId, Input, Seq}, #{input_queue := Queue} = State) ->
    {noreply, State#{input_queue => [{PlayerId, Seq, Input} | Queue]}};
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
    #{subscribers := Subs} = State
) when is_binary(PlayerId), is_pid(PlayerPid), is_map_key(PlayerId, Subs) ->
    %% Re-affirming a subscription that already holds for this pid is a no-op:
    %% callers now subscribe a crossing player to their destination zone
    %% unconditionally (widgrensit/asobi#275), so this is the common case on
    %% every crossing, not just a rare double-call. Re-monitoring here would
    %% leak the old MonRef (never demonitored) and resending the snapshot is
    %% wasted - the next tick already delivers deltas to a live subscriber.
    case maps:get(PlayerId, Subs) of
        {PlayerPid, _MonRef} ->
            {noreply, State};
        {_OldPid, OldMonRef} ->
            demonitor(OldMonRef, [flush]),
            subscribe_new(PlayerId, PlayerPid, State)
    end;
handle_cast(
    {subscribe, PlayerId, PlayerPid},
    State
) when is_binary(PlayerId), is_pid(PlayerPid) ->
    subscribe_new(PlayerId, PlayerPid, State);
handle_cast(
    {unsubscribe, PlayerId},
    #{subscribers := Subs, broadcast_entities := BroadcastEntities, coords := Coords} = State
) ->
    case maps:get(PlayerId, Subs, undefined) of
        undefined ->
            {noreply, State};
        {Pid, MonRef} ->
            demonitor(MonRef, [flush]),
            send_leave_removals(Pid, Coords, BroadcastEntities, frame_slots(State)),
            {noreply, State#{subscribers => maps:remove(PlayerId, Subs)}}
    end;
handle_cast(
    {resync, PlayerId},
    #{
        subscribers := Subs,
        broadcast_entities := BroadcastEntities,
        coords := Coords,
        wire_seq := WireSeq
    } = State
) ->
    %% Serves the pid this zone already holds for PlayerId. A request naming a
    %% zone the player is not subscribed to is dropped silently rather than
    %% answered: there is nothing to repair, and answering would turn resync into
    %% a way to read any zone in the world.
    case maps:get(PlayerId, Subs, undefined) of
        undefined ->
            ok;
        {Pid, _MonRef} ->
            send_keyframe(Pid, Coords, WireSeq, BroadcastEntities, frame_slots(State))
    end,
    {noreply, State};
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
        {error, Reason} ->
            log_spawn_failed(TemplateId, Reason, State),
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
    %% asobi#252 review: a zone that ever suppressed a log line leaves a
    %% permanent drop-count row otherwise - this Key's lifetime ends here.
    asobi_script_log_limiter:forget({WorldId, Coords}),
    pg:leave(?PG_SCOPE, {asobi_zone, WorldId, Coords}, self()),
    ok;
terminate({shutdown, _}, #{world_id := WorldId, coords := Coords} = State) ->
    maybe_final_snapshot(State),
    clear_zone_backup(WorldId, Coords),
    notify_zone_manager_terminated(State),
    asobi_script_log_limiter:forget({WorldId, Coords}),
    pg:leave(?PG_SCOPE, {asobi_zone, WorldId, Coords}, self()),
    ok;
terminate(_Reason, #{world_id := WorldId, coords := Coords, entities := Entities} = State) ->
    %% Abnormal termination — save state for recovery
    maybe_final_snapshot(State),
    backup_zone_state(WorldId, Coords, Entities),
    notify_zone_manager_terminated(State),
    asobi_script_log_limiter:forget({WorldId, Coords}),
    pg:leave(?PG_SCOPE, {asobi_zone, WorldId, Coords}, self()),
    ok.

%% --- Internal ---

-spec subscribe_new(binary(), pid(), map()) -> {noreply, map()}.
subscribe_new(
    PlayerId,
    PlayerPid,
    #{
        subscribers := Subs,
        broadcast_entities := BroadcastEntities,
        coords := Coords,
        wire_seq := WireSeq
    } = State
) ->
    MonRef = monitor(process, PlayerPid),
    send_keyframe(PlayerPid, Coords, WireSeq, BroadcastEntities, frame_slots(State)),
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
    {noreply, State#{subscribers => Subs#{PlayerId => {PlayerPid, MonRef}}}}.

%% Mirror of subscribe_new/3's keyframe, in reverse. See widgrensit/asobi#293.
%%
%% Carries `zone` but deliberately no `frame_seq`, and the client applies it
%% ungated. It is not a position in the zone's stream: it is the last thing this
%% connection hears from a zone it is leaving, and gating it behind a sequence
%% guard would let a client that was mid-gap keep a table of ghosts forever.
%% Built from `broadcast_entities` for the same reason the keyframe is - removing
%% the ids the client was actually told about, rather than the ids the zone
%% happens to hold this sim tick.
-spec send_leave_removals(
    pid(), {integer(), integer()}, map(), asobi_wire_slots:slots() | undefined
) -> ok.
send_leave_removals(_Pid, _Coords, Entities, _Slots) when map_size(Entities) =:= 0 ->
    ok;
send_leave_removals(Pid, Coords, Entities, Slots) ->
    Deltas = [{removed, Id} || Id <- maps:keys(Entities)],
    Removals = encode_deltas(Deltas),
    %% `ungated` is the binary frame's way of saying what the text frame says by
    %% omitting frame_seq: this is not a position in the zone's stream. Encoding
    %% it as sequence 0 instead would have every client past its first frame
    %% discard the one message that clears the ghosts.
    Msg =
        case encode_binary(ungated, Coords, 0, 0, false, Deltas, Slots) of
            skip -> {zone_removals, Coords, Removals};
            {ok, Bin} -> {zone_removals, Coords, Removals, Bin}
        end,
    Pid ! {asobi_message, Msg},
    ok.

%% The three fields stage 1 adds to world.tick, in one place so the shared and
%% per-connection paths cannot disagree about their shape.
%%
%% `zone` is the field that fixes the corruption bug, and it is the reason this
%% work exists: a player subscribes to an interest ring of several zones
%% (asobi_world_server:subscribe_interest_zones/4), each an independent process
%% sending to the same session pid, and Erlang orders messages per
%% sender-receiver pair only. A zone crossing emits `op:"r"` from the old zone
%% and `op:"a"` from the new one, from two different senders, so they can arrive
%% inverted - and a client applying both into one flat table then deletes the
%% entity and never hears about it again. Per-zone tables make that unreachable.
%% The client's baseline, and the one frame it adopts unconditionally.
%%
%% Built from `broadcast_entities` rather than `entities` for a reason that is
%% easy to get wrong. The delta stream diffs against `broadcast_entities`
%% (do_tick/2), which only advances on a broadcast tick, so with the default
%% `broadcast_interval` of 3 `entities` can be two sim ticks ahead of it.
%% Snapshotting `entities` hands the client a baseline AHEAD of the stream that
%% follows, and the next `op:"u"` diff never re-sends the fields that changed in
%% between - they already equal the server's own baseline, so compute_deltas/2
%% emits nothing for them and the client keeps a value it was never told to
%% expect. Anchoring both to the same map is what makes `frame_seq` mean
%% anything.
%%
%% Sent unconditionally, including for an empty zone. An empty zone still has a
%% sequence position, and a client with no keyframe has no baseline to reject a
%% stale delta against.
%%
%% The binary companion matters more here than anywhere else: the slot->id
%% bindings ride the `add` records (ADR 0013, decision 4) and a keyframe is
%% all-adds, so this is the frame that gives a binary client its whole mapping.
%% A binary client handed only the text keyframe would have no bindings at all.
-spec send_keyframe(
    pid(),
    {integer(), integer()},
    non_neg_integer(),
    map(),
    asobi_wire_slots:slots() | undefined
) -> ok.
send_keyframe(PlayerPid, Coords, WireSeq, BroadcastEntities, Slots) ->
    Snapshot = [E#{~"op" => ~"a", ~"id" => Id} || Id := E <- BroadcastEntities],
    Adds = [{added, Id, E} || Id := E <- BroadcastEntities],
    Meta = frame_meta(Coords, WireSeq, true),
    Msg =
        case encode_binary(sequenced, Coords, WireSeq, 0, true, Adds, Slots) of
            skip -> {zone_keyframe, Meta, Snapshot};
            {ok, Bin} -> {zone_keyframe, Meta, Snapshot, Bin}
        end,
    PlayerPid ! {asobi_message, Msg},
    ok.

%% Binary keys, matching broadcast_deltas/5's own payload, so the shared and
%% per-connection frames are byte-identical in shape and one merge covers both.
-spec frame_meta({integer(), integer()}, non_neg_integer(), boolean()) -> map().
frame_meta({ZX, ZY}, WireSeq, IsKeyframe) ->
    #{~"zone" => [ZX, ZY], ~"frame_seq" => WireSeq, ~"kf" => IsKeyframe}.

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
        wire_seq := WireSeq,
        zone_state := ZoneState,
        input_queue := Queue,
        subscribers := Subs,
        ticker_pid := TickerPid,
        entity_timers := ET
    } = State
) ->
    %% Run zone_tick BEFORE apply_inputs so bridges that stash per-zone state
    %% in the proc dict (e.g., asobi_lua_world) have a chance to populate it
    %% before handle_input/3 reads it. Without this swap, the very first tick
    %% on a freshly-spawned zone runs apply_inputs against an empty proc dict
    %% and the bridge silently drops every queued input. The semantic effect
    %% is that an input arrives one zone-tick later than it would have under
    %% the previous order; broadcasts still reflect this tick's input because
    %% the broadcast step runs after both.
    ZoneStateWithTick = ZoneState#{tick => TickN},
    {Entities0, ZoneState1} = GameMod:zone_tick(Entities, ZoneStateWithTick),
    %% input_queue is built newest-first via [Input | Queue], so reverse it
    %% before applying so handle_input sees inputs in arrival order. Without
    %% this, a burst of moves arriving in one tick window collapses to the
    %% OLDEST input's state — every later move gets overwritten by the
    %% next-handle_input call walking the list head-first.
    {Entities2, TickAcks} = apply_inputs(GameMod, lists:reverse(Queue), Entities0),
    PlayerAck1 = maps:fold(fun record_ack/3, maps:get(player_ack, State, #{}), TickAcks),
    Now = erlang:system_time(millisecond),
    {TimerEvents, ET1} = asobi_entity_timer:tick(Now, ET),
    Entities3 = apply_timer_events(TimerEvents, Entities2),
    %% Tick spawner — process respawn queue. asobi#253: pick up a live
    %% template update (e.g. a script hot-reload) before ticking, so a
    %% just-renamed/added template doesn't have to wait for the next respawn
    %% window to become spawnable.
    Spawner0 = maybe_apply_spawn_templates_hint(
        GameMod, ZoneState1, maps:get(spawner, State), WorldId, Coords
    ),
    {Respawns, FailedRespawns, Spawner1} = asobi_zone_spawner:tick(Now, Spawner0),
    lists:foreach(
        fun
            ({TemplateId, unknown_template = Reason}) when is_binary(TemplateId) ->
                log_spawn_failed(TemplateId, Reason, State);
            (_) ->
                ok
        end,
        FailedRespawns
    ),
    Entities4 = apply_respawns(Respawns, Entities3),
    %% Only broadcast every Nth tick to reduce network traffic
    State1 =
        case TickN rem BroadcastInterval of
            0 ->
                Deltas = compute_deltas(BroadcastEntities, Entities4),
                {FrameSlots, Slots1} = advance_slots(
                    maps:get(binary_wire, State),
                    BroadcastEntities,
                    Entities4,
                    maps:get(slots, State)
                ),
                WireSeq1 = broadcast_deltas(Coords, TickN, WireSeq, Deltas, Subs, FrameSlots),
                broadcast_acks(TickN, PlayerAck1, Subs),
                State#{
                    broadcast_entities => Entities4, wire_seq => WireSeq1, slots => Slots1
                };
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
                zone_state => call_optional(GameMod, dump_zone_state, [ZoneState1], ZoneState1),
                entity_timers => asobi_entity_timer:serialise(ET1),
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
        %% Bound player_ack to currently-subscribed players so it does not grow
        %% with everyone who ever sent an input (asobi#474).
        player_ack => maps:with(maps:keys(Subs), PlayerAck1),
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

apply_inputs(GameMod, Queue, Entities) ->
    apply_inputs(GameMod, Queue, Entities, #{}).

apply_inputs(_GameMod, [], Entities, Acks) ->
    {Entities, Acks};
apply_inputs(GameMod, [{PlayerId, Seq, Input} | Rest], Entities, Acks) ->
    %% A rejected input still advances the ack (asobi#474): the client asked the
    %% server to consume this seq and it did, it just declined the effect.
    %% Otherwise a client waits forever on an input the server chose to drop.
    Acks1 = record_ack(PlayerId, Seq, Acks),
    case GameMod:handle_input(PlayerId, Input, Entities) of
        {ok, Entities1} ->
            apply_inputs(GameMod, Rest, Entities1, Acks1);
        {error, Reason} ->
            ?LOG_WARNING(#{
                msg => ~"zone input rejected",
                player_id => PlayerId,
                reason => Reason
            }),
            apply_inputs(GameMod, Rest, Entities, Acks1)
    end.

%% Keep the highest seq per player. world.input carries a monotonic client seq;
%% out-of-order or duplicate delivery must never regress the ack. Inputs with no
%% seq (the client did not opt in) contribute nothing.
record_ack(_PlayerId, undefined, Acks) ->
    Acks;
record_ack(PlayerId, Seq, Acks) when is_integer(Seq), Seq >= 0 ->
    case Acks of
        #{PlayerId := Prev} when Prev >= Seq -> Acks;
        _ -> Acks#{PlayerId => Seq}
    end;
%% Total over Seq: player_input/4 is exported, so a caller passing a
%% spec-violating Seq must not function_clause-crash the shared zone process.
record_ack(_PlayerId, _Seq, Acks) ->
    Acks.

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

%% Returns the zone's new frame_seq, which is the ONLY place it advances.
%%
%% It advances on a frame actually sent, not on a broadcast tick. An empty delta
%% list sends nothing (the clause below), so advancing there would put a gap in
%% the sequence for a tick where nothing happened, and a gap is precisely what
%% the client treats as loss. The `tick` field cannot serve this purpose for
%% exactly that reason and is left alone: it stays the sim tick, ADR 0010 froze
%% it, and clients read it.
-spec broadcast_deltas(
    {integer(), integer()},
    non_neg_integer(),
    non_neg_integer(),
    [term()],
    map(),
    asobi_wire_slots:slots() | undefined
) -> non_neg_integer().
broadcast_deltas(_Coords, _TickN, WireSeq, [], _Subs, _FrameSlots) ->
    WireSeq;
broadcast_deltas(Coords, TickN, WireSeq, Deltas, Subs, FrameSlots) ->
    Seq = WireSeq + 1,
    EncodedDeltas = encode_deltas(Deltas),
    Meta = frame_meta(Coords, Seq, false),
    Payload = #{
        ~"type" => ~"world.tick",
        ~"payload" => Meta#{~"tick" => TickN, ~"updates" => EncodedDeltas}
    },
    PreEncoded = iolist_to_binary(json:encode(Payload)),
    RawMsg = delta_msg(
        PreEncoded, encode_binary(sequenced, Coords, Seq, TickN, false, Deltas, FrameSlots)
    ),
    maps:foreach(
        fun(_PlayerId, {Pid, _MonRef}) -> Pid ! RawMsg end,
        Subs
    ),
    Seq.

%% One shared buffer per wire in use, never one per subscriber - that is the
%% whole point of ADR 0001's encode-once fan-out and the reason both buffers
%% travel in ONE message. The connection picks; the zone does not need to know
%% who negotiated what, so no per-subscriber state and no race between
%% negotiation and subscription.
delta_msg(Json, skip) -> {asobi_message, {zone_delta_raw, Json}};
delta_msg(Json, {ok, Bin}) -> {asobi_message, {zone_delta_raw, Json, Bin}}.

%% `undefined` when the binary wire is off, so the per-connection paths do the
%% same nothing the broadcast path does rather than encoding against an empty
%% slot map and warning once per entity.
-spec frame_slots(map()) -> asobi_wire_slots:slots() | undefined.
frame_slots(#{binary_wire := true, slots := Slots}) -> Slots;
frame_slots(_State) -> undefined.

%% Slots have to cover BOTH sides of the diff for the length of one frame: a
%% removal names an entity that has already left the new baseline, so releasing
%% first would leave it slotless in the very frame that announces its departure.
%% Hence the union for the frame, then the real baseline for what the zone keeps.
-spec advance_slots(boolean(), map(), map(), asobi_wire_slots:slots()) ->
    {asobi_wire_slots:slots() | undefined, asobi_wire_slots:slots()}.
advance_slots(false, _Old, _New, Slots) ->
    {undefined, Slots};
advance_slots(true, Old, New, Slots) ->
    case asobi_wire_slots:sync(maps:merge(Old, New), Slots) of
        {ok, FrameSlots} ->
            case asobi_wire_slots:sync(New, FrameSlots) of
                {ok, Next} -> {FrameSlots, Next};
                %% Unreachable: this sync only releases relative to the one
                %% above. Handled rather than matched so an invariant break
                %% degrades to the text wire instead of killing a shared zone.
                {error, exhausted} -> {FrameSlots, FrameSlots}
            end;
        {error, exhausted} ->
            ?LOG_WARNING(#{
                msg => ~"zone slot space exhausted, binary wire disabled for this frame",
                live_entities => map_size(New)
            }),
            {undefined, Slots}
    end.

%% `skip` rather than an error: binary negotiation covers `world.tick` alone and
%% every other frame is text regardless, so a client that asked for binary can
%% always take a text frame. Falling back therefore costs bandwidth, not
%% correctness, and is the right answer when a frame cannot be encoded.
-spec encode_binary(
    sequenced | ungated,
    {integer(), integer()},
    non_neg_integer(),
    non_neg_integer(),
    boolean(),
    [term()],
    asobi_wire_slots:slots() | undefined
) -> {ok, binary()} | skip.
encode_binary(_Kind, _Coords, _Seq, _TickN, _Kf, _Deltas, undefined) ->
    skip;
encode_binary(Kind, {ZX, ZY}, Seq, TickN, Kf, Deltas, Slots) ->
    case wire_records(Deltas, Slots) of
        {ok, Records} ->
            Frame = #{
                kind => Kind,
                zone => {ZX, ZY},
                frame_seq => Seq,
                kf => Kf,
                tick => TickN,
                records => Records
            },
            case asobi_wire:encode(Frame) of
                {ok, Bin} ->
                    {ok, Bin};
                {error, Reason} ->
                    ?LOG_WARNING(#{
                        msg => ~"binary world.tick frame refused, falling back to text",
                        reason => Reason
                    }),
                    skip
            end;
        skip ->
            skip
    end.

%% Built from the delta TUPLES rather than from encode_deltas/1's JSON maps: the
%% op and the entity id are structural here and only become `~"op"`/`~"id"` keys
%% on the text wire, so re-deriving them from the encoded map would make the
%% binary wire depend on the text wire's field naming.
%% Built head-first rather than accumulated and reversed: lists:reverse/1's
%% eqWAlizer overlay erases the element type, and a list of `term()` is not a list
%% of records the encoder can be trusted with. Recursion depth is one frame's
%% delta count, which a zone's entity count already bounds.
-spec wire_records([term()], asobi_wire_slots:slots()) ->
    {ok, [asobi_wire:delta()]} | skip.
wire_records([], _Slots) ->
    {ok, []};
wire_records([Delta | Rest], Slots) ->
    case wire_record(Delta, Slots) of
        skip ->
            skip;
        {ok, Rec} ->
            case wire_records(Rest, Slots) of
                skip -> skip;
                {ok, Recs} -> {ok, [Rec | Recs]}
            end
    end.

wire_record({added, Id, FullState}, Slots) ->
    with_slot(Id, Slots, FullState, fun(Slot, Gen, Fields) ->
        #{op => add, slot => Slot, gen => Gen, id => Id, fields => Fields}
    end);
wire_record({updated, Id, Diff}, Slots) ->
    with_slot(Id, Slots, Diff, fun(Slot, Gen, Fields) ->
        #{op => update, slot => Slot, gen => Gen, fields => Fields}
    end);
wire_record({removed, Id}, Slots) ->
    with_slot(Id, Slots, #{}, fun(Slot, Gen, _Fields) ->
        #{op => remove, slot => Slot, gen => Gen}
    end).

with_slot(Id, Slots, Fields, Build) ->
    case {asobi_wire_slots:slot_of(Id, Slots), wire_encodable(Fields)} of
        {{ok, {Slot, Gen}}, true} ->
            {ok, Build(Slot, Gen, Fields)};
        {error, _} ->
            %% advance_slots/4 syncs against the union of both baselines, so
            %% every id in the diff has a slot. Missing one means the two have
            %% drifted, and a frame encoded around the gap would bind the wrong
            %% entity on a client; drop to text and say so.
            ?LOG_WARNING(#{msg => ~"entity has no wire slot, falling back to text", id => Id}),
            skip;
        {_, false} ->
            ?LOG_WARNING(#{
                msg => ~"entity field has no binary form, falling back to text", id => Id
            }),
            skip
    end.

%% asobi_wire carries six scalar value types. A game is free to put a list or a
%% nested map in an entity, and dropping such a field from the binary frame while
%% the text frame keeps it would make the two wires disagree about what an entity
%% IS. So a zone holding a non-scalar field stays on text entirely: the wires are
%% equivalent or the binary one is not used.
wire_encodable(Fields) ->
    lists:all(fun is_wire_value/1, maps:values(Fields)).

is_wire_value(V) when is_number(V); is_boolean(V); is_binary(V); V =:= null -> true;
is_wire_value(_) -> false.

%% asobi#474: input ack, addressed to one connection. Iterate the opted-in
%% players (those with a recorded seq) and send world.ack only to the ones still
%% subscribed. The mark is per zone, so a crossing player can be acked by both
%% the zone they left and the one they entered; asobi_player_session drops any
%% ack that does not advance, which is what makes the frame monotonic. Kept
%% off the shared world.tick binary so the ack never leaks one player's input
%% stream to the rest of the zone.
-spec broadcast_acks(non_neg_integer(), #{binary() => non_neg_integer()}, map()) -> ok.
broadcast_acks(TickN, PlayerAck, Subs) ->
    maps:foreach(
        fun(PlayerId, Seq) ->
            case Subs of
                #{PlayerId := {Pid, _MonRef}} ->
                    Pid ! {asobi_message, {world_ack, TickN, Seq}};
                _ ->
                    ok
            end
        end,
        PlayerAck
    ).

encode_deltas(Deltas) ->
    [encode_delta(D) || D <- Deltas].

encode_delta({updated, Id, Diff}) ->
    Diff#{~"op" => ~"u", ~"id" => Id};
encode_delta({added, Id, FullState}) ->
    FullState#{~"op" => ~"a", ~"id" => Id};
encode_delta({removed, Id}) ->
    #{~"op" => ~"r", ~"id" => Id}.

%% --- Zone Crossing ---

%% Called after every tick, once entity positions for this tick are final.
%% NPCs are transferred directly (asobi_zone owns them outright). Players
%% can't be: only asobi_world_server can move a session's subscriptions and
%% zone_pid, so those are handed off via move_player/4 instead. See
%% widgrensit/asobi#248.
resolve_zone_crossings(
    #{
        entities := Entities,
        coords := Coords,
        zone_size := ZoneSize,
        grid_size := GridSize,
        rehome_margin := RehomeMargin,
        world_server_pid := WorldServerPid
    } = State
) ->
    {ToRemove, ToTransfer, ToRehome} = find_zone_crossings(
        Entities, Coords, ZoneSize, GridSize, RehomeMargin
    ),
    %% Transfer each NPC to the target zone. An NPC whose target zone can't be
    %% reached is kept here (clamped), never deleted - see transfer_npcs/2.
    KeptNpcs = transfer_npcs(ToTransfer, State),
    %% Hand each player off to move_player/4 rather than writing them into the
    %% target zone directly - handle_move/4 (via remove_player_from_zones/2)
    %% is what actually removes them from this zone, re-subscribes their
    %% interest ring and re-points their session's zone_pid. move_player/4 is
    %% a cast: it always returns ok whether or not the world server has a
    %% player_zones entry for this id, so that can't be used to decide
    %% whether to delete the entity here. Deleting it unconditionally instead
    %% destroyed any non-NPC entity a game script keeps as type "player"
    %% (bots, decoys, ...) that the world server has never joined - it now
    %% simply stays here, exactly as it did before this fix, until something
    %% actually claims it. See widgrensit/asobi#248.
    %%
    %% A rate-limited crossing is denied here (WorldServerPid never learns
    %% about it), but denying the hand-off alone would leave the entity's raw
    %% x/y outside this zone's own rectangle while this zone keeps owning it -
    %% security review measured that divergence running over a second at a
    %% time under sustained denial, with the entity invisible to
    %% query_radius/3 and query_rect/3 callers at its true position and this
    %% zone re-detecting the same crossing (and re-denying it) every tick.
    %% Clamping the denied entity back inside Coords closes the divergence:
    %% once input stops, the position is self-consistent with Coords again.
    %% Under sustained input the crossing is still re-detected (and
    %% re-denied) every tick - clamping does not stop that - but each denied
    %% tick now costs no hand-off, no ring diff and no terrain-store call,
    %% only this cheap re-clamp.
    DeniedEntities =
        case WorldServerPid of
            undefined ->
                #{};
            _ ->
                Results = [
                    rehome_or_clamp(WorldServerPid, Id, Pos, Entity, Coords, ZoneSize)
                 || {Id, {X, Y} = Pos, Entity} <- ToRehome,
                    is_binary(Id),
                    is_number(X),
                    is_number(Y),
                    is_map(Entity)
                ],
                maps:from_list([R || R <- Results, R =/= moved])
        end,
    %% Remove transferred NPCs and rehomed players from this zone; a denied
    %% player and an NPC whose target zone was unreachable are kept, clamped
    %% back inside these bounds.
    Kept = maps:merge(DeniedEntities, KeptNpcs),
    Entities1 = maps:merge(maps:without(ToRemove, Entities), Kept),
    Grid = maps:get(spatial_grid, State, undefined),
    Grid1 = remove_from_grid(ToRemove, Grid),
    %% query_radius/3 and query_rect/3 read positions from this grid, not
    %% Entities1, when spatial_grid_cell_size is configured - without
    %% re-indexing here, a denied entity's clamp is invisible to both and
    %% they keep answering with its out-of-zone position: exactly the
    %% divergence clamping exists to close. See widgrensit/asobi#248.
    Grid2 = reindex_clamped(maps:to_list(Kept), Grid1),
    State#{entities => Entities1, spatial_grid => Grid2}.

%% A player crossing into an unloaded zone gets it created for them
%% (asobi_world_server:handle_move/4 calls ensure_zone/2 before it moves
%% anyone), so under lazy_zones - where an unloaded neighbour is the normal
%% state - an NPC crossing the same boundary must not simply cease to exist.
%% Same ordering as asobi#258: resolve the target first, and if it can't be
%% resolved the crossing is a no-op, with the NPC clamped back inside this
%% zone exactly as a rate-limited player is. Returns the NPCs to keep here.
%%
%% pg is tried first so the common case (target already loaded) stays a
%% local ETS read; only a real miss pays a call to the zone manager, and
%% that call is bounded so a busy manager costs this tick's crossing rather
%% than stalling the whole zone's tick loop.
-spec transfer_npcs([{binary(), {integer(), integer()}, map()}], map()) -> #{binary() => map()}.
transfer_npcs(ToTransfer, State) ->
    Results = [
        transfer_npc(Id, TargetCoords, Entity, State)
     || {Id, {TX, TY} = TargetCoords, Entity} <- ToTransfer,
        is_binary(Id),
        is_integer(TX),
        is_integer(TY)
    ],
    maps:from_list([R || R <- Results, R =/= transferred]).

-spec transfer_npc(binary(), {integer(), integer()}, map(), map()) ->
    transferred | {binary(), map()}.
transfer_npc(Id, TargetCoords, Entity, State) ->
    #{world_id := WorldId, coords := Coords, zone_size := ZoneSize} = State,
    case target_zone_pid(TargetCoords, State) of
        {ok, TargetPid} ->
            gen_server:cast(TargetPid, {add_entity, Id, Entity}),
            transferred;
        {error, Reason} ->
            log_npc_transfer_unavailable(WorldId, Id, TargetCoords, Reason),
            {Id, clamp_to_zone(Entity, Coords, ZoneSize)}
    end.

-spec target_zone_pid({integer(), integer()}, map()) -> {ok, pid()} | {error, term()}.
target_zone_pid(TargetCoords, #{world_id := WorldId} = State) ->
    case pg:get_members(?PG_SCOPE, {asobi_zone, WorldId, TargetCoords}) of
        [TargetPid | _] ->
            {ok, TargetPid};
        [] ->
            ensure_target_zone(TargetCoords, State)
    end.

-spec ensure_target_zone({integer(), integer()}, map()) -> {ok, pid()} | {error, term()}.
ensure_target_zone(_TargetCoords, #{zone_manager_pid := undefined}) ->
    {error, no_zone_manager};
ensure_target_zone(TargetCoords, #{zone_manager_pid := ZMPid, world_server_pid := WSPid}) ->
    try asobi_zone_manager:ensure_zone(ZMPid, TargetCoords, ?ENSURE_ZONE_TIMEOUT) of
        {ok, TargetPid, created} ->
            notify_zone_created(WSPid, TargetCoords, TargetPid),
            {ok, TargetPid};
        {ok, TargetPid, existing} ->
            {ok, TargetPid};
        {error, _} = Err ->
            Err
    catch
        %% A manager that is overloaded, restarting or gone must not take the
        %% zone down with it - the NPC stays here instead.
        Class:Reason ->
            {error, {Class, Reason}}
    end.

-spec notify_zone_created(pid() | undefined, {integer(), integer()}, pid()) -> ok.
notify_zone_created(undefined, _Coords, _ZonePid) ->
    ok;
notify_zone_created(WSPid, Coords, ZonePid) ->
    asobi_world_server:zone_created(WSPid, Coords, ZonePid).

-spec reindex_clamped([{binary(), map()}], asobi_spatial_grid:grid() | undefined) ->
    asobi_spatial_grid:grid() | undefined.
reindex_clamped(_DeniedList, undefined) ->
    undefined;
reindex_clamped([], Grid) ->
    Grid;
reindex_clamped([{Id, Entity} | Rest], Grid) when is_map(Entity) ->
    case entity_pos(Entity) of
        undefined -> reindex_clamped(Rest, Grid);
        Pos -> reindex_clamped(Rest, asobi_spatial_grid:update(Id, Pos, Grid))
    end;
reindex_clamped([_ | Rest], Grid) ->
    reindex_clamped(Rest, Grid).

%% Attempts the hand-off; returns `moved` (caller does nothing further) or
%% `{Id, ClampedEntity}` for a denied crossing (caller keeps the entity here).
-spec rehome_or_clamp(
    pid(), binary(), {number(), number()}, map(), {integer(), integer()}, pos_integer()
) ->
    moved | {binary(), map()}.
rehome_or_clamp(WorldServerPid, Id, Pos, Entity, Coords, ZoneSize) ->
    %% Backstop under the crossing hysteresis: a client that still manages to
    %% force repeated re-homes (a modified client skipping the margin, or
    %% plain jitter at the wrong instant) gets denied rather than paying for
    %% a fresh interest-ring diff and zone snapshot resend every tick.
    case asobi_rehome_limiter:allow(Id) of
        true ->
            asobi_world_server:move_player(WorldServerPid, Id, Pos, Entity),
            moved;
        false ->
            asobi_telemetry:rehome_rate_limited(Id),
            {Id, clamp_to_zone(Entity, Coords, ZoneSize)}
    end.

%% Pulls a denied entity's x/y back inside the zone rectangle Coords owns, so
%% the position this zone broadcasts never disagrees with the zone that owns
%% it. Epsilon keeps the clamped point strictly inside (at the exact upper
%% edge, pos_to_zone/3 would compute the next zone over again).
-spec clamp_to_zone(map(), {integer(), integer()}, pos_integer()) -> map().
clamp_to_zone(Entity, {ZX, ZY}, ZoneSize) ->
    case entity_pos(Entity) of
        undefined ->
            Entity;
        {X, Y} ->
            Eps = 1.0e-6,
            XLo = ZX * ZoneSize * 1.0,
            YLo = ZY * ZoneSize * 1.0,
            entity_with_pos(
                Entity,
                min(max(X, XLo), XLo + ZoneSize - Eps),
                min(max(Y, YLo), YLo + ZoneSize - Eps)
            )
    end.

%% Explicit -spec so eqwalizer treats ToRehome's element type as ground truth
%% at the move_player/4 call site above, rather than inferring term() through
%% the fold's multi-branch accumulator.
-spec find_zone_crossings(map(), {integer(), integer()}, pos_integer(), pos_integer(), number()) ->
    {[binary()], [{binary(), {integer(), integer()}, map()}], [
        {binary(), {number(), number()}, map()}
    ]}.
find_zone_crossings(Entities, Coords, ZoneSize, GridSize, RehomeMargin) ->
    maps:fold(
        fun(Id, Entity, Acc) ->
            fold_crossing(Id, Entity, Acc, {Coords, ZoneSize, GridSize, RehomeMargin})
        end,
        {[], [], []},
        Entities
    ).

-spec fold_crossing(
    term(),
    term(),
    Acc,
    {{integer(), integer()}, pos_integer(), pos_integer(), number()}
) -> Acc when
    Acc ::
        {[binary()], [{binary(), {integer(), integer()}, map()}], [
            {binary(), {number(), number()}, map()}
        ]}.
fold_crossing(Id, Entity, {Rem, Trans, Rehome} = Acc, {Coords, ZoneSize, GridSize, Margin}) when
    is_binary(Id), is_map(Entity)
->
    case {entity_type(Entity, ~"unknown"), entity_pos(Entity)} of
        {~"npc", {_, _} = Pos} ->
            case classify_crossing(Pos, Coords, ZoneSize, GridSize, Margin) of
                same -> Acc;
                {crossed, NewCoords} -> {[Id | Rem], [{Id, NewCoords, Entity} | Trans], Rehome}
            end;
        {~"player", {_, _} = Pos} ->
            case classify_crossing(Pos, Coords, ZoneSize, GridSize, Margin) of
                same -> Acc;
                {crossed, _NewCoords} -> {Rem, Trans, [{Id, Pos, Entity} | Rehome]}
            end;
        _ ->
            Acc
    end;
fold_crossing(_Id, _Entity, Acc, _Cfg) ->
    Acc.

%% Entity maps are game-supplied data. An Erlang game module hands the zone
%% atom keys, but the Lua bridge decodes Luerl tables straight into
%% binary-keyed maps, so every entity field the zone reads has to accept
%% both shapes - otherwise re-homing, NPC transfer, snapshotting and grid
%% indexing are all silently inert for a Lua world. See widgrensit/asobi#269.
-spec entity_pos(map()) -> {number(), number()} | undefined.
entity_pos(#{x := X, y := Y}) when is_number(X), is_number(Y) ->
    {X, Y};
entity_pos(#{~"x" := X, ~"y" := Y}) when is_number(X), is_number(Y) ->
    {X, Y};
entity_pos(_Entity) ->
    undefined.

-spec entity_with_pos(map(), number(), number()) -> map().
entity_with_pos(#{x := _, y := _} = Entity, X, Y) -> Entity#{x => X, y => Y};
entity_with_pos(Entity, X, Y) -> Entity#{~"x" => X, ~"y" => Y}.

-spec entity_type(map(), binary()) -> binary().
entity_type(#{type := Type}, _Default) when is_binary(Type) -> Type;
entity_type(#{~"type" := Type}, _Default) when is_binary(Type) -> Type;
entity_type(_Entity, Default) -> Default.

-spec entity_persistent(map()) -> boolean().
entity_persistent(#{persistent := P}) when is_boolean(P) -> P;
entity_persistent(#{~"persistent" := P}) when is_boolean(P) -> P;
entity_persistent(_Entity) -> true.

%% Hysteresis: pos_to_zone/3 disagreeing with Coords alone is a hard edge
%% with zero margin, so an entity jittering across a boundary crosses every
%% tick it does - for a player a full ring diff, snapshot resend and
%% zone_pid flip. Require ZoneSize * RehomeMargin of clearance first, for
%% both entity types. This is a jitter filter, not a rate limit - see
%% asobi_rehome_limiter for that. widgrensit/asobi#248.
-spec classify_crossing(
    {number(), number()}, {integer(), integer()}, pos_integer(), pos_integer(), number()
) ->
    same | {crossed, {integer(), integer()}}.
classify_crossing({X, Y}, Coords, ZoneSize, GridSize, RehomeMargin) ->
    case asobi_world_server:pos_to_zone({X, Y}, ZoneSize, GridSize) of
        Coords ->
            same;
        NewCoords ->
            case past_zone_margin({X, Y}, Coords, ZoneSize, RehomeMargin) of
                true -> {crossed, NewCoords};
                false -> same
            end
    end.

-spec past_zone_margin({number(), number()}, {integer(), integer()}, pos_integer(), number()) ->
    boolean().
past_zone_margin({X, Y}, {ZX, ZY}, ZoneSize, RehomeMargin) ->
    Margin = ZoneSize * RehomeMargin,
    XLo = ZX * ZoneSize,
    YLo = ZY * ZoneSize,
    X < XLo - Margin orelse X >= XLo + ZoneSize + Margin orelse
        Y < YLo - Margin orelse Y >= YLo + ZoneSize + Margin.

%% --- Snapshot Helpers ---

snapshot_entities(Entities) ->
    maps:filter(
        fun(_Id, E) ->
            entity_type(E, ~"unknown") =/= ~"player" andalso
                entity_persistent(E)
        end,
        Entities
    ).

maybe_final_snapshot(#{persistence := true} = State) ->
    #{
        world_id := WorldId,
        coords := Coords,
        game_module := GameMod,
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
            zone_state => call_optional(GameMod, dump_zone_state, [ZoneState], ZoneState),
            entity_timers => asobi_entity_timer:serialise(ET),
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
    asobi_zone_manager:zone_terminated(ZMPid, Coords, self());
notify_zone_manager_terminated(_) ->
    ok.

has_tickable_entities(Entities) ->
    maps:fold(
        fun
            (_, E, Acc) when is_map(E) -> Acc orelse entity_type(E, ~"unknown") =:= ~"npc";
            (_, _, Acc) -> Acc
        end,
        false,
        Entities
    ).

%% asobi#253: spawn_templates/1 is only ever called once, at zone creation -
%% a long-running zone never learns about a template added/renamed by a
%% later script hot-reload, so it surfaces as unknown_spawn_template
%% indefinitely rather than just until the next reload. spawn_templates_hint/1
%% is optional and runs every tick, so it must be cheap when nothing
%% changed - the callback owns that cost, not this call site.
-spec maybe_apply_spawn_templates_hint(
    module(), term(), asobi_zone_spawner:state(), binary(), {integer(), integer()}
) -> asobi_zone_spawner:state().
maybe_apply_spawn_templates_hint(GameMod, ZoneState, Spawner, WorldId, Coords) ->
    case erlang:function_exported(GameMod, spawn_templates_hint, 1) of
        false ->
            Spawner;
        true ->
            case GameMod:spawn_templates_hint(ZoneState) of
                {changed, NewTemplates} when is_map(NewTemplates) ->
                    ?LOG_NOTICE(#{
                        event => zone_spawn_templates_updated,
                        world_id => WorldId,
                        coords => Coords,
                        template_count => map_size(NewTemplates)
                    }),
                    asobi_zone_spawner:set_templates(NewTemplates, Spawner);
                unchanged ->
                    Spawner;
                Other ->
                    %% A malformed callback return (anything but `unchanged` or
                    %% a well-formed `{changed, Map}`) is a bug in the game
                    %% module's implementation, not a normal "nothing changed"
                    %% outcome - surface it rather than silently no-op like the
                    %% expected `unchanged` case does.
                    ?LOG_WARNING(#{
                        event => zone_spawn_templates_hint_malformed,
                        world_id => WorldId,
                        coords => Coords,
                        game_module => GameMod,
                        returned => bound_debug_term(Other)
                    }),
                    Spawner
            end
    end.

%% asobi_zone_spawner:spawn_entity/4's only error today is unknown_template.
%% The cast API (game.zone.spawn and world-server spawn_at) can't return this
%% synchronously to the caller, so this is the only place it becomes
%% observable - without it, a bad template_id silently spawned nothing with
%% zero signal (asobi#246/#247).
-spec log_spawn_failed(binary(), unknown_template, map()) -> ok.
log_spawn_failed(TemplateId, Reason, #{world_id := WorldId, coords := Coords}) ->
    %% Caller-supplied (a Lua script can pass player input straight through
    %% to game.zone.spawn); game_error/2 requires bounded details.
    Id = bound_template_id(TemplateId),
    %% asobi#252: a tick-loop script with a typo'd template_id logs once per
    %% tick forever. The telemetry counter stays unconditional so dashboards
    %% see the true rate; only the log line itself is rate-limited per zone.
    case asobi_script_log_limiter:allow({WorldId, Coords}) of
        {true, DroppedSinceLastLog} ->
            ?LOG_WARNING(#{
                event => zone_spawn_failed,
                world_id => WorldId,
                coords => Coords,
                template_id => Id,
                reason => Reason,
                suppressed_since_last => DroppedSinceLastLog
            });
        false ->
            ok
    end,
    asobi_telemetry:game_error(unknown_spawn_template, #{
        world_id => WorldId,
        template_id => Id
    }).

%% An NPC whose target zone could not be reached or created stays in this
%% zone (widgrensit/asobi#271); the denied crossing is still reported the way
%% asobi#251 reports a failed spawn. This runs from the per-tick crossing
%% check, so an NPC parked against an unreachable neighbour would otherwise
%% log once per tick forever (asobi#252) - only the log line is rate-limited,
%% the telemetry counter stays unconditional.
-spec log_npc_transfer_unavailable(binary(), binary(), {integer(), integer()}, term()) -> ok.
log_npc_transfer_unavailable(WorldId, Id, TargetCoords, Reason) ->
    case asobi_script_log_limiter:allow({WorldId, TargetCoords}) of
        {true, DroppedSinceLastLog} ->
            ?LOG_WARNING(#{
                event => npc_transfer_zone_unavailable,
                world_id => WorldId,
                entity_id => Id,
                coords => TargetCoords,
                reason => Reason,
                suppressed_since_last => DroppedSinceLastLog
            });
        false ->
            ok
    end,
    asobi_telemetry:game_error(zone_unavailable, #{
        world_id => WorldId, coords => TargetCoords, entity_id => Id, reason => Reason
    }).

%% A byte-length cut alone can land mid-codepoint, and the result is exported
%% verbatim to a JSON log formatter (nova_jsonlogger) and every telemetry
%% handler - an invalid-UTF8 template_id must not raise there. Re-validate
%% after truncating and take whichever prefix unicode:characters_to_binary/1
%% says is actually well-formed (possibly empty, never invalid).
-spec bound_template_id(binary()) -> binary().
bound_template_id(TemplateId) ->
    Head = binary:part(TemplateId, 0, min(64, byte_size(TemplateId))),
    case unicode:characters_to_binary(Head) of
        Valid when is_binary(Valid) -> Valid;
        {incomplete, Valid, _} -> Valid;
        {error, Valid, _} -> Valid
    end.

%% A malformed spawn_templates_hint/1 return can be an arbitrary Erlang term
%% (the callback is game-module code, not asobi's own); ~p-format it before
%% logging so nova_jsonlogger's JSON encoder always sees a plain, bounded
%% binary rather than a raw pid/reference/fun it cannot encode.
-spec bound_debug_term(term()) -> binary().
bound_debug_term(Term) ->
    Formatted = iolist_to_binary(io_lib:format("~0p", [Term])),
    Head = binary:part(Formatted, 0, min(200, byte_size(Formatted))),
    case unicode:characters_to_binary(Head) of
        Valid when is_binary(Valid) -> Valid;
        {incomplete, Valid, _} -> Valid;
        {error, Valid, _} -> Valid
    end.

%% --- Spatial Grid Helpers ---

spatial_grid_insert(_EntityId, _EntityState, undefined) ->
    undefined;
spatial_grid_insert(EntityId, EntityState, Grid) when is_map(EntityState) ->
    case entity_pos(EntityState) of
        undefined -> Grid;
        Pos -> asobi_spatial_grid:insert(EntityId, Pos, Grid)
    end;
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
            {error, Reason} ->
                log_spawn_failed(TemplateId, Reason, State),
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
            (Id, Entity, G) when is_map(Entity) ->
                case entity_pos(Entity) of
                    undefined ->
                        G;
                    Pos ->
                        case maps:find(Id, OldEntities) of
                            {ok, Old} when is_map(Old) ->
                                case entity_pos(Old) of
                                    Pos -> G;
                                    _ -> asobi_spatial_grid:update(Id, Pos, G)
                                end;
                            _ ->
                                asobi_spatial_grid:update(Id, Pos, G)
                        end
                end;
            (_Id, _Entity, G) ->
                G
        end,
        Grid1,
        NewEntities
    ).
