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
-export([apply_effect/3, whereis_zone/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_continue/2, handle_info/2, terminate/2]).
-ifdef(TEST).
-export([shape_of/1]).
-export([past_zone_margin/4, classify_crossing/5]).
-export([log_refusal/6, distinct_field_names/1, widest_entity/1]).
-endif.

-include_lib("kernel/include/logger.hrl").
-include("asobi_ack.hrl").

-define(PG_SCOPE, nova_scope).
%% Must match asobi_world_server's own defaults of the same name.
-define(DEFAULT_ZONE_SIZE, 200).
-define(DEFAULT_GRID_SIZE, 10).
-define(DEFAULT_REHOME_MARGIN, 0.15).
%% Fraction of `zone_size` a zone mirrors into `asobi_zone_border` for its
%% neighbours to read. **Off by default**, because publishing costs every world
%% a filter plus a copy of the band into ETS on every tick whether or not
%% anything reads it. `guides/world-server.md` carries the measured figure and
%% the reasoning; it is not repeated here so there is only one copy of it to
%% drift. ?DEFAULT_REHOME_MARGIN is the value to reach for when turning it on.
-define(DEFAULT_BORDER_BAND, 0).
%% A fraction, so anything outside [0, 1] is a typo rather than an intent. The
%% Lua config path already refuses one (asobi_lua_config:maybe_add_fraction/3);
%% an Erlang-declared game mode reaches asobi_game_modes:forward_optional/3
%% unvalidated, and `border_band => 50` would put every entity in the zone
%% inside the band and copy the whole map into ETS every tick.
-define(MAX_BORDER_BAND, 1).
%% Cross-zone effects a zone will hold for one tick, by count and by size. The
%% queue is drained every tick, so this only bites when a neighbour is casting
%% faster than this zone ticks - which is a script fault, not traffic.
%%
%% Both bounds, because a count alone bounds nothing that matters: 256 entries
%% of an arbitrary Lua table is an arbitrary number of megabytes on this
%% process's heap. The sender is bounded too and more tightly
%% (`asobi_lua_api:effect_within_budget/1`), which is the bound that protects
%% the *mailbox*; this one protects the queue behind it, and holds for an
%% Erlang game module calling `apply_effect/3` directly, which no sender-side
%% budget covers.
-define(MAX_EFFECT_QUEUE, 256).
-define(MAX_EFFECT_BYTES_QUEUED, 1_048_576).
%% Bound on the per-tick zone-manager call an NPC crossing into an unloaded
%% neighbour makes (widgrensit/asobi#271). The manager's own work there is
%% an ETS lookup plus a supervisor:start_child (the new zone's snapshot load
%% happens in its handle_continue, off the manager), so exceeding this means
%% the manager is saturated - in which case the NPC waits in this zone for a
%% later tick rather than the zone stalling behind a 5s gen_server default.
-define(ENSURE_ZONE_TIMEOUT, 1_000).
%% How long a zone stays on the text wire before trying the binary one again, and
%% the ceiling the doubling stops at. Read from the environment at zone start so a
%% deployment whose games legitimately produce short-lived unencodable entities can
%% ask sooner, and a test can ask immediately.
-define(WIRE_RETRY_MS, 60_000).
-define(WIRE_RETRY_MAX_MS, 3_600_000).

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

-doc """
The pid currently serving `Coords` in `WorldId`, if one is running.

Deliberately never creates the zone, unlike the crossing path's
`target_zone_pid/2`: this answers "who owns what I can already see", and a
coordinate with no live zone has nothing in the border mirror to have seen.
""".
-spec whereis_zone(binary(), {integer(), integer()}) -> {ok, pid()} | error.
whereis_zone(WorldId, Coords) ->
    case pg:get_members(?PG_SCOPE, {asobi_zone, WorldId, Coords}) of
        [Pid | _] when is_pid(Pid) -> {ok, Pid};
        _ -> error
    end.

-doc """
Deliver `Event` to `EntityId`, which this zone owns.

The point of it is what it does *not* do: the caller never touches the entity.
A zone that can see a neighbour's entity through `asobi_zone_border` can ask
the owning zone to act on it, and the owning zone applies it in its own tick,
in order, under its own script. That keeps single-writer ownership intact
while still letting a projectile resolved in one zone hit a target in the
next - the case `guides/world-server.md` documents as impossible today
(widgrensit/asobi#544).
""".
-spec apply_effect(pid(), binary(), map()) -> ok.
apply_effect(Pid, EntityId, Event) when is_binary(EntityId), is_map(Event) ->
    gen_server:cast(Pid, {entity_effect, EntityId, Event}).

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
    BorderBand = clamp_border_band(maps:get(border_band, Config, ?DEFAULT_BORDER_BAND)),
    BorderTab = maps:get(border_tab, Config, undefined),
    %% terminate/2 is where this zone writes its final snapshot, clears its ETS
    %% crash backup, forgets its rate-limiter keys and drops its border row.
    %% None of that ran on a supervisor shutdown - which is to say on world
    %% teardown, the one time a final snapshot is the whole point - because a
    %% gen_server that does not trap exits is killed outright by the shutdown
    %% signal. Paired with `shutdown => 5000` on the child spec in
    %% asobi_zone_sup, without which the supervisor would brutal-kill it anyway.
    process_flag(trap_exit, true),
    pg:join(?PG_SCOPE, {asobi_zone, WorldId, Coords}, self()),
    %% Reclaim whatever the previous incarnation of this zone left behind. This
    %% gen_server does not trap exits, so `terminate/2` does not run on a
    %% supervisor shutdown, a linked crash or a `one_for_all` sibling restart -
    %% and `border_live => false` below means the restarted zone would otherwise
    %% never delete the row it inherited, leaving neighbours seeing a dead entity
    %% at its death position for as long as the world lasts.
    asobi_zone_border:clear(maps:get(border_tab, Config, undefined), Coords),
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
            %% The manager's stamp table, when this zone was started by one.
            %% See touch_manager/1.
            zone_stamp_tab => maps:get(zone_stamp_tab, Config, undefined),
            terrain_store_pid => TerrainStorePid,
            zone_size => ZoneSize,
            grid_size => GridSize,
            rehome_margin => RehomeMargin,
            %% In world units, resolved once here rather than per tick, so a
            %% zone publishes the same band for its whole life even if the
            %% config map is rebuilt under it.
            border_band => BorderBand * ZoneSize,
            border_tab => BorderTab,
            %% Whether this zone currently has a row in asobi_zone_border, so a
            %% zone that has published nothing never pays a delete.
            border_live => false,
            %% Effects other zones have addressed at entities this zone owns,
            %% newest-first like input_queue and reversed at drain.
            effect_queue => [],
            %% Counted rather than measured with length/1: the cap is checked on
            %% every inbound effect cast, so an O(n) check would be O(n^2) per
            %% tick exactly when the queue is under pressure.
            effect_count => 0,
            effect_bytes => 0,
            %% Counted rather than reported per message: unlike every other
            %% game_error kind, this one's rate is set by another process's send
            %% loop, so a telemetry fan-out per dropped cast would make the
            %% drop path more expensive for the victim than the accept path -
            %% which inverts the point of a cap. Emitted once per tick instead.
            effect_dropped => 0,
            %% zone_tick/2's last third return value. Starts false: the zone has
            %% not ticked, so the game has not claimed anything.
            script_busy => false,
            %% A zone with nothing to simulate is demoted to the ticker's cold
            %% set, which runs it once every `cold_tick_divisor` ticks instead
            %% of every tick (widgrensit/asobi#543). Starts hot: the zone has
            %% not ticked yet, so it has not established that it is idle.
            cold => false,
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
            %% Read once at init, like binary_wire. `disabled` unless a game has
            %% described its transform fields, because guessing a scale for a
            %% world of unknown size is worse than not doing this at all.
            pose_manifest => asobi_dgram_pose:manifest(),
            %% Counts pose datagrams this zone has emitted, so a client can tell
            %% a lost one from a quiet tick. Independent of wire_seq: the two
            %% carriers lose frames independently and sharing a counter would
            %% make each look like it had gaps the other caused.
            pose_seq => 0,
            %% Read once at init rather than per tick, so a zone that started
            %% under one setting keeps it, which is what makes the two wires
            %% consistent for every subscriber. It can still be turned OFF for
            %% this zone's life by `latch_to_text/5` when the encoder proves it
            %% cannot express this game's entities; it is never turned on.
            binary_wire => application:get_env(asobi, binary_wire, false) =:= true,
            slots => asobi_wire_slots:new(),
            %% Set when a frame was refused and sent as text, which leaves every
            %% binary client without the slot bindings that frame's `add` records
            %% carried (ADR 0013, decision 4). The next binary frame is then a
            %% KEYFRAME rather than a delta, which re-establishes the whole
            %% mapping - decision 4's own stated repair. If that keyframe is
            %% refused too the cause is structural rather than passing, and the
            %% zone latches to the text wire for its life (`binary_wire` below).
            %%
            %% Without this an entity introduced by a text frame is not merely
            %% off the datagram plane: the next successful binary frame carries
            %% `op:"u"` for a slot the client never bound, so the update is
            %% dropped there and the entity is stale on BOTH carriers, with a
            %% contiguous `frame_seq` that gives the client no reason to resync
            %% (asobi#510).
            wire_rebind => false,
            %% `at` is when to try the binary wire again, or `undefined` for "not
            %% latched". The backoff doubles on each failed retry (latch_to_text/5).
            wire_retry => #{
                at => undefined,
                backoff => application:get_env(asobi, binary_wire_retry_ms, ?WIRE_RETRY_MS)
            },
            %% Throttle state for the refusal warning. A zone holding one
            %% entity the encoder cannot take refuses every frame, which at 20
            %% Hz is a warning five times a second for the life of the zone.
            %% `undefined` rather than 0 because the clock is monotonic and can
            %% start negative, which would make the first refusal look recent.
            wire_log => #{logged_at => undefined, suppressed => 0},
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
        world_server_pid => WorldServerPid,
        %% The neighbour-facing game.* calls need the same grid geometry the
        %% zone itself decides crossings with, or a script's idea of which
        %% zones touch it disagrees with asobi's (widgrensit/asobi#544).
        zone_size => maps:get(zone_size, State),
        grid_size => maps:get(grid_size, State),
        border_tab => maps:get(border_tab, State, undefined)
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
handle_cast(reap, #{entities := Entities, script_busy := true} = State) when
    map_size(Entities) =:= 0
->
    %% "This zone has work" has to mean it is not torn down, or a wave spawner
    %% counting down between waves is reaped mid-countdown at
    %% `zone_idle_timeout` and the wave never comes. Declined the same way an
    %% occupied zone declines below.
    touch_manager(State),
    {noreply, State};
%% A watched zone is in use even with nothing in it. This was already true in
%% effect - an empty zone with subscribers re-stamps itself active on the
%% `map_size(Subs) > 0` branch of every tick, so the reap cast never arrived -
%% but it was emergent rather than stated, and at `cold_tick_divisor = 0` the
%% zone stops ticking and stops stamping (widgrensit/asobi#561). Reaping it
%% then would tear it out from under subscribers who are not re-subscribed
%% until they next move, so they would silently stop seeing anything that
%% happens there.
handle_cast(reap, #{entities := Entities, subscribers := Subs} = State) when
    map_size(Entities) =:= 0, map_size(Subs) > 0
->
    touch_manager(State),
    {noreply, State};
handle_cast(reap, #{entities := Entities} = State) when map_size(Entities) =:= 0 ->
    %% Graceful stop so terminate/2 writes a final snapshot. Transient restart
    %% means a normal stop is not respawned.
    {stop, normal, State};
handle_cast(reap, State) ->
    %% asobi#283: the manager decides to reap from its own last-active
    %% bookkeeping, which can lag real occupancy - release_zone backdates it
    %% the moment a zone empties, and nothing re-touches it for an occupied
    %% zone with no live subscribers (this zone's own tick only touches on
    %% the map_size(Subs) > 0 branch). Trusting the cast here would tear down
    %% an occupied zone out from under its entities. This zone is the one
    %% source of truth for its own occupancy at the moment it actually
    %% receives the cast, so decline and re-touch instead of stopping.
    touch_manager(State),
    {noreply, State};
handle_cast({tick, TickN}, State) ->
    State1 = do_tick(TickN, State),
    State2 = publish_border(resolve_zone_crossings(State1)),
    State3 = reclassify(State2),
    #{subscribers := Subs, entities := Ents} = State3,
    case map_size(Subs) of
        0 ->
            %% A zone that says it is busy is not idle between its ticks, so
            %% hibernating it would pay a full-sweep GC of the whole Luerl state
            %% at tick rate - more per tick than an occupied zone costs.
            case has_tickable_entities(Ents) orelse maps:get(script_busy, State3, false) of
                false -> {noreply, State3, hibernate};
                true -> {noreply, State3}
            end;
        _ ->
            touch_manager(State3),
            {noreply, State3}
    end;
handle_cast({input, PlayerId, Input, Seq}, #{input_queue := Queue} = State) ->
    {noreply, warm_up(State#{input_queue => [{PlayerId, Seq, Input} | Queue]})};
%% Dropped rather than queued once the queue is full: see ?MAX_EFFECT_QUEUE.
handle_cast(
    {entity_effect, EntityId, Event},
    #{effect_queue := Q, effect_count := N, effect_bytes := B} = State
) when is_binary(EntityId), is_map(Event) ->
    Size = erts_debug:size(Event) * erlang:system_info(wordsize),
    case N >= ?MAX_EFFECT_QUEUE orelse B + Size > ?MAX_EFFECT_BYTES_QUEUED of
        true ->
            {noreply, State#{effect_dropped => maps:get(effect_dropped, State, 0) + 1}};
        false ->
            {noreply,
                warm_up(State#{
                    effect_queue => [{EntityId, Event} | Q],
                    effect_count => N + 1,
                    effect_bytes => B + Size
                })}
    end;
handle_cast(
    {add_entity, EntityId, EntityState}, #{entities := Entities, spatial_grid := Grid} = State
) when is_binary(EntityId) ->
    Grid1 = spatial_grid_insert(EntityId, EntityState, Grid),
    {noreply,
        warm_up(State#{entities => Entities#{EntityId => EntityState}, spatial_grid => Grid1})};
%% Every other id-bearing cast in this module guards, and this one did not. A Lua
%% table that mixes named and numeric keys hands the zone a non-binary entity id
%% (`asobi_lua_api:ensure_pairs/1` does not normalise them), which then reached
%% `byte_size/1` in the encoder and killed the zone mid-tick - the same crash as
%% asobi#509, one layer up. Refused loudly here rather than dropped by the
%% catch-all clause, which would be a silent no-op for a game doing something it
%% has no way to discover is wrong.
handle_cast({add_entity, EntityId, _EntityState}, State) ->
    ?LOG_WARNING(#{
        msg => ~"entity id is not a binary, add ignored",
        coords => maps:get(coords, State, undefined),
        id => io_lib:format("~0p", [EntityId])
    }),
    {noreply, State};
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
    KeyframeResult =
        case maps:get(PlayerId, Subs, undefined) of
            undefined ->
                ok;
            {Pid, _MonRef} ->
                send_keyframe(Pid, Coords, WireSeq, BroadcastEntities, frame_slots(State))
        end,
    {noreply, owe_rebind(KeyframeResult, State)};
handle_cast({start_entity_timer, Config}, #{entity_timers := ET} = State) when is_map(Config) ->
    {noreply, warm_up(State#{entity_timers => asobi_entity_timer:start_timer(Config, ET)})};
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
            {noreply,
                warm_up(State#{
                    entities => Entities#{EntityId => Entity},
                    spawner => Spawner1,
                    spatial_grid => Grid1
                })};
        {error, Reason} ->
            log_spawn_failed(TemplateId, Reason, State),
            {noreply, State}
    end;
handle_cast({spawn_entities, Spawns}, State) when is_list(Spawns) ->
    {noreply, warm_up(apply_spawns(Spawns, State))};
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

-spec handle_info(term(), map()) -> {noreply, map()} | {stop, term(), map()}.
handle_info({'DOWN', _Ref, process, DownPid, _Reason}, #{subscribers := Subs} = State) ->
    Subs1 = maps:filter(
        fun(_PlayerId, {Pid, _MonRef}) -> Pid =/= DownPid end,
        Subs
    ),
    {noreply, State#{subscribers => Subs1}};
%% The zone traps exits so terminate/2 runs on shutdown (see init/1), and
%% trapping must not quietly change what a *linked crash* means. gen_server
%% handles the parent's own EXIT; anything else reaching here is a process this
%% zone's runtime is linked to - under ADR 0015's `owned` mode that is its
%% `asobi_lua_vm`, the process now holding the Lua state - so the zone dies with
%% it exactly as it would have before, and its `transient` child spec brings it
%% back.
%%
%% The final snapshot is deliberately skipped on this path. The zone's
%% `game_state` is a reference into the VM that just died, so dumping it would
%% decode nothing and overwrite the last good row with an empty one. Leaving the
%% stored snapshot alone is what lets the replacement zone restore into it,
%% which is ADR 0015 decision 5.
handle_info({'EXIT', Pid, Reason}, State) ->
    ?LOG_ERROR(#{
        event => zone_linked_process_died,
        coords => maps:get(coords, State, undefined),
        from => Pid,
        reason => Reason,
        msg => ~"a process this zone is linked to died; restarting into the last snapshot"
    }),
    {stop, Reason, State#{skip_final_snapshot => true}};
handle_info(_Info, State) ->
    {noreply, State}.

-spec terminate(term(), map()) -> ok.
terminate(normal, #{world_id := WorldId, coords := Coords} = State) ->
    maybe_final_snapshot(State),
    clear_zone_backup(WorldId, Coords),
    notify_zone_manager_terminated(State),
    %% asobi#252 review: a zone that ever suppressed a log line leaves a
    %% permanent drop-count row otherwise - these Keys' lifetime ends here.
    forget_log_keys(WorldId, Coords),
    asobi_zone_border:clear(maps:get(border_tab, State, undefined), Coords),
    pg:leave(?PG_SCOPE, {asobi_zone, WorldId, Coords}, self()),
    ok;
%% Bare `shutdown` is what a supervisor sends, and until the zone started
%% trapping exits it could never be observed here at all - so it fell to the
%% abnormal clause below and would now leave an ETS crash-backup row behind on
%% an orderly world teardown. An orderly stop is an orderly stop however it is
%% spelled.
terminate(shutdown, #{world_id := WorldId, coords := Coords} = State) ->
    maybe_final_snapshot(State),
    clear_zone_backup(WorldId, Coords),
    notify_zone_manager_terminated(State),
    forget_log_keys(WorldId, Coords),
    asobi_zone_border:clear(maps:get(border_tab, State, undefined), Coords),
    pg:leave(?PG_SCOPE, {asobi_zone, WorldId, Coords}, self()),
    ok;
terminate({shutdown, _}, #{world_id := WorldId, coords := Coords} = State) ->
    maybe_final_snapshot(State),
    clear_zone_backup(WorldId, Coords),
    notify_zone_manager_terminated(State),
    forget_log_keys(WorldId, Coords),
    asobi_zone_border:clear(maps:get(border_tab, State, undefined), Coords),
    pg:leave(?PG_SCOPE, {asobi_zone, WorldId, Coords}, self()),
    ok;
terminate(_Reason, #{world_id := WorldId, coords := Coords, entities := Entities} = State) ->
    %% Abnormal termination — save state for recovery
    maybe_final_snapshot(State),
    backup_zone_state(WorldId, Coords, Entities),
    notify_zone_manager_terminated(State),
    forget_log_keys(WorldId, Coords),
    asobi_zone_border:clear(maps:get(border_tab, State, undefined), Coords),
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
    KeyframeResult = send_keyframe(
        PlayerPid, Coords, WireSeq, BroadcastEntities, frame_slots(State)
    ),
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
    State1 = owe_rebind(KeyframeResult, State),
    {noreply, State1#{subscribers => Subs#{PlayerId => {PlayerPid, MonRef}}}}.

%% A refused keyframe is the worst refusal there is: it is all-adds, so the client
%% it was built for has NO slot bindings at all, and it says nothing about whether
%% the shared delta stream is fine (a keyframe's field-name union is a superset of
%% any delta's, so a zone can encode every delta and refuse every keyframe). Owing
%% a rebind puts the question to the shared path, which either repairs it for
%% everyone on the next frame or latches the zone to text.
-spec owe_rebind(ok | {refused, refusal()}, map()) -> map().
owe_rebind(ok, State) ->
    State;
owe_rebind({refused, Reason}, #{coords := Coords, broadcast_entities := Entities} = State) ->
    State1 = log_refusal(
        Reason,
        ~"binary keyframe refused, joining client has no slot bindings",
        Coords,
        0,
        [{added, Id, EntityState} || Id := EntityState <- Entities],
        State
    ),
    State1#{wire_rebind => true}.

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
            {skip, _Reason} -> {zone_removals, Coords, Removals};
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
) -> ok | {refused, refusal()}.
send_keyframe(PlayerPid, Coords, WireSeq, BroadcastEntities, Slots) ->
    Snapshot = [E#{~"op" => ~"a", ~"id" => Id} || Id := E <- BroadcastEntities],
    Adds = [{added, Id, E} || Id := E <- BroadcastEntities],
    Meta = frame_meta(Coords, WireSeq, true),
    Encoded = encode_binary(sequenced, Coords, WireSeq, 0, true, Adds, Slots),
    Msg =
        case Encoded of
            {ok, Bin} -> {zone_keyframe, Meta, Snapshot, Bin};
            {skip, _Reason} -> {zone_keyframe, Meta, Snapshot}
        end,
    PlayerPid ! {asobi_message, Msg},
    %% Counted here rather than left to the caller, so the rate is visible even
    %% while the shared path encodes cleanly - a zone can refuse every keyframe
    %% and no delta. The LOG is the caller's, because the throttle lives in the
    %% zone's state and this path is client-driven through `world.resync`.
    Refusal = refusal(Encoded),
    _ = count_refusal(Refusal),
    Refusal.

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
        effect_queue := EffectQueue,
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
    {Entities0, ZoneState1, ScriptBusy} = zone_tick_result(
        GameMod:zone_tick(Entities, ZoneStateWithTick), State
    ),
    %% input_queue is built newest-first via [Input | Queue], so reverse it
    %% before applying so handle_input sees inputs in arrival order. Without
    %% this, a burst of moves arriving in one tick window collapses to the
    %% OLDEST input's state — every later move gets overwritten by the
    %% next-handle_input call walking the list head-first.
    {Entities2, TickAcks} = apply_inputs(
        GameMod, lists:reverse(Queue), Entities0, {WorldId, Coords}
    ),
    PlayerAck1 = maps:fold(fun record_ack/3, maps:get(player_ack, State, #{}), TickAcks),
    %% After inputs, so an effect a neighbour addressed at an entity lands on
    %% the same tick's post-input state rather than one the player has already
    %% moved away from.
    report_effects_dropped(State),
    %% The sender-side per-tick send budget lives in the process dictionary and
    %% is scoped to a tick, so this zone's own handle_input callers get a fresh
    %% one each tick. A zone_tick caller runs in a throwaway eval worker whose
    %% dictionary dies with it, so that half needs no reset.
    _ = asobi_lua_api:reset_effect_sends(),
    Entities2a = apply_effects(GameMod, drain_effects(EffectQueue), Entities2, State),
    Now = erlang:system_time(millisecond),
    {TimerEvents, ET1} = asobi_entity_timer:tick(Now, ET),
    Entities3 = apply_timer_events(TimerEvents, Entities2a),
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
                State0 = maybe_retry_binary_wire(State),
                {FrameSlots, Slots1} = advance_slots(
                    maps:get(binary_wire, State0),
                    BroadcastEntities,
                    Entities4,
                    maps:get(slots, State0)
                ),
                Rebind = maps:get(wire_rebind, State0),
                {WireSeq1, Refusal} = broadcast_deltas(
                    Coords, TickN, WireSeq, Deltas, Subs, FrameSlots, Rebind, Entities4
                ),
                State2 = apply_refusal(Refusal, Rebind, Coords, TickN, Deltas, State0),
                broadcast_acks(TickN, PlayerAck1, Subs),
                PoseSeq1 = broadcast_pose(
                    Coords, TickN, State2, Deltas, Entities4, Slots1, Subs
                ),
                State2#{
                    broadcast_entities => Entities4,
                    wire_seq => WireSeq1,
                    slots => Slots1,
                    pose_seq => PoseSeq1
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
        effect_queue => [],
        effect_count => 0,
        effect_bytes => 0,
        effect_dropped => 0,
        %% Bound player_ack to currently-subscribed players so it does not grow
        %% with everyone who ever sent an input (asobi#474).
        player_ack => maps:with(maps:keys(Subs), PlayerAck1),
        entity_timers => ET1,
        spawner => Spawner1,
        spatial_grid => Grid1,
        script_busy => ScriptBusy,
        tick => TickN
    }.

-doc """
Reads `zone_tick/2`'s optional third return value: does the game say this zone
still has work asobi cannot see?

A return value rather than a callback or a state field, and that is the whole
design. `reclassify/1` runs immediately after `zone_tick/2` in the same
`handle_cast`, so the answer is wanted at exactly the instant the callback
already returns - which makes any *separate* way of asking strictly worse:

- a second callback costs a marshalled crossing per idle tick, on the zones
  widgrensit/asobi#543 exists to make cheaper;
- a field on the zone state costs a table read, and a Luerl table read is not
  raw - an absent key on a table with an `__index` runs the metamethod inline on
  this process, with no timeout, no heap cap and no reduction budget. `_keep_hot`
  was absent from almost every zone state, so that was the ordinary path, and
  ordinary OOP Lua (`setmetatable(zone_state, Zone)`) was enough to hang a zone
  forever. That is what this replaced, in v0.98.0.

A value cannot do either: it is already here, and nothing is read to get it.

Fail-safe is `true`. Demoting a zone that has work is silent and harmful;
keeping one hot is loud and costs one zone.
""".
-spec zone_tick_result(term(), map()) -> {map(), term(), boolean()}.
zone_tick_result({Entities, ZoneState}, _State) when is_map(Entities) ->
    {Entities, ZoneState, false};
zone_tick_result({Entities, ZoneState, Busy}, _State) when
    is_map(Entities), is_boolean(Busy)
->
    {Entities, ZoneState, Busy};
zone_tick_result({Entities, ZoneState, Busy, Dirty}, State) when
    is_map(Entities), is_boolean(Busy)
->
    {apply_dirty(Entities, Dirty, State), ZoneState, Busy};
zone_tick_result({Entities, ZoneState, Other, Dirty}, State) when is_map(Entities) ->
    log_bad_zone_busy(State, Other),
    {apply_dirty(Entities, Dirty, State), ZoneState, true};
zone_tick_result({Entities, ZoneState, Other}, State) when is_map(Entities) ->
    log_bad_zone_busy(State, Other),
    {Entities, ZoneState, true}.

-doc """
Apply `zone_tick/2`'s optional fourth return value: what actually changed.

`#{changed => #{Id => Entity}, removed => [Id]}` on top of the map the callback
returned. A game that declares this is telling asobi that every entity it did
NOT name is byte-for-byte what asobi handed in - so the unchanged ones stay the
same TERMS, and structural sharing with the previous tick survives the callback
(widgrensit/asobi#557).

That sharing is the whole point, and it is worth more than the merge costs.
`compute_deltas/2` short-circuits on an identical entity with one pointer
comparison instead of walking its fields, and so does `sync_spatial_grid/3`.
Without it a Lua zone rebuilds every entity map on every tick's decode, so both
of those degrade to O(all entities x fields) to discover that three NPCs moved.
The bigger half of the win is upstream, in the bridge: `asobi_lua_world` decodes
only `changed` rather than the whole entities table.

Ignoring the declaration entirely is always safe and never wrong - it only
costs the sharing - so this fails towards "merge what is well-formed and log
the rest" rather than towards refusing a tick.
""".
-spec apply_dirty(map(), term(), map()) -> map().
apply_dirty(Entities, Dirty, State) when is_map(Dirty) ->
    Changed = narrow_changed(maps:get(changed, Dirty, #{}), State),
    Removed = narrow_ids(maps:get(removed, Dirty, [])),
    maps:without(Removed, maps:merge(Entities, Changed));
apply_dirty(Entities, Dirty, State) ->
    log_bad_zone_dirty(State, Dirty),
    Entities.

%% Same bar every other id-bearing path in this module holds: a non-binary id
%% reaches byte_size/1 in the encoder and kills the zone mid-tick (asobi#509).
-spec narrow_changed(term(), map()) -> map().
narrow_changed(Changed, State) when is_map(Changed) ->
    Narrowed = maps:filter(
        fun
            (Id, E) when is_binary(Id), is_map(E) -> true;
            (_Id, _E) -> false
        end,
        Changed
    ),
    case map_size(Narrowed) =:= map_size(Changed) of
        true -> ok;
        false -> log_bad_zone_dirty(State, Changed)
    end,
    Narrowed;
narrow_changed(Changed, State) ->
    log_bad_zone_dirty(State, Changed),
    #{}.

-spec narrow_ids(term()) -> [binary()].
narrow_ids(Ids) when is_list(Ids) -> [Id || Id <- Ids, is_binary(Id)];
narrow_ids(_Ids) -> [].

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

%% A module that exports handle_input_batch/2 gets the whole queue in one call.
%% The ack policy below is unchanged either way - the batch reports an outcome
%% per input and asobi still decides what that means for world.ack - so the only
%% thing the batch buys is that a bridge marshalling the entity map across a
%% language boundary does it once per tick instead of once per input.
apply_inputs(_GameMod, [], Entities, _LogKey) ->
    {Entities, #{}};
apply_inputs(GameMod, Queue, Entities, LogKey) ->
    case input_mode(GameMod) of
        batch ->
            apply_input_batch(GameMod, Queue, Entities, LogKey);
        per_input ->
            apply_per_input(GameMod, Queue, Entities, LogKey, {#{}, #{}});
        none ->
            %% Both input callbacks are optional, so a world that takes no player
            %% input is legal - but one that RECEIVES input with no handler will
            %% never process any, so this is an error, not a degraded mode.
            log_no_input_handler(GameMod, LogKey),
            {Entities, stamp_all(Queue)}
    end.

%% No code:ensure_loaded/1: do_tick/2 calls GameMod:zone_tick/2 before it ever
%% reaches here, and a remote call forces the load.
input_mode(GameMod) ->
    case erlang:function_exported(GameMod, handle_input_batch, 2) of
        true ->
            batch;
        false ->
            case erlang:function_exported(GameMod, handle_input, 3) of
                true -> per_input;
                false -> none
            end
    end.

%% Telemetry is emitted unconditionally, outside the limiter: suppressing the
%% line must not suppress the rate an operator alerts on (asobi_script_log_limiter's
%% own contract). Same at every other limited site below.
log_no_input_handler(GameMod, LogKey) ->
    asobi_telemetry:game_error(no_input_handler, #{game_module => GameMod}),
    case asobi_script_log_limiter:allow(no_input_handler_log_key(LogKey)) of
        {true, SuppressedSinceLast} ->
            ?LOG_ERROR(#{
                msg =>
                    ~"game module exports neither handle_input/3 nor handle_input_batch/2; inputs acked and dropped",
                game_module => GameMod,
                suppressed_since_last => SuppressedSinceLast
            });
        false ->
            ok
    end.

apply_input_batch(GameMod, Queue, Entities, LogKey) ->
    Inputs = [{PlayerId, Input} || {PlayerId, _Seq, Input} <- Queue],
    case GameMod:handle_input_batch(Inputs, Entities) of
        {ok, Entities1, Outcomes} when is_map(Entities1) ->
            %% No length/1 on `Outcomes`: is_list/1 admits an IMPROPER list, and
            %% length/1 then raises badarg inside the zone every other player
            %% here is simulated by. Walking the two lists in lockstep makes
            %% wrong-length, improper-tail and not-a-list one case, and that case
            %% is a bail-out rather than a crash.
            case pair_outcomes(Queue, Outcomes, LogKey) of
                {ok, Acks} ->
                    {Entities1, Acks};
                mismatch ->
                    log_bad_batch(GameMod, length(Queue), outcome_shape(Outcomes), LogKey),
                    %% NOT stamp_all/1. A stamp claims every arriving seq ran,
                    %% and asobi_player_session's ack gate is monotonic per
                    %% socket - so an overclaim here permanently buries whatever
                    %% watermark the module meant to report, for every player in
                    %% the tick, including ones whose own input was fine.
                    %% Acking nothing is recoverable: the next clean tick acks
                    %% past it.
                    {Entities1, #{}}
            end;
        Other ->
            %% Deliberately NOT a fallback to the per-input path: the batch may
            %% already have applied some of these inputs, and running them again
            %% would double-apply them.
            log_bad_batch(GameMod, length(Queue), return_shape(Other), LogKey),
            %% Acks nothing, same as the mismatch arm and for the same reason:
            %% `{ok, not_a_map, [{consumed, 30}]}` lands here, and stamping over
            %% that report would bury it permanently.
            {Entities, #{}}
    end.

%% Limited as well as shape-only: this fires once per tick for as long as the
%% module stays broken, and multiplies by every live zone in the world.
log_bad_batch(GameMod, Expected, Got, LogKey) ->
    asobi_telemetry:game_error(batch_contract, #{game_module => GameMod}),
    case asobi_script_log_limiter:allow(bad_batch_log_key(LogKey)) of
        {true, SuppressedSinceLast} ->
            ?LOG_WARNING(#{
                msg => ~"handle_input_batch broke its contract; this tick's inputs are unacked",
                game_module => GameMod,
                inputs => Expected,
                outcomes => Got,
                suppressed_since_last => SuppressedSinceLast
            });
        false ->
            ok
    end.

%% Shape, never the term: a game module's return can carry the whole entity map,
%% and this is written synchronously on the zone at tick rate. Same reasoning as
%% reported_ack/5's. `{ok, Map, _}` needs no clause - it matches
%% apply_input_batch/4's first case clause and never reaches this arm.
return_shape(T) -> shape_of(T).

outcome_shape(L) when is_list(L) ->
    try
        {list, length(L)}
    catch
        error:badarg -> improper_list
    end;
outcome_shape(T) ->
    shape_of(T).

shape_of(T) when is_atom(T) -> T;
shape_of(T) when is_map(T) -> map;
shape_of(T) when is_binary(T) -> {binary, byte_size(T)};
shape_of(T) when is_number(T) -> number;
%% Tag and arity. `{error, {out_of_range, 5}}` is the ordinary shape of a
%% rejection reason and the tag is the developer's own word for what went wrong,
%% so collapsing it to `other` would redact the only useful half.
shape_of(T) when is_tuple(T), tuple_size(T) > 0 ->
    {tuple, tag_of(element(1, T)), tuple_size(T)};
shape_of(_) ->
    other.

%% One level, not one level per nesting. Recursing through shape_of/1 here is
%% O(depth) to build and O(depth^2) to pretty-print - a 200k-deep left-spine
%% tuple renders a 40 GB log line. A tag that is itself a tuple carries no
%% developer word worth preserving.
tag_of(T) when is_atom(T) -> T;
tag_of(T) when is_binary(T) -> {binary, byte_size(T)};
tag_of(T) when is_number(T) -> number;
tag_of(_) -> other.

%% Only the no-input-handler path, where nothing else will ever ack and the
%% client would otherwise wait forever. Both contract-violation arms ack nothing
%% instead: a stamp over a report is permanent, a missing ack is not.
stamp_all(Queue) ->
    stamp_all(Queue, #{}).

stamp_all([], Stamped) ->
    Stamped;
stamp_all([{PlayerId, Seq, _Input} | Rest], Stamped) ->
    stamp_all(Rest, record_ack(PlayerId, Seq, Stamped)).

%% Shape first, apply second. apply_outcomes/4 emits rate-limited logs as it
%% walks, so discovering the mismatch halfway would spend limiter budget on
%% rejections the zone then discards - and starve the contract warning that
%% actually explains the tick.
pair_outcomes(Queue, Outcomes, LogKey) ->
    case same_length(Queue, Outcomes) of
        true -> {ok, apply_outcomes(Queue, Outcomes, LogKey, {#{}, #{}})};
        false -> mismatch
    end.

%% Total, and deliberately not length/1 on either side: is_list/1 admits an
%% improper list and length/1 would then raise badarg inside the zone.
same_length([], []) -> true;
same_length([_ | Q], [_ | O]) -> same_length(Q, O);
same_length(_, _) -> false.

apply_outcomes([], [], _LogKey, {Stamped, Reported}) ->
    maps:merge(Stamped, Reported);
apply_outcomes([{PlayerId, Seq, _Input} | Rest], [ok | Outcomes], LogKey, Acks) ->
    apply_outcomes(Rest, Outcomes, LogKey, stamped_ack(PlayerId, Seq, Acks));
apply_outcomes(
    [{PlayerId, Seq, _Input} | Rest], [{consumed, Consumed} | Outcomes], LogKey, Acks
) ->
    apply_outcomes(
        Rest, Outcomes, LogKey, reported_ack(PlayerId, Seq, Consumed, LogKey, Acks)
    );
apply_outcomes([{PlayerId, Seq, _Input} | Rest], [{error, Reason} | Outcomes], LogKey, Acks) ->
    %% Limited, unlike the per-input path's equivalent: a batch hands back every
    %% rejection in the tick at once, so an always-rejecting module turns this
    %% into inputs-per-tick warnings per tick, written synchronously on the zone
    %% every other player in it is simulated by. Same bucket and same reasoning
    %% as reported_ack/5.
    log_rejected(PlayerId, Reason, LogKey),
    apply_outcomes(Rest, Outcomes, LogKey, stamped_ack(PlayerId, Seq, Acks));
apply_outcomes([{PlayerId, Seq, _Input} | Rest], [Bad | Outcomes], LogKey, Acks) ->
    %% Shape and limited, for the same reason as log_rejected/3: this runs once
    %% per input, and the documented way to write the callback lifts values
    %% straight off the client payload, so `Bad` is attacker-influenced in both
    %% size and depth.
    asobi_telemetry:game_error(unknown_outcome, #{}),
    case asobi_script_log_limiter:allow(unknown_outcome_log_key(LogKey)) of
        {true, SuppressedSinceLast} ->
            ?LOG_WARNING(#{
                msg => ~"handle_input_batch returned an unknown outcome; acking by frame stamp",
                player_id => PlayerId,
                outcome => shape_of(Bad),
                suppressed_since_last => SuppressedSinceLast
            });
        false ->
            ok
    end,
    apply_outcomes(Rest, Outcomes, LogKey, stamped_ack(PlayerId, Seq, Acks)).

%% Shape rather than the term, because a Lua script fills a rejection reason from
%% client input via `error(...)`, and limited because this fires once per
%% rejected input.
log_rejected(PlayerId, Reason, LogKey) ->
    asobi_telemetry:game_error(input_rejected, #{}),
    case asobi_script_log_limiter:allow(reject_log_key(LogKey)) of
        {true, SuppressedSinceLast} ->
            ?LOG_WARNING(#{
                msg => ~"zone input rejected",
                player_id => PlayerId,
                reason => shape_of(Reason),
                suppressed_since_last => SuppressedSinceLast
            });
        false ->
            ok
    end.

%% Two maps, not one tagged map: a stamp says an input ARRIVED, a report says
%% how much of it RAN, and the merge below is the whole rule - a report is
%% authoritative for the rest of the tick, so the right-hand map wins per
%% player. Max-ing the two together instead would let "arrived" beat "ran",
%% which is the overclaim a game that parks overflow steps needs to avoid.
%% Stamps still max among themselves, via the same record_ack/3 that merges
%% this tick into player_ack.
apply_per_input(_GameMod, [], Entities, _LogKey, {Stamped, Reported}) ->
    {Entities, maps:merge(Stamped, Reported)};
apply_per_input(GameMod, [{PlayerId, Seq, Input} | Rest], Entities, LogKey, Acks) ->
    case GameMod:handle_input(PlayerId, Input, Entities) of
        {ok, Entities1} ->
            apply_per_input(GameMod, Rest, Entities1, LogKey, stamped_ack(PlayerId, Seq, Acks));
        {ok, Entities1, Consumed} ->
            apply_per_input(
                GameMod,
                Rest,
                Entities1,
                LogKey,
                reported_ack(PlayerId, Seq, Consumed, LogKey, Acks)
            );
        {error, Reason} ->
            %% A rejected input still advances the ack (asobi#474): the client
            %% asked the server to consume this seq and it did, it just declined
            %% the effect. Otherwise a client waits forever on an input the
            %% server chose to drop. A report already recorded this tick still
            %% outranks it - refusing one input does not unrun the others.
            log_rejected(PlayerId, Reason, LogKey),
            apply_per_input(GameMod, Rest, Entities, LogKey, stamped_ack(PlayerId, Seq, Acks))
    end.

stamped_ack(PlayerId, Seq, {Stamped, Reported}) ->
    {record_ack(PlayerId, Seq, Stamped), Reported}.

%% Note the absent `Seq` guard: a report acks a client that never stamped one.
%% Numbering steps inside the payload and leaving the frame unstamped is the
%% cleanest form of the batching design, and a module that reports is asserting
%% its clients reconcile - #474's stamp is not the only way to say so.
%%
%% ?MAX_ACK_SEQ is not decoration. The documented way to write this callback is
%% to derive the watermark from the client's own payload, so the value is
%% attacker-influenced by design, and it is echoed on every broadcast tick to a
%% session whose ack gate keeps the highest seq it has sent. One unbounded
%% bignum would therefore be both a per-tick encode amplifier and a permanent
%% kill of that connection's ack stream from every zone.
reported_ack(PlayerId, _Seq, Consumed, _LogKey, {Stamped, Reported}) when
    is_integer(Consumed), Consumed >= 0, Consumed =< ?MAX_ACK_SEQ
->
    %% Newest report wins: a module revising its watermark down within a tick
    %% is the parking case this exists for.
    {Stamped, Reported#{PlayerId => Consumed}};
reported_ack(PlayerId, Seq, Consumed, LogKey, Acks) ->
    %% A game module is user code, so a nonsense consumed seq must neither crash
    %% the shared zone nor silently ack something the client cannot use. Fall
    %% back to the frame stamp and say so.
    %%
    %% The term itself is never logged, only its shape: it is usually a field
    %% lifted straight off the client's payload, so its size and depth are
    %% attacker-chosen, and `logger` in sync mode charges the write back to
    %% THIS process - the zone every other player in it is simulated by.
    %% Keyed per zone rather than per player: a player-keyed bucket is minted
    %% by the flood it is meant to bound and nothing would ever reclaim it,
    %% since forget/1 runs at zone terminate and deletes an exact key.
    asobi_telemetry:game_error(invalid_consumed_seq, #{}),
    case asobi_script_log_limiter:allow(invalid_seq_log_key(LogKey)) of
        {true, SuppressedSinceLast} ->
            ?LOG_WARNING(#{
                msg => ~"handle_input reported an invalid consumed seq",
                player_id => PlayerId,
                consumed => classify_consumed(Consumed),
                suppressed_since_last => SuppressedSinceLast
            });
        false ->
            ok
    end,
    stamped_ack(PlayerId, Seq, Acks).

classify_consumed(N) when is_integer(N), N < 0 -> negative;
classify_consumed(N) when is_integer(N) -> above_max_ack_seq;
classify_consumed(N) when is_float(N) -> float;
classify_consumed(_) -> not_a_number.

%% One bucket per class of failure, all derived from the zone's own id. Sharing
%% one bucket blinds the others: the site that fires at input rate is the
%% rejection warning, and a rejection happens because a CLIENT sent something
%% invalid - so three bad inputs would silence the module-is-broken signals.
invalid_seq_log_key({WorldId, Coords}) -> {WorldId, Coords, invalid_consumed_seq}.
reject_log_key({WorldId, Coords}) -> {WorldId, Coords, input_rejected}.
bad_batch_log_key({WorldId, Coords}) -> {WorldId, Coords, batch_contract}.
unknown_outcome_log_key({WorldId, Coords}) -> {WorldId, Coords, unknown_outcome}.
no_input_handler_log_key({WorldId, Coords}) -> {WorldId, Coords, no_input_handler}.
effect_log_key({WorldId, Coords}, Kind) -> {WorldId, Coords, Kind}.

%% Same split as log_no_input_handler/2: the telemetry is unconditional and only
%% the log line is limited, so a zone under a flood still shows up as a rate.
%% One telemetry event and at most one log line per tick, carrying the tick's
%% count - see `effect_dropped` in init/1 for why this is not per message.
report_effects_dropped(#{effect_dropped := 0}) ->
    ok;
report_effects_dropped(#{effect_dropped := Dropped} = State) ->
    asobi_telemetry:game_error(effect_queue_full, #{
        game_module => maps:get(game_module, State, undefined),
        dropped => Dropped
    }),
    case asobi_script_log_limiter:allow(effect_log_key(log_zone(State), effect_queue_full)) of
        {true, SuppressedSinceLast} ->
            ?LOG_ERROR(#{
                msg => ~"cross-zone effect queue full; effects dropped",
                coords => maps:get(coords, State, undefined),
                dropped => Dropped,
                suppressed_since_last => SuppressedSinceLast
            });
        false ->
            ok
    end;
report_effects_dropped(_State) ->
    ok.

log_no_effect_handler(State) ->
    log_effect_issue(
        State,
        no_effect_handler,
        ~"game module does not export handle_effects/2; cross-zone effects dropped"
    ).

log_bad_effects_return(State) ->
    log_effect_issue(
        State,
        bad_effects_return,
        ~"handle_effects/2 did not return an entity map; this tick's effects are dropped"
    ).

log_zone(State) ->
    {maps:get(world_id, State, undefined), maps:get(coords, State, undefined)}.

log_effect_issue(State, Kind, Msg) ->
    Zone = log_zone(State),
    asobi_telemetry:game_error(Kind, #{
        game_module => maps:get(game_module, State, undefined)
    }),
    case asobi_script_log_limiter:allow(effect_log_key(Zone, Kind)) of
        {true, SuppressedSinceLast} ->
            ?LOG_ERROR(#{
                msg => Msg,
                coords => maps:get(coords, State, undefined),
                suppressed_since_last => SuppressedSinceLast
            });
        false ->
            ok
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
    asobi_wire_slots:slots() | undefined,
    boolean(),
    map()
) -> {non_neg_integer(), ok | {refused, refusal()}}.
broadcast_deltas(_Coords, _TickN, WireSeq, [], _Subs, _FrameSlots, _Rebind, _Entities) ->
    {WireSeq, ok};
broadcast_deltas(Coords, TickN, WireSeq, Deltas, Subs, FrameSlots, Rebind, Entities) ->
    Seq = WireSeq + 1,
    EncodedDeltas = encode_deltas(Deltas),
    Meta = frame_meta(Coords, Seq, false),
    Payload = #{
        ~"type" => ~"world.tick",
        ~"payload" => Meta#{~"tick" => TickN, ~"updates" => EncodedDeltas}
    },
    PreEncoded = iolist_to_binary(json:encode(Payload)),
    %% The binary buffer is a keyframe rather than this tick's delta when a repair
    %% is owed. The JSON buffer stays the delta either way: a text client never
    %% lost anything and does not need the baseline resent to it.
    Encoded = encode_tick(Rebind, Coords, Seq, TickN, Deltas, Entities, FrameSlots),
    RawMsg = delta_msg(PreEncoded, Encoded),
    maps:foreach(
        fun(_PlayerId, {Pid, _MonRef}) -> Pid ! RawMsg end,
        Subs
    ),
    {Seq, refusal(Encoded)}.

%% The binary wire being off is not a refusal. Nothing was attempted, no client
%% is on that wire, and reporting it would suppress the pose plane for every
%% deployment that never turned the wire on.
-spec refusal({ok, binary()} | {skip, disabled | refusal()}) -> ok | {refused, refusal()}.
refusal({ok, _Bin}) -> ok;
refusal({skip, disabled}) -> ok;
refusal({skip, Reason}) -> {refused, Reason}.

%% All-adds when a repair is owed, so the binary frame re-establishes every slot
%% binding the refused frame failed to carry. Built from the new baseline rather
%% than from the deltas, which is what makes it a baseline.
-spec encode_tick(
    boolean(),
    {integer(), integer()},
    non_neg_integer(),
    non_neg_integer(),
    [term()],
    map(),
    asobi_wire_slots:slots() | undefined
) -> {ok, binary()} | {skip, disabled | refusal()}.
encode_tick(false, Coords, Seq, TickN, Deltas, _Entities, FrameSlots) ->
    encode_binary(sequenced, Coords, Seq, TickN, false, Deltas, FrameSlots);
encode_tick(true, Coords, Seq, TickN, _Deltas, Entities, FrameSlots) ->
    Adds = [{added, Id, EntityState} || Id := EntityState <- Entities],
    encode_binary(sequenced, Coords, Seq, TickN, true, Adds, FrameSlots).

%% What a refusal costs the zone, in one place.
%%
%% First refusal: owe a keyframe. A refusal WHILE that keyframe was being built
%% means the cause is the shape of this game's entities rather than one passing
%% frame - a 33-field entity or a list-valued field is still there next tick, and
%% every keyframe after it refuses too - so the zone gives the binary wire up
%% rather than stream frames its clients cannot bind. Every subscriber falls back
%% to text, which carries everything and which a binary client handles by
%% construction (ADR 0013, decision 5).
-spec apply_refusal(
    ok | {refused, refusal()}, boolean(), {integer(), integer()}, non_neg_integer(), [term()], map()
) -> map().
apply_refusal(ok, _Rebind, _Coords, _TickN, _Deltas, State) ->
    State#{wire_rebind => false};
apply_refusal({refused, Reason}, false, Coords, TickN, Deltas, State) ->
    State1 = report_refusal(
        Reason,
        ~"binary world.tick frame refused, falling back to text",
        Coords,
        TickN,
        Deltas,
        State
    ),
    State1#{wire_rebind => true};
apply_refusal({refused, Reason}, true, Coords, TickN, Deltas, State) ->
    latch_to_text(Reason, Coords, TickN, Deltas, State).

%% Off for this zone's life. Logged unthrottled because it happens once and it is
%% the line that explains why a game's binary wire and datagram plane went quiet.
-spec latch_to_text(refusal(), {integer(), integer()}, non_neg_integer(), [term()], map()) ->
    map().
latch_to_text(Reason, Coords, TickN, Deltas, State) ->
    #{backoff := Backoff} = Retry = maps:get(wire_retry, State),
    ?LOG_WARNING(
        maps:merge(
            #{
                msg => ~"binary wire disabled for this zone, its entities cannot be encoded",
                coords => Coords,
                tick => TickN,
                field_names => distinct_field_names(Deltas),
                widest_entity => widest_entity(Deltas),
                retry_in_ms => Backoff
            },
            refusal_detail(Reason)
        )
    ),
    asobi_telemetry:binary_wire_refused(refusal_kind(Reason)),
    State#{
        binary_wire => false,
        wire_rebind => false,
        slots => asobi_wire_slots:new(),
        wire_retry => Retry#{
            at => erlang:monotonic_time(millisecond) + Backoff,
            backoff => min(Backoff * 2, ?WIRE_RETRY_MAX_MS)
        }
    }.

%% A latched zone tries the binary wire again, on a doubling backoff.
%%
%% The alternative was to latch for the zone's life, which is correct and, for a
%% persistent world, means one entity carrying a debug field for ten seconds costs
%% every player the datagram plane until the zone is restarted. Every refusal
%% cause is a property of entity shape, so most latches ARE permanent - but "most"
%% is not "all", and the zone cannot tell which it has without asking.
%%
%% Asking is cheap and self-limiting: one refused encode and one text frame, which
%% is what the tick was already paying while latched. The backoff doubles to an
%% hour so a genuinely unencodable zone settles into asking twice a day rather
%% than flapping, and `wire_rebind` makes the retry frame a keyframe, so a
%% successful one rebinds every client rather than stranding the slots it just
%% allocated.
-spec maybe_retry_binary_wire(map()) -> map().
maybe_retry_binary_wire(#{wire_retry := #{at := At} = Retry} = State) when is_integer(At) ->
    case erlang:monotonic_time(millisecond) >= At of
        false ->
            State;
        true ->
            State#{
                binary_wire => true,
                wire_rebind => true,
                wire_retry => Retry#{at => undefined}
            }
    end;
maybe_retry_binary_wire(State) ->
    State.

%% Slots are needed by the binary wire AND by the pose plane, and they are the
%% same slots: two allocations for one zone would eventually disagree about which
%% entity holds a slot, which is the class of defect ADR 0011 exists to close.
%% `binary_wire` is in the guard because the plane cannot resolve a slot without
%% it - the rule and its reasoning are in `asobi_dgram_pose:manifest/0`, which is
%% where every reader of it goes. Repeated in this guard because a zone can also
%% LATCH the wire off for itself, which the manifest cannot know.
%%
%% `wire_rebind` is in the guard for the same reason `binary_wire` is: while a
%% repair is owed the clients' slot tables are known to be behind the zone's, so a
%% pose naming a slot would be dropped where it landed. It clears on the next
%% frame that encodes, so this costs one broadcast interval rather than the plane.
-spec pose_enabled(map()) -> boolean().
pose_enabled(#{pose_manifest := {ok, _}, binary_wire := true, wire_rebind := false}) -> true;
pose_enabled(_State) -> false.

%% The datagram plane's half of the tick. Returns the zone's new pose sequence.
%%
%% Absolute transform state only: a pose can never create or remove an entity,
%% and structurally has nowhere to say so. Creation and removal ride the reliable
%% ordered world.tick and only that.
-spec broadcast_pose(
    {integer(), integer()},
    non_neg_integer(),
    map(),
    [term()],
    map(),
    asobi_wire_slots:slots(),
    map()
) -> non_neg_integer().
broadcast_pose(Coords, TickN, State, Deltas, Entities, Slots, Subs) ->
    PoseSeq = maps:get(pose_seq, State),
    case {pose_enabled(State), maps:get(pose_manifest, State)} of
        {true, {ok, Manifest}} ->
            case pose_targets(Subs) of
                [] ->
                    %% Nobody on the plane. Building a body for no one is the one
                    %% cost this whole path can trivially avoid.
                    PoseSeq;
                ConnIds ->
                    emit_pose(Coords, TickN, PoseSeq, Manifest, Deltas, Entities, Slots, ConnIds)
            end;
        _ ->
            PoseSeq
    end.

emit_pose(Coords, TickN, PoseSeq, Manifest, Deltas, Entities, Slots, ConnIds) ->
    Changed = changed_fields(Deltas, #{}),
    {Records, Saturated} = asobi_dgram_pose:records(Changed, Entities, Slots, Manifest, TickN),
    _ =
        case Saturated of
            0 -> ok;
            _ -> asobi_dgram_telemetry:pose_saturated(Saturated)
        end,
    case Records of
        [] ->
            PoseSeq;
        _ ->
            Bodies = asobi_dgram:pack_pose(
                TickN, PoseSeq, Coords, asobi_dgram_pose:fieldmask(Manifest), 0, Records
            ),
            _ = [asobi_dgram_link_client:pose(B, ConnIds) || B <- Bodies],
            PoseSeq + length(Bodies)
    end.

%% Which transform fields moved, from the delta list the JSON wire already
%% computed. Reusing it is what keeps the two carriers anchored to one baseline:
%% a second diff would drift the moment either changed.
changed_fields([], Acc) ->
    Acc;
changed_fields([{updated, Id, Diff} | Rest], Acc) ->
    changed_fields(Rest, Acc#{Id => maps:keys(Diff)});
changed_fields([{added, Id, Full} | Rest], Acc) ->
    changed_fields(Rest, Acc#{Id => maps:keys(Full)});
changed_fields([_Removed | Rest], Acc) ->
    %% A removal has no pose. The client learns it from world.tick, where it is
    %% ordered and cannot be lost.
    changed_fields(Rest, Acc).

%% Subscribers that hold a datagram credential. Read from the mint's ETS mirror
%% rather than by asking it, because this runs once per subscriber per broadcast
%% tick and a gen_server call there would put one process in every zone's path.
pose_targets(Subs) ->
    [C || PlayerId := _ <- Subs, {ok, C} <- [asobi_dgram_mint:pose_conn_of(PlayerId)]].

%% One shared buffer per wire in use, never one per subscriber - that is the
%% whole point of ADR 0001's encode-once fan-out and the reason both buffers
%% travel in ONE message. The connection picks; the zone does not need to know
%% who negotiated what, so no per-subscriber state and no race between
%% negotiation and subscription.
delta_msg(Json, {skip, _Reason}) -> {asobi_message, {zone_delta_raw, Json}};
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

%% Why a frame could not be encoded. Carried rather than logged at the point of
%% failure so one throttled warning can name the zone, the reason AND the entity,
%% which is what the report of this being un-diagnosable asked for (asobi#510).
-type refusal() ::
    dict_too_large
    | bad_field_name
    | ambiguous_field_name
    | bad_entity_id
    | value_too_large
    | {no_slot, binary()}
    | {unencodable_field, binary()}.

%% At most one refusal warning per zone per minute. A zone holding one entity the
%% encoder cannot take refuses every single frame, so an un-throttled warning is
%% five lines a second per zone for the life of the zone - which is how a real
%% signal ends up filtered out of a log pipeline. The suppressed count goes in the
%% line, so the rate is still visible.
-define(WIRE_LOG_INTERVAL_MS, 60_000).

%% Counted on every refusal, on every path. The log is throttled and this is not:
%% a dashboard has to see the rate the log deliberately hides.
-spec count_refusal(ok | {refused, refusal()}) -> ok.
count_refusal(ok) -> ok;
count_refusal({refused, Reason}) -> asobi_telemetry:binary_wire_refused(refusal_kind(Reason)).

%% Both refusal paths, one line shape and one throttle. The attribution is built
%% INSIDE the branch that logs: `distinct_field_names/1` sorts every field name in
%% the frame, and `world.resync` lets a client ask for keyframes at the resync
%% limiter's rate, so computing it per refusal would hand that client an O(N log N)
%% walk of the whole zone per request.
-spec log_refusal(
    refusal(), binary(), {integer(), integer()}, non_neg_integer(), [term()], map()
) -> map().
log_refusal(Reason, Msg, Coords, TickN, Deltas, State) ->
    Log = maps:get(wire_log, State),
    At = maps:get(logged_at, Log, undefined),
    Suppressed = maps:get(suppressed, Log, 0),
    %% Monotonic, not system time: a clock stepped backwards over an NTP
    %% correction would suppress the line for the size of the step.
    Now = erlang:monotonic_time(millisecond),
    case At =:= undefined orelse Now - At >= ?WIRE_LOG_INTERVAL_MS of
        false ->
            State#{wire_log => Log#{suppressed => Suppressed + 1}};
        true ->
            %% The two numbers that identify the cause of the common refusal:
            %% the frame carries at most 32 distinct field names (asobi_wire),
            %% and one entity is usually the reason.
            ?LOG_WARNING(
                maps:merge(
                    #{
                        msg => Msg,
                        coords => Coords,
                        tick => TickN,
                        field_names => distinct_field_names(Deltas),
                        widest_entity => widest_entity(Deltas),
                        suppressed_since => Suppressed
                    },
                    refusal_detail(Reason)
                )
            ),
            State#{wire_log => #{logged_at => Now, suppressed => 0}}
    end.

-spec report_refusal(
    refusal(), binary(), {integer(), integer()}, non_neg_integer(), [term()], map()
) -> map().
report_refusal(Reason, Msg, Coords, TickN, Deltas, State) ->
    _ = count_refusal({refused, Reason}),
    log_refusal(Reason, Msg, Coords, TickN, Deltas, State).

-spec refusal_detail(refusal()) -> map().
refusal_detail({no_slot, Id}) -> #{reason => ~"no_slot", entity => Id};
refusal_detail({unencodable_field, Id}) -> #{reason => ~"unencodable_field", entity => Id};
refusal_detail(Reason) -> #{reason => atom_to_binary(Reason, utf8)}.

-spec refusal_kind(refusal()) -> atom().
refusal_kind({Kind, _Id}) -> Kind;
refusal_kind(Kind) -> Kind.

%% How many distinct field names this frame would need in its dictionary, which
%% is the number that has to stay within 32 and the one nothing reported before.
-spec distinct_field_names([term()]) -> non_neg_integer().
distinct_field_names(Deltas) ->
    length(lists:usort([Name || Delta <- Deltas, Name := _V <- delta_fields(Delta)])).

%% The entity most likely to be the reason, so the line names something a game
%% developer can go and look at rather than a count.
-spec widest_entity([term()]) -> map().
widest_entity(Deltas) ->
    widest_entity(Deltas, #{entity => undefined, fields => 0}).

widest_entity([], Widest) ->
    Widest;
widest_entity([Delta | Rest], #{fields := Most} = Widest) ->
    case map_size(delta_fields(Delta)) of
        Count when Count > Most ->
            widest_entity(Rest, #{entity => delta_id(Delta), fields => Count});
        _ ->
            widest_entity(Rest, Widest)
    end.

-spec delta_fields(term()) -> map().
delta_fields({added, _Id, Fields}) when is_map(Fields) -> Fields;
delta_fields({updated, _Id, Fields}) when is_map(Fields) -> Fields;
delta_fields(_Delta) -> #{}.

%% `term()` and not `binary()`: the delta list is untyped here, and this value only
%% ever lands in a log report.
-spec delta_id(term()) -> term().
delta_id({added, Id, _Fields}) -> Id;
delta_id({updated, Id, _Fields}) -> Id;
delta_id({removed, Id}) -> Id.

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
) -> {ok, binary()} | {skip, disabled | refusal()}.
encode_binary(_Kind, _Coords, _Seq, _TickN, _Kf, _Deltas, undefined) ->
    {skip, disabled};
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
                {ok, Bin} -> {ok, Bin};
                {error, Reason} -> {skip, Reason}
            end;
        {skip, Reason} ->
            {skip, Reason}
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
    {ok, [asobi_wire:delta()]} | {skip, refusal()}.
wire_records([], _Slots) ->
    {ok, []};
wire_records([Delta | Rest], Slots) ->
    case wire_record(Delta, Slots) of
        {skip, Reason} ->
            {skip, Reason};
        {ok, Rec} ->
            case wire_records(Rest, Slots) of
                {skip, Reason} -> {skip, Reason};
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

%% Reports rather than logs: every refusal in this module funnels through one
%% throttled warning in `log_wire_refusal/5`, because a zone holding one entity
%% the encoder cannot take refuses every frame and would otherwise emit a warning
%% per broadcast tick for the life of the zone (asobi#510).
with_slot(Id, Slots, Fields, Build) ->
    case {asobi_wire_slots:slot_of(Id, Slots), wire_encodable(Fields)} of
        {{ok, {Slot, Gen}}, true} ->
            {ok, Build(Slot, Gen, Fields)};
        {error, _} ->
            %% advance_slots/4 syncs against the union of both baselines, so
            %% every id in the diff has a slot. Missing one means the two have
            %% drifted, and a frame encoded around the gap would bind the wrong
            %% entity on a client; drop to text and say so.
            {skip, {no_slot, Id}};
        {_, false} ->
            {skip, {unencodable_field, Id}}
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

%% asobi#474: input ack, addressed to one connection. Iterate the players with a
%% recorded mark - a stamped seq, or a seq their game module reported consuming
%% - and send world.ack only to the ones still subscribed. The mark is per zone, so a crossing player can be acked by both
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
                clamp(X, XLo, XLo + ZoneSize - Eps),
                clamp(Y, YLo, YLo + ZoneSize - Eps)
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
%% Named rather than nested min/max, which says what it does and has a type
%% the nested form could not carry into entity_with_pos/3.
-spec clamp(number(), number(), number()) -> number().
clamp(V, Lo, _Hi) when V < Lo -> Lo;
clamp(V, _Lo, Hi) when V > Hi -> Hi;
clamp(V, _Lo, _Hi) -> V.

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

%% See handle_info({'EXIT', ...}): the state this would dump is unreadable, and
%% writing it would destroy the snapshot the replacement zone needs.
maybe_final_snapshot(#{skip_final_snapshot := true}) ->
    ok;
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

%% Every limiter key this zone can mint. forget/1 deletes an exact key, so a
%% new bucket that is not listed here is a permanent ETS row per zone.
forget_log_keys(WorldId, Coords) ->
    Zone = {WorldId, Coords},
    asobi_script_log_limiter:forget(Zone),
    asobi_script_log_limiter:forget(invalid_seq_log_key(Zone)),
    asobi_script_log_limiter:forget(reject_log_key(Zone)),
    asobi_script_log_limiter:forget(bad_batch_log_key(Zone)),
    asobi_script_log_limiter:forget(unknown_outcome_log_key(Zone)),
    asobi_script_log_limiter:forget(no_input_handler_log_key(Zone)),
    asobi_script_log_limiter:forget(effect_log_key(Zone, effect_queue_full)),
    asobi_script_log_limiter:forget(effect_log_key(Zone, no_effect_handler)),
    asobi_script_log_limiter:forget(effect_log_key(Zone, bad_effects_return)),
    asobi_script_log_limiter:forget(effect_log_key(Zone, bad_zone_busy)).

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

%% --- Cross-zone border mirror (widgrensit/asobi#544) ---

%% Runs after resolve_zone_crossings/1, not before: an entity that crossed this
%% tick is published by the zone that now owns it rather than by the one handing
%% it over. A reader can still see it under both owners for at most one tick,
%% because the old owner's row is only refreshed on its own next tick -
%% apply_effects/4's ownership filter is what makes that harmless, not this
%% ordering.
publish_border(#{border_band := Band} = State) when Band =< 0 ->
    State;
publish_border(
    #{
        coords := Coords,
        zone_size := ZoneSize,
        border_band := Band,
        border_live := Live,
        border_tab := Tab,
        entities := Entities
    } = State
) ->
    InBand = asobi_zone_border:band_entities(Coords, ZoneSize, Band, Entities),
    case {map_size(InBand), Live} of
        {0, false} ->
            %% The common case on a large grid: an empty zone with no row to
            %% delete. Deleting an absent row every tick was measurably the
            %% whole cost of this feature for a zone with nothing in it.
            State;
        {0, true} ->
            asobi_zone_border:clear(Tab, Coords),
            State#{border_live => false};
        {_, _} ->
            asobi_zone_border:write_band(Tab, Coords, InBand),
            State#{border_live => true}
    end.

%% Narrows the queue back to its element type on the way out. The zone's state
%% is a plain map, so everything read from it is `term()` as far as the type
%% checker is concerned; only the cast that fills the queue guards the shape,
%% and this is where that guarantee is restated rather than asserted.
-spec drain_effects(term()) -> [{binary(), map()}].
drain_effects(Queue) when is_list(Queue) ->
    narrow_effects(Queue, []);
drain_effects(_) ->
    [].

%% Reverses as it narrows: the queue is built newest-first.
-spec narrow_effects([term()], [{binary(), map()}]) -> [{binary(), map()}].
narrow_effects([], Acc) ->
    Acc;
narrow_effects([{Id, Event} | Rest], Acc) when is_binary(Id), is_map(Event) ->
    narrow_effects(Rest, [{Id, Event} | Acc]);
narrow_effects([_ | Rest], Acc) ->
    narrow_effects(Rest, Acc).

%% Effects naming an entity this zone no longer owns are dropped silently: the
%% target died, or crossed into a third zone, between the neighbour reading the
%% band and this tick draining the queue. Both are ordinary, and handing the
%% script an effect for an id it cannot look up would make every game write the
%% same guard.
-spec apply_effects(module(), [{binary(), map()}], map(), map()) -> map().
apply_effects(_GameMod, [], Entities, _State) ->
    Entities;
apply_effects(GameMod, Effects, Entities, State) ->
    case [E || {Id, _} = E <- Effects, is_map_key(Id, Entities)] of
        [] ->
            Entities;
        Live ->
            case erlang:function_exported(GameMod, handle_effects, 2) of
                true ->
                    effects_result(GameMod:handle_effects(Live, Entities), Entities, State);
                false ->
                    log_no_effect_handler(State),
                    Entities
            end
    end.

effects_result({ok, Entities1}, _Prev, _State) when is_map(Entities1) -> Entities1;
effects_result(Entities1, _Prev, _State) when is_map(Entities1) -> Entities1;
effects_result(_Other, Prev, State) ->
    log_bad_effects_return(State),
    Prev.

%% --- Cold/hot classification (widgrensit/asobi#543) ---

%% A zone with no entities, no queued input, no live entity timer and no
%% pending respawn has nothing to simulate, and on a Lua world its tick is
%% almost entirely the bridge's fixed per-callback cost rather than game logic.
%% Ticking it at `cold_tick_divisor` is what `cold_tick_divisor` has always
%% promised; until #543 nothing ever demoted a zone, so no zone was ever cold.
%%
%% Subscribers deliberately do not count. A player watching a neighbouring
%% empty zone creates no work in it: there are no entities to move and no
%% deltas to send. That is exactly the "watched but empty" case #543 asks about.
-spec zone_idle(map()) -> boolean().
-spec asobi_idle(map()) -> boolean().
zone_idle(State) ->
    asobi_idle(State) andalso not maps:get(script_busy, State, false).

%% Everything asobi can see for itself. `script_busy` - the game's own answer,
%% from zone_tick_result/2 - is the other half, and it is a stored value rather
%% than a question asked here, so neither half costs anything to consult.
%%
%% `input_queue` and `effect_queue` are always `[]` where reclassify/1 calls
%% this - do_tick/2 empties both before it runs - so those two conditions never
%% decide anything at that call site. They are kept because this states what
%% "idle" means for a zone rather than what happens to be true at one caller,
%% and warm_up/1 is what actually handles a queue filling between ticks.
asobi_idle(#{
    entities := Entities,
    input_queue := Queue,
    effect_queue := Effects,
    entity_timers := ET,
    spawner := Spawner
}) ->
    map_size(Entities) =:= 0 andalso
        Queue =:= [] andalso
        Effects =:= [] andalso
        asobi_entity_timer:active_count(ET) =:= 0 andalso
        not asobi_zone_spawner:has_pending(Spawner).

-spec clamp_border_band(term()) -> number().
clamp_border_band(Band) when is_number(Band), Band >= 0, Band =< ?MAX_BORDER_BAND ->
    Band;
clamp_border_band(Band) ->
    ?LOG_WARNING(#{
        msg => ~"border_band must be a fraction of zone_size between 0 and 1; ignoring",
        value => Band
    }),
    ?DEFAULT_BORDER_BAND.

%% `Detail` is whatever the game returned, so it is bounded and binarised the
%% way every other game-supplied term in this module is - an unbounded `~0p` of
%% a zone state is both a 200KB log line and a way to print a secret the game
%% keeps in it.
log_bad_zone_dirty(State, Detail) ->
    Zone = log_zone(State),
    asobi_telemetry:game_error(bad_zone_dirty, #{
        game_module => maps:get(game_module, State, undefined),
        world_id => maps:get(world_id, State, undefined),
        coords => maps:get(coords, State, undefined)
    }),
    case asobi_script_log_limiter:allow(effect_log_key(Zone, bad_zone_dirty)) of
        {true, SuppressedSinceLast} ->
            ?LOG_ERROR(#{
                msg =>
                    ~"zone_tick/2's fourth return value was not a well-formed dirty set; ignoring it",
                coords => maps:get(coords, State, undefined),
                detail => bound_debug_term(Detail),
                suppressed_since_last => SuppressedSinceLast
            });
        false ->
            ok
    end.

log_bad_zone_busy(State, Detail) ->
    Zone = log_zone(State),
    asobi_telemetry:game_error(bad_zone_busy, #{
        game_module => maps:get(game_module, State, undefined),
        world_id => maps:get(world_id, State, undefined),
        coords => maps:get(coords, State, undefined)
    }),
    case asobi_script_log_limiter:allow(effect_log_key(Zone, bad_zone_busy)) of
        {true, SuppressedSinceLast} ->
            ?LOG_ERROR(#{
                msg =>
                    ~"zone_tick/2's third return value was not a boolean; keeping the zone hot",
                coords => maps:get(coords, State, undefined),
                detail => bound_debug_term(Detail),
                suppressed_since_last => SuppressedSinceLast
            });
        false ->
            ok
    end.

%% Demotion is decided on the tick, where the cost is. Promotion is not: see
%% warm_up/1.
-spec reclassify(map()) -> map().
reclassify(#{cold := Cold, ticker_pid := TickerPid} = State) ->
    case zone_idle(State) of
        Cold ->
            State;
        true ->
            asobi_world_ticker:demote_zone(TickerPid, self()),
            announce(cold, State),
            State#{cold => true};
        false ->
            warm(State)
    end.

%% Promote from the message that created the work rather than from the next
%% tick. A cold zone only ticks once every `cold_tick_divisor` ticks, so
%% waiting for its own tick to notice a player arrived would put that whole
%% divisor of latency on the first frame of every zone entry. At
%% `cold_tick_divisor = 0` it never ticks at all, so this is the ONLY
%% transition left and the whole thing rests on it (widgrensit/asobi#561).
%%
%% Nothing time-based has to be caught up here, and that is a property of
%% `asobi_idle/1` rather than an omission: a zone is only demoted when it has
%% no live entity timer and an empty respawn queue, so a dormant zone has no
%% elapsed deadline to reconcile. What it can acquire while dormant - a spawn,
%% a timer, an entity, an input, an effect - arrives as a message, and every
%% one of those messages runs this. `asobi_zone_spawner:tick/2` and
%% `asobi_entity_timer:tick/2` are both driven by the wall clock the resumed
%% tick passes them, so a window that opened during the silence fires on the
%% first tick after it rather than `cold_tick_divisor` ticks later.
-spec warm_up(map()) -> map().
warm_up(#{cold := true} = State) ->
    warm(State);
warm_up(State) ->
    State.

-doc """
Tell the reaper this zone is still in use.

Written straight into the manager's stamp table where the zone has one, which
is every zone the manager started. An occupied zone does this on EVERY tick,
and as a `gen_server` cast it made the zone manager a queue the whole world
shared - the same process `ensure_zone/2` goes through on the join and
crossing hot path, where a 1s timeout costs the crossing
(widgrensit/asobi#559). The cast remains for a zone started outside the
manager, which has no table to write to.
""".
-spec touch_manager(map()) -> ok.
touch_manager(#{zone_stamp_tab := Tab, coords := Coords}) when Tab =/= undefined ->
    asobi_zone_manager:stamp_active(Tab, Coords);
touch_manager(#{zone_manager_pid := ZMPid, coords := Coords}) when is_pid(ZMPid) ->
    asobi_zone_manager:touch_zone(ZMPid, Coords);
touch_manager(_State) ->
    ok.

%% Emitted on the transition only, never per tick: a zone that is merely busy is
%% the normal case and says nothing an operator can act on.
-spec warm(map()) -> map().
warm(#{ticker_pid := TickerPid} = State) ->
    asobi_world_ticker:promote_zone(TickerPid, self()),
    announce(hot, State),
    State#{cold => false}.

%% Both events carry the same identity, and both are emitted from a plain state
%% map, so the narrowing lives in one place rather than at each call.
-spec announce(cold | hot, map()) -> ok.
announce(Which, #{world_id := WorldId, coords := {CX, CY} = Coords}) when
    is_binary(WorldId), is_integer(CX), is_integer(CY)
->
    case Which of
        cold -> asobi_telemetry:zone_cold(WorldId, Coords);
        hot -> asobi_telemetry:zone_hot(WorldId, Coords)
    end;
announce(_Which, _State) ->
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

%% Ids in `OldEntities` that `NewEntities` no longer has.
%%
%% A fold with `maps:is_key/2` rather than `maps:keys(Old) -- maps:keys(New)`
%% (widgrensit/asobi#558). `--` is O(N*M): it rescans the right-hand list for
%% every element of the left one, so with a spatial grid configured a zone
%% holding N entities paid O(N^2) key comparisons EVERY tick to almost always
%% produce `[]`. Measured on an inert 2,000-entity zone, `erlang:'--'/2` was
%% 13% of the whole tick at ~500us a call. This is O(N) with O(1) lookups.
-spec removed_ids(map(), map()) -> [term()].
removed_ids(OldEntities, NewEntities) ->
    maps:fold(
        fun(Id, _Old, Acc) ->
            case is_map_key(Id, NewEntities) of
                true -> Acc;
                false -> [Id | Acc]
            end
        end,
        [],
        OldEntities
    ).

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
    Grid1 = remove_from_grid_do(removed_ids(OldEntities, NewEntities), Grid),
    %% Update/insert entities with changed or new positions
    maps:fold(
        fun
            (Id, Entity, G) when is_binary(Id), is_map(Entity) ->
                %% `{ok, Entity}` matches the bound entity, so an entity the
                %% tick left alone settles in one pointer comparison rather
                %% than two position extractions. Worth having only because a
                %% tick can now preserve structural sharing - see apply_dirty/3
                %% and widgrensit/asobi#557.
                case maps:find(Id, OldEntities) of
                    {ok, Entity} ->
                        G;
                    Found ->
                        sync_moved_entity(Id, Entity, Found, G)
                end;
            (_Id, _Entity, G) ->
                G
        end,
        Grid1,
        NewEntities
    ).

-spec sync_moved_entity(
    binary(), map(), {ok, term()} | error, asobi_spatial_grid:grid()
) -> asobi_spatial_grid:grid().
sync_moved_entity(Id, Entity, Found, Grid) ->
    case entity_pos(Entity) of
        undefined ->
            Grid;
        Pos ->
            case Found of
                {ok, Old} when is_map(Old) ->
                    case entity_pos(Old) of
                        Pos -> Grid;
                        _ -> asobi_spatial_grid:update(Id, Pos, Grid)
                    end;
                _ ->
                    asobi_spatial_grid:update(Id, Pos, Grid)
            end
    end.
