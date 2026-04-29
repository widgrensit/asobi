-module(asobi_world_server).
-behaviour(gen_statem).

-export([start_link/1, join/2, join/3, leave/2, move_player/3, post_tick/2, get_info/1, cancel/1]).
-export([spawn_at/3, spawn_at/4]).
-export([reconnect/2]).
-export([start_vote/2, cast_vote/4, use_veto/3]).
-export([whereis/1]).
-export([callback_mode/0, init/1, terminate/3]).
-export([loading/3, running/3, finished/3]).

-define(PG_SCOPE, nova_scope).
-define(DEFAULT_GRID_SIZE, 10).
-define(DEFAULT_ZONE_SIZE, 200).
-define(DEFAULT_TICK_RATE, 50).
-define(DEFAULT_MAX_PLAYERS, 500).
-define(DEFAULT_VIEW_RADIUS, 1).

%% --- Public API ---

-spec start_link(map()) -> gen_statem:start_ret().
start_link(Config) ->
    gen_statem:start_link(?MODULE, Config, []).

-spec join(pid(), binary()) -> ok | {error, term()}.
join(Pid, PlayerId) ->
    case gen_statem:call(Pid, {join, PlayerId}) of
        {ok, _ZonePid} -> ok;
        {error, _} = Err -> Err
    end.

%% Variant of join/2 that also synchronously binds zone_pid into the caller's
%% asobi_player_session via SessionPid before returning. Use this from the WS
%% handler so an immediately-following world.input isn't dropped while the async
%% {world_joined,...} notification is still in flight.
-spec join(pid(), binary(), pid()) -> ok | {error, term()}.
join(Pid, PlayerId, SessionPid) when is_pid(SessionPid) ->
    case gen_statem:call(Pid, {join, PlayerId}) of
        {ok, ZonePid} when is_pid(ZonePid) ->
            ok = asobi_player_session:set_zone(SessionPid, Pid, ZonePid),
            ok;
        {error, _} = Err ->
            Err
    end.

-spec leave(pid(), binary()) -> ok.
leave(Pid, PlayerId) ->
    gen_statem:cast(Pid, {leave, PlayerId}).

-spec move_player(pid(), binary(), {number(), number()}) -> ok.
move_player(Pid, PlayerId, NewPos) ->
    gen_statem:cast(Pid, {move_player, PlayerId, NewPos}).

-spec post_tick(pid(), non_neg_integer()) -> ok.
post_tick(Pid, TickN) ->
    gen_statem:cast(Pid, {post_tick, TickN}).

-spec get_info(pid()) -> map().
get_info(Pid) ->
    case gen_statem:call(Pid, get_info) of
        M when is_map(M) -> M
    end.

-spec reconnect(pid(), binary()) -> ok | {error, term()}.
reconnect(Pid, PlayerId) ->
    narrow_ok_or_error(gen_statem:call(Pid, {reconnect, PlayerId})).

-spec cancel(pid()) -> ok.
cancel(Pid) ->
    gen_statem:cast(Pid, cancel).

-spec spawn_at(pid(), binary(), {number(), number()}) -> ok.
spawn_at(Pid, TemplateId, Pos) ->
    spawn_at(Pid, TemplateId, Pos, #{}).

-spec spawn_at(pid(), binary(), {number(), number()}, map()) -> ok.
spawn_at(Pid, TemplateId, Pos, Overrides) ->
    gen_statem:cast(Pid, {spawn_at, TemplateId, Pos, Overrides}).

-spec start_vote(pid(), map()) -> {ok, pid()} | {error, term()}.
start_vote(Pid, VoteConfig) ->
    case gen_statem:call(Pid, {start_vote, VoteConfig}) of
        {ok, P} when is_pid(P) -> {ok, P};
        {error, _} = Err -> Err
    end.

-spec cast_vote(pid(), binary(), binary(), binary()) -> ok | {error, term()}.
cast_vote(Pid, PlayerId, VoteId, OptionId) ->
    narrow_ok_or_error(gen_statem:call(Pid, {cast_vote, PlayerId, VoteId, OptionId})).

-spec use_veto(pid(), binary(), binary()) -> ok | {error, term()}.
use_veto(Pid, PlayerId, VoteId) ->
    narrow_ok_or_error(gen_statem:call(Pid, {use_veto, PlayerId, VoteId})).

-spec narrow_ok_or_error(term()) -> ok | {error, term()}.
narrow_ok_or_error(ok) -> ok;
narrow_ok_or_error({error, _} = Err) -> Err.

-spec whereis(binary()) -> {ok, pid()} | error.
whereis(WorldId) ->
    case pg:get_members(?PG_SCOPE, {asobi_world_server, WorldId}) of
        [Pid | _] -> {ok, Pid};
        [] -> error
    end.

%% --- gen_statem callbacks ---

-spec callback_mode() -> gen_statem:callback_mode_result().
callback_mode() -> [state_functions, state_enter].

-spec init(map()) -> {ok, atom(), map()}.
init(Config) ->
    WorldId = maps:get(world_id, Config, asobi_id:generate()),
    pg:join(?PG_SCOPE, {asobi_world_server, WorldId}, self()),
    GameMod = maps:get(game_module, Config),
    GameConfig0 = maps:get(game_config, Config, #{}),
    GameConfig = GameConfig0#{match_id => WorldId},
    {ok, GameState0} = GameMod:init(GameConfig),
    GridSize = maps:get(grid_size, Config, ?DEFAULT_GRID_SIZE),
    ZoneSize = maps:get(zone_size, Config, ?DEFAULT_ZONE_SIZE),
    TickRate = maps:get(tick_rate, Config, ?DEFAULT_TICK_RATE),
    MaxPlayers = maps:get(max_players, Config, ?DEFAULT_MAX_PLAYERS),
    ViewRadius = maps:get(view_radius, Config, ?DEFAULT_VIEW_RADIUS),
    VetoTokensPerPlayer = maps:get(veto_tokens_per_player, Config, 0),
    FrustrationBonus = maps:get(frustration_bonus, Config, 0.5),
    Persistent = maps:get(persistent, Config, false),
    EmptyGraceMs = maps:get(empty_grace_ms, Config, 0),
    InstanceSup = maps:get(instance_sup, Config, undefined),
    {PhaseInitEvents, PhaseState} =
        case erlang:function_exported(GameMod, phases, 1) of
            true ->
                case GameMod:phases(GameConfig) of
                    [] -> {[], undefined};
                    Phases -> asobi_phase:init(Phases)
                end;
            false ->
                {[], undefined}
        end,
    %% Drive on_phase_started for the auto-started first phase. Without this,
    %% the first phase's start callback silently never fires.
    GameState = handle_phase_events(PhaseInitEvents, GameMod, GameState0),
    ChatConfig0 = maps:get(chat, Config, #{}),
    ChatConfig = ChatConfig0#{grid_size => GridSize},
    ChatState = asobi_world_chat:init(WorldId, Config#{chat => ChatConfig}),
    State = #{
        world_id => WorldId,
        mode => maps:get(mode, Config, undefined),
        config => Config,
        game_module => GameMod,
        game_state => GameState,
        grid_size => GridSize,
        zone_size => ZoneSize,
        tick_rate => TickRate,
        max_players => MaxPlayers,
        view_radius => ViewRadius,
        players => #{},
        player_zones => #{},
        instance_sup => InstanceSup,
        zone_sup_pid => undefined,
        zone_manager_pid => undefined,
        terrain_store_pid => undefined,
        ticker_pid => undefined,
        started_at => undefined,
        vote_frustration => #{},
        veto_tokens => #{},
        veto_tokens_per_player => VetoTokensPerPlayer,
        frustration_bonus => FrustrationBonus,
        active_votes => #{},
        persistent => Persistent,
        empty_grace_ms => EmptyGraceMs,
        player_ttl_ms => maps:get(player_ttl_ms, Config, 0),
        reconnect_state => init_reconnect(Config),
        chat_state => ChatState,
        phase_state => PhaseState
    },
    {ok, loading, State}.

%% --- loading state ---

-spec loading(gen_statem:event_type() | enter, term(), map()) ->
    gen_statem:state_enter_result(atom()) | gen_statem:event_handler_result(atom()).
loading(enter, _OldState, _State) ->
    %% Defer zone spawning — supervisor:which_children deadlocks if called during init
    erlang:send(self(), resolve_and_spawn),
    keep_state_and_data;
loading(info, resolve_and_spawn, #{instance_sup := InstanceSup, grid_size := GridSize} = State) ->
    {ZoneSupPid, TickerPid, ZoneManagerPid} = resolve_siblings(#{instance_sup => InstanceSup}),
    LazyZones = maps:get(lazy_zones, maps:get(config, State, #{}), GridSize > 100),
    State1 = State#{
        zone_sup_pid => ZoneSupPid,
        ticker_pid => TickerPid,
        zone_manager_pid => ZoneManagerPid
    },
    State1a = configure_zone_manager(State1),
    State2 =
        case LazyZones of
            false -> spawn_zones(State1a);
            true -> State1a
        end,
    {keep_state, State2, [{state_timeout, 0, zones_ready}]};
loading(state_timeout, zones_ready, State) ->
    {next_state, running, State#{started_at => erlang:system_time(millisecond)}};
loading({call, From}, get_info, State) ->
    {keep_state_and_data, [{reply, From, world_info(loading, State)}]};
loading({call, _From}, {join, _PlayerId}, _State) ->
    %% Postpone join until we transition to running. Otherwise the call
    %% would crash with function_clause and the caller would time out.
    {keep_state_and_data, [postpone]};
loading(cast, cancel, State) ->
    {stop, {shutdown, cancelled}, State}.

%% --- running state ---

-spec running(gen_statem:event_type() | enter, term(), map()) ->
    gen_statem:state_enter_result(atom()).
running(
    enter,
    _OldState,
    #{
        ticker_pid := TickerPid,
        zone_manager_pid := ZoneManagerPid,
        world_id := WorldId
    } = State
) ->
    asobi_world_ticker:set_zone_manager(TickerPid, ZoneManagerPid, self()),
    asobi_telemetry:world_started(WorldId, maps:get(mode, State, undefined)),
    keep_state_and_data;
running({call, From}, {join, PlayerId}, State) ->
    handle_join(From, PlayerId, State);
running(cast, {leave, PlayerId}, State) ->
    handle_leave(PlayerId, State);
running(cast, {move_player, PlayerId, NewPos}, State) ->
    handle_move(PlayerId, NewPos, State);
running(
    cast,
    {post_tick, TickN},
    #{
        game_module := Mod,
        game_state := GS,
        tick_rate := TickRate
    } = State
) ->
    case Mod:post_tick(TickN, GS) of
        {ok, GS1} ->
            State0 = tick_reconnect(State#{game_state => GS1}),
            State1 = tick_phases(TickRate, State0),
            case maps:get(phase_state, State1) of
                PS when is_map(PS) ->
                    case asobi_phase:info(PS) of
                        #{status := complete} ->
                            {next_state, finished, State1#{
                                result => #{status => ~"phases_complete"}
                            }};
                        _ ->
                            {keep_state, State1}
                    end;
                _ ->
                    {keep_state, State1}
            end;
        {vote, VoteConfig, GS1} ->
            State1 = State#{game_state => GS1},
            do_start_vote(VoteConfig, State1);
        {finished, Result, GS1} ->
            {next_state, finished, State#{game_state => GS1, result => Result}}
    end;
running({timeout, empty_grace}, _Content, #{players := Players} = State) ->
    case map_size(Players) of
        0 ->
            {next_state, finished, State#{result => #{status => ~"empty_grace_expired"}}};
        _ ->
            keep_state_and_data
    end;
running({call, From}, get_info, State) ->
    {keep_state_and_data, [{reply, From, world_info(running, State)}]};
running({call, From}, {start_vote, VoteConfig}, State) ->
    handle_start_vote(From, VoteConfig, State);
running({call, From}, {cast_vote, PlayerId, VoteId, OptionId}, State) ->
    handle_cast_vote(From, PlayerId, VoteId, OptionId, State);
running({call, From}, {use_veto, PlayerId, VoteId}, State) ->
    handle_use_veto(From, PlayerId, VoteId, State);
running(
    cast,
    {spawn_at, TemplateId, {X, Y} = Pos, Overrides},
    #{zone_manager_pid := ZMPid, zone_size := ZS} = _State
) when is_binary(TemplateId), is_number(X), is_number(Y), is_map(Overrides) ->
    Coords = pos_to_zone(Pos, ZS),
    case asobi_zone_manager:ensure_zone(ZMPid, Coords) of
        {ok, ZonePid} ->
            asobi_zone:spawn_entity(ZonePid, TemplateId, Pos, Overrides),
            keep_state_and_data;
        {error, _} ->
            keep_state_and_data
    end;
running(cast, cancel, State) ->
    {next_state, finished, State#{result => #{status => ~"cancelled"}}};
running(info, {vote_resolved, VoteId, Template, Result}, State) ->
    handle_vote_resolved(VoteId, Template, Result, State);
running(info, {vote_vetoed, VoteId, _Template}, State) ->
    Active = maps:remove(VoteId, maps:get(active_votes, State, #{})),
    {keep_state, State#{active_votes => Active}};
running(info, {asobi_message, _}, _State) ->
    %% Zone snapshots/deltas forwarded here in tests — ignore
    keep_state_and_data;
running(
    info, {'DOWN', _MonRef, process, DownPid, _Reason}, #{reconnect_state := undefined} = State
) ->
    %% No reconnect policy active. Behavior depends on player_ttl_ms:
    %%   0  (default): immediate cleanup — remove entity, broadcast op="r"
    %%   -1: keep entity forever (opt-in for persistent worlds where the
    %%       game module manages reconnection state itself)
    %% A positive player_ttl_ms is upgraded to a reconnect_state at world
    %% init, so that path is handled by the {reconnect_state := RS} clause
    %% below — never reaches here.
    case find_player_by_pid(DownPid, State) of
        {ok, PlayerId} ->
            case maps:get(player_ttl_ms, State, 0) of
                -1 -> keep_state_and_data;
                _ -> handle_leave(PlayerId, State)
            end;
        none ->
            keep_state_and_data
    end;
running(info, {'DOWN', _MonRef, process, DownPid, _Reason}, #{reconnect_state := RS} = State) ->
    case find_player_by_pid(DownPid, State) of
        {ok, PlayerId} ->
            Now = erlang:system_time(millisecond),
            {Events, RS1} = asobi_reconnect:disconnect(PlayerId, Now, RS),
            State1 = handle_reconnect_events(Events, State#{reconnect_state => RS1}),
            {keep_state, State1};
        none ->
            keep_state_and_data
    end;
running({call, From}, {reconnect, PlayerId}, State) when is_binary(PlayerId) ->
    #{
        reconnect_state := RS,
        player_zones := PZ,
        zone_manager_pid := ZMPid
    } = State,
    case {RS, maps:get(PlayerId, PZ, undefined)} of
        {undefined, _} ->
            {keep_state_and_data, [{reply, From, {error, no_reconnect_policy}}]};
        {_, undefined} ->
            {keep_state_and_data, [{reply, From, {error, not_in_world}}]};
        {_, #{zone := {ZX, ZY}, interest := InterestZones}} when
            is_integer(ZX), is_integer(ZY), is_list(InterestZones)
        ->
            ZoneCoords = {ZX, ZY},
            {_Events, RS1} = asobi_reconnect:reconnect(PlayerId, RS),
            PlayerPid = find_player_pid(PlayerId),
            MonRef = erlang:monitor(process, PlayerPid),
            %% Re-subscribe to all interest zones
            subscribe_interest_zones(InterestZones, ZMPid, PlayerId, PlayerPid),
            %% Notify session of world/zone
            ZonePid =
                case asobi_zone_manager:get_zone(ZMPid, ZoneCoords) of
                    {ok, ZP} -> ZP;
                    not_loaded -> undefined
                end,
            asobi_presence:send(PlayerId, {world_joined, self(), ZonePid}),
            %% Update player entry with new session
            Players = maps:get(players, State),
            PlayerMeta = maps:get(PlayerId, Players, #{}),
            Players1 = Players#{
                PlayerId => PlayerMeta#{
                    session_pid => PlayerPid, monitor_ref => MonRef
                }
            },
            {keep_state, State#{reconnect_state => RS1, players => Players1}, [{reply, From, ok}]}
    end.

%% --- finished state ---

-spec finished(gen_statem:event_type() | enter, term(), map()) ->
    gen_statem:state_enter_result(atom()).
finished(enter, _OldState, #{world_id := WorldId, config := Config} = State) ->
    DurationMs =
        case maps:get(started_at, State, undefined) of
            undefined -> 0;
            StartedAt -> erlang:system_time(millisecond) - StartedAt
        end,
    asobi_telemetry:world_finished(WorldId, DurationMs, maps:get(result, State, #{})),
    persist_result(State),
    %% Clean up snapshots unless world is persistent (will be restarted)
    case maps:get(persistent, Config, false) of
        false -> asobi_zone_snapshotter:delete_world(WorldId);
        true -> ok
    end,
    notify_players(finished, State),
    {keep_state_and_data, [{state_timeout, 5000, cleanup}]};
finished(state_timeout, cleanup, State) ->
    {stop, normal, State};
finished({call, From}, get_info, State) ->
    {keep_state_and_data, [{reply, From, world_info(finished, State)}]};
finished(_EventType, _Event, _State) ->
    keep_state_and_data.

-spec terminate(term(), atom(), map()) -> ok.
terminate(_Reason, _StateName, #{world_id := WorldId} = State) ->
    pg:leave(?PG_SCOPE, {asobi_world_server, WorldId}, self()),
    %% Clean up player→world ETS entries for any players still in the map.
    %% Normal handle_leave removes them per-player; this catches abrupt shutdowns.
    Players = maps:get(players, State, #{}),
    maps:foreach(fun(PlayerId, _) -> forget_player_world(PlayerId) end, Players),
    ok.

%% --- Internal: Zone Management ---

configure_zone_manager(
    #{
        zone_manager_pid := ZoneManagerPid,
        ticker_pid := TickerPid,
        world_id := WorldId,
        game_module := GameMod,
        config := Config
    } = State
) ->
    Templates = get_spawn_templates(GameMod, Config),
    Persistence = maps:get(persistence, Config, false),
    TerrainStorePid = start_terrain_store(GameMod, Config),
    BaseZoneConfig = #{
        world_id => WorldId,
        ticker_pid => TickerPid,
        game_module => GameMod,
        spawn_templates => Templates,
        persistence => Persistence,
        snapshot_interval => maps:get(snapshot_interval, Config, 600),
        zone_manager_pid => ZoneManagerPid,
        terrain_store_pid => TerrainStorePid
    },
    asobi_zone_manager:set_zone_config(ZoneManagerPid, BaseZoneConfig),
    State#{terrain_store_pid => TerrainStorePid}.

start_terrain_store(GameMod, Config) ->
    case erlang:function_exported(GameMod, terrain_provider, 1) of
        true ->
            case GameMod:terrain_provider(Config) of
                none ->
                    undefined;
                {ProvMod, ProvArgs} ->
                    {ok, Pid} = asobi_terrain_store:start_link(#{
                        provider => {ProvMod, ProvArgs},
                        seed => maps:get(seed, Config, 0)
                    }),
                    Pid
            end;
        false ->
            undefined
    end.

spawn_zones(
    #{
        grid_size := GridSize,
        game_module := GameMod,
        config := Config,
        zone_manager_pid := ZoneManagerPid,
        world_id := WorldId,
        game_state := GS
    } = State
) ->
    Persistence = maps:get(persistence, Config, false),
    AllCoords = [{X, Y} || X <- lists:seq(0, GridSize - 1), Y <- lists:seq(0, GridSize - 1)],
    {ZoneStates, Entities, _SpawnerStates, GS1} =
        case Persistence of
            true ->
                case asobi_zone_snapshotter:load_snapshots(WorldId) of
                    {ok, Snapshots} when map_size(Snapshots) > 0 ->
                        ZS = maps:map(fun(_, #{zone_state := V}) -> V end, Snapshots),
                        Ents = maps:map(fun(_, #{entities := V}) -> V end, Snapshots),
                        SS = maps:map(fun(_, #{spawner_state := V}) -> V end, Snapshots),
                        GS2 =
                            case erlang:function_exported(GameMod, on_world_recovered, 2) of
                                true ->
                                    {ok, GS3} = GameMod:on_world_recovered(Snapshots, GS),
                                    GS3;
                                false ->
                                    GS
                            end,
                        {ZS, Ents, SS, GS2};
                    _ ->
                        {generate_zone_states(GameMod, Config), #{}, #{}, GS}
                end;
            false ->
                {generate_zone_states(GameMod, Config), #{}, #{}, GS}
        end,
    %% Thread per-zone state from generate_world/2 (or recovered snapshots) into
    %% the zone_manager so each zone's init sees its own zone_state. Without
    %% this, callbacks like asobi_lua_world:handle_input/3 silently no-op
    %% because the lua_state they need is buried in the discarded ZoneStates.
    ok = asobi_zone_manager:set_initial_zone_states(ZoneManagerPid, ZoneStates),
    %% Pre-warm all zones via zone_manager (uses base config with terrain_store_pid etc.)
    ok = asobi_zone_manager:pre_warm(ZoneManagerPid),
    %% Add recovered entities to zones
    restore_entities(AllCoords, Entities, ZoneManagerPid),
    State#{game_state => GS1}.

-spec restore_entities([term()], map(), pid() | atom()) -> ok.
restore_entities([], _Entities, _ZoneManagerPid) ->
    ok;
restore_entities([{CX, CY} = Coords | Rest], Entities, ZoneManagerPid) when
    is_integer(CX), is_integer(CY)
->
    RecoveredEnts = maps:get(Coords, Entities, #{}),
    case map_size(RecoveredEnts) of
        0 ->
            ok;
        _ ->
            {ok, ZonePid} = asobi_zone_manager:ensure_zone(ZoneManagerPid, Coords),
            maps:foreach(
                fun(EId, EState) -> asobi_zone:add_entity(ZonePid, EId, EState) end,
                RecoveredEnts
            )
    end,
    restore_entities(Rest, Entities, ZoneManagerPid);
restore_entities([_ | Rest], Entities, ZoneManagerPid) ->
    restore_entities(Rest, Entities, ZoneManagerPid).

generate_zone_states(GameMod, Config) ->
    Seed = maps:get(seed, Config, erlang:system_time(millisecond)),
    case erlang:function_exported(GameMod, generate_world, 2) of
        true ->
            {ok, ZoneStates} = GameMod:generate_world(Seed, Config),
            ZoneStates;
        false ->
            #{}
    end.

get_spawn_templates(GameMod, Config) ->
    case erlang:function_exported(GameMod, spawn_templates, 1) of
        true -> GameMod:spawn_templates(Config);
        false -> maps:get(spawn_templates, Config, #{})
    end.

%% --- Internal: Player Management ---

handle_join(
    From,
    PlayerId,
    #{
        world_id := WorldId,
        players := Players,
        max_players := Max,
        game_module := Mod,
        game_state := GS
    } = State
) ->
    case map_size(Players) >= Max of
        true ->
            {keep_state_and_data, [{reply, From, {error, world_full}}]};
        false ->
            case Mod:join(PlayerId, GS) of
                {ok, GS1} ->
                    {ok, SpawnPos} = Mod:spawn_position(PlayerId, GS1),
                    State1 = State#{game_state => GS1},
                    {State2, ZonePid} = place_player(PlayerId, SpawnPos, State1),
                    %% Monitor player session for reconnection handling
                    PlayerPid = find_player_pid(PlayerId),
                    MonRef = erlang:monitor(process, PlayerPid),
                    Players1 = Players#{
                        PlayerId => #{
                            joined_at => erlang:system_time(millisecond),
                            position => SpawnPos,
                            session_pid => PlayerPid,
                            monitor_ref => MonRef
                        }
                    },
                    %% Track player→world for reconnection lookup
                    remember_player_world(PlayerId, self()),
                    VetoTokens = maps:get(veto_tokens, State2),
                    VetoCount = maps:get(veto_tokens_per_player, State2),
                    State3 = State2#{
                        players => Players1,
                        veto_tokens => VetoTokens#{PlayerId => VetoCount}
                    },
                    asobi_telemetry:world_player_joined(WorldId, PlayerId),
                    ZoneCoords = pos_to_zone(SpawnPos, maps:get(zone_size, State3)),
                    asobi_world_chat:player_joined(
                        PlayerId, ZoneCoords, maps:get(chat_state, State3)
                    ),
                    State4 = notify_phase_player_joined(State3),
                    %% Cancel any pending empty_grace timer — this player rescued the world
                    %% from the grace window. The cancel is a no-op if no timer is pending.
                    {keep_state, State4, [
                        {reply, From, {ok, ZonePid}},
                        {{timeout, empty_grace}, infinity, undefined}
                    ]};
                {error, Reason} ->
                    {keep_state_and_data, [{reply, From, {error, Reason}}]}
            end
    end.

handle_leave(
    PlayerId,
    #{
        players := Players,
        game_module := Mod,
        game_state := GS
    } = State
) ->
    case maps:is_key(PlayerId, Players) of
        false ->
            keep_state_and_data;
        true ->
            asobi_telemetry:world_player_left(maps:get(world_id, State), PlayerId),
            {ok, GS1} = Mod:leave(PlayerId, GS),
            leave_chat(PlayerId, State),
            State1 = remove_player_from_zones(PlayerId, State),
            Players1 = maps:remove(PlayerId, Players),
            forget_player_world(PlayerId),
            State2 = State1#{players => Players1, game_state => GS1},
            Persistent = maps:get(persistent, State2, false),
            GraceMs = maps:get(empty_grace_ms, State2, 0),
            case {map_size(Players1), Persistent, GraceMs} of
                {0, false, 0} ->
                    {next_state, finished, State2#{result => #{status => ~"empty"}}};
                {0, false, _} ->
                    %% Schedule a generic timeout; if a player rejoins before it fires,
                    %% handle_join cancels it. Generic timeouts persist across events
                    %% in the same state (unlike state_timeout, which resets).
                    {keep_state, State2, [{{timeout, empty_grace}, GraceMs, fire}]};
                _ ->
                    {keep_state, State2}
            end
    end.

place_player(
    PlayerId,
    {X, Y} = _Pos,
    #{
        zone_manager_pid := ZMPid,
        view_radius := ViewRadius,
        zone_size := ZoneSize,
        grid_size := GridSize
    } = State
) ->
    ZoneCoords = pos_to_zone({X, Y}, ZoneSize),
    {ok, ZonePid} = asobi_zone_manager:ensure_zone(ZMPid, ZoneCoords),
    PlayerPid = find_player_pid(PlayerId),
    asobi_zone:add_entity(ZonePid, PlayerId, #{x => X, y => Y, type => ~"player"}),
    asobi_presence:send(PlayerId, {world_joined, self(), ZonePid}),
    InterestZones = interest_zones(ZoneCoords, ViewRadius, GridSize),
    subscribe_interest_zones(InterestZones, ZMPid, PlayerId, PlayerPid),
    %% Drain the casts above (add_entity + subscribe) by issuing a sync call to
    %% the zone. Without this, a world.input cast from the WS handler can race
    %% past the add_entity cast (different sender = no FIFO) and the zone's
    %% next tick runs apply_inputs against an entities map missing the player —
    %% the Lua handle_input's "if not e then return entities end" guard then
    %% silently drops the input. The sync call forces the zone to process its
    %% mailbox up to here before we reply {ok, ZonePid} to the WS handler.
    _ = asobi_zone:get_subscriber_count(ZonePid),
    PlayerZones = maps:get(player_zones, State),
    State1 = State#{
        player_zones => PlayerZones#{PlayerId => #{zone => ZoneCoords, interest => InterestZones}}
    },
    {State1, ZonePid}.

remove_player_from_zones(
    PlayerId,
    #{
        player_zones := PlayerZones,
        zone_manager_pid := ZMPid
    } = State
) ->
    case maps:get(PlayerId, PlayerZones, undefined) of
        undefined ->
            State;
        #{zone := ZoneCoords, interest := InterestZones} ->
            case asobi_zone_manager:get_zone(ZMPid, ZoneCoords) of
                {ok, ZonePid} -> asobi_zone:remove_entity(ZonePid, PlayerId);
                not_loaded -> ok
            end,
            unsubscribe_interest_zones(InterestZones, ZMPid, PlayerId),
            %% Release primary zone if no other players need it
            asobi_zone_manager:release_zone(ZMPid, ZoneCoords),
            State#{player_zones => maps:remove(PlayerId, PlayerZones)}
    end.

handle_move(
    PlayerId,
    {X, Y} = NewPos,
    #{
        players := Players,
        player_zones := PlayerZones,
        zone_manager_pid := ZMPid,
        zone_size := ZoneSize,
        view_radius := ViewRadius,
        grid_size := GridSize,
        chat_state := ChatState
    } = State
) ->
    case maps:get(PlayerId, PlayerZones, undefined) of
        undefined ->
            keep_state_and_data;
        #{zone := OldZoneCoords} ->
            NewZoneCoords = pos_to_zone(NewPos, ZoneSize),
            case OldZoneCoords =:= NewZoneCoords of
                true ->
                    case asobi_zone_manager:get_zone(ZMPid, OldZoneCoords) of
                        {ok, ZonePid} ->
                            asobi_zone:add_entity(ZonePid, PlayerId, #{
                                x => X, y => Y, type => ~"player"
                            });
                        not_loaded ->
                            ok
                    end,
                    Players1 = maps:update_with(
                        PlayerId,
                        fun(Meta) -> Meta#{position => NewPos} end,
                        Players
                    ),
                    {keep_state, State#{players => Players1}};
                false ->
                    State1 = remove_player_from_zones(PlayerId, State),
                    {State2, _NewZonePid} = place_player(PlayerId, NewPos, State1),
                    asobi_world_chat:player_zone_changed(
                        PlayerId, OldZoneCoords, NewZoneCoords, GridSize, ChatState
                    ),
                    Players1 = maps:update_with(
                        PlayerId,
                        fun(Meta) -> Meta#{position => NewPos} end,
                        maps:get(players, State2)
                    ),
                    PlayerPid = find_player_pid(PlayerId),
                    {ok, ZonePid} = asobi_zone_manager:ensure_zone(ZMPid, NewZoneCoords),
                    PlayerPid ! {asobi_message, {world_zone_changed, ZonePid}},
                    NewInterest = interest_zones(NewZoneCoords, ViewRadius, GridSize),
                    PZ = maps:get(player_zones, State2),
                    {keep_state, State2#{
                        players => Players1,
                        player_zones => PZ#{
                            PlayerId => #{zone => NewZoneCoords, interest => NewInterest}
                        }
                    }}
            end
    end.

leave_chat(PlayerId, #{player_zones := PlayerZones, chat_state := ChatState}) ->
    case maps:get(PlayerId, PlayerZones, undefined) of
        undefined ->
            ok;
        #{zone := ZoneCoords} ->
            asobi_world_chat:player_left(PlayerId, ZoneCoords, ChatState)
    end.

%% --- Internal: Spatial ---

-spec pos_to_zone({number(), number()}, non_neg_integer()) ->
    {non_neg_integer(), non_neg_integer()}.
pos_to_zone({X, Y}, ZoneSize) when is_number(X), is_number(Y), ZoneSize > 0 ->
    TX = trunc(X) div ZoneSize,
    TY = trunc(Y) div ZoneSize,
    ZX =
        if
            TX < 0 -> 0;
            true -> TX
        end,
    ZY =
        if
            TY < 0 -> 0;
            true -> TY
        end,
    {ZX, ZY}.

-spec interest_zones({integer(), integer()}, non_neg_integer(), non_neg_integer()) ->
    [{integer(), integer()}].
interest_zones({ZX, ZY}, Radius, GridSize) ->
    XLo = clamp_lo(ZX - Radius),
    XHi = min(GridSize - 1, ZX + Radius),
    YLo = clamp_lo(ZY - Radius),
    YHi = min(GridSize - 1, ZY + Radius),
    [
        {X, Y}
     || X <- lists:seq(XLo, XHi),
        Y <- lists:seq(YLo, YHi)
    ].

-spec clamp_lo(integer()) -> non_neg_integer().
clamp_lo(N) when N < 0 -> 0;
clamp_lo(N) -> N.

find_player_pid(PlayerId) ->
    case pg:get_members(?PG_SCOPE, {player, PlayerId}) of
        [Pid | _] -> Pid;
        [] -> self()
    end.

-spec remember_player_world(binary(), pid()) -> ok.
remember_player_world(PlayerId, WorldPid) ->
    case ets:info(asobi_player_worlds) of
        undefined ->
            ok;
        _ ->
            ets:insert(asobi_player_worlds, {PlayerId, WorldPid}),
            ok
    end.

-spec forget_player_world(binary()) -> ok.
forget_player_world(PlayerId) ->
    case ets:info(asobi_player_worlds) of
        undefined ->
            ok;
        _ ->
            ets:delete(asobi_player_worlds, PlayerId),
            ok
    end.

-spec subscribe_interest_zones([term()], pid() | atom(), binary(), pid()) -> ok.
subscribe_interest_zones([], _ZMPid, _PlayerId, _PlayerPid) ->
    ok;
subscribe_interest_zones([{CX, CY} | Rest], ZMPid, PlayerId, PlayerPid) when
    is_integer(CX), is_integer(CY)
->
    case asobi_zone_manager:get_zone(ZMPid, {CX, CY}) of
        {ok, ZPid} -> asobi_zone:subscribe(ZPid, {PlayerId, PlayerPid});
        not_loaded -> ok
    end,
    subscribe_interest_zones(Rest, ZMPid, PlayerId, PlayerPid);
subscribe_interest_zones([_ | Rest], ZMPid, PlayerId, PlayerPid) ->
    subscribe_interest_zones(Rest, ZMPid, PlayerId, PlayerPid).

-spec unsubscribe_interest_zones([term()], pid() | atom(), binary()) -> ok.
unsubscribe_interest_zones([], _ZMPid, _PlayerId) ->
    ok;
unsubscribe_interest_zones([{CX, CY} | Rest], ZMPid, PlayerId) when
    is_integer(CX), is_integer(CY)
->
    case asobi_zone_manager:get_zone(ZMPid, {CX, CY}) of
        {ok, ZPid} -> asobi_zone:unsubscribe(ZPid, PlayerId);
        not_loaded -> ok
    end,
    unsubscribe_interest_zones(Rest, ZMPid, PlayerId);
unsubscribe_interest_zones([_ | Rest], ZMPid, PlayerId) ->
    unsubscribe_interest_zones(Rest, ZMPid, PlayerId).

%% --- Internal: Voting ---

handle_start_vote(
    From,
    VoteConfig,
    #{
        world_id := WorldId,
        players := Players,
        vote_frustration := Frustration,
        frustration_bonus := FBonus
    } = State
) ->
    VoteId = maps:get(vote_id, VoteConfig, asobi_id:generate()),
    PlayerIds = maps:keys(Players),
    Weights = merge_vote_weights(VoteConfig, PlayerIds, Frustration, FBonus),
    FullConfig = VoteConfig#{
        vote_id => VoteId,
        match_id => WorldId,
        match_pid => self(),
        eligible => PlayerIds,
        weights => Weights
    },
    {ok, VotePid} = asobi_vote_sup:start_vote(FullConfig),
    Active = maps:get(active_votes, State, #{}),
    {keep_state, State#{active_votes => Active#{VoteId => VotePid}}, [
        {reply, From, {ok, VotePid}}
    ]}.

do_start_vote(
    VoteConfig,
    #{
        world_id := WorldId,
        players := Players,
        vote_frustration := Frustration,
        frustration_bonus := FBonus
    } = State
) ->
    VoteId = maps:get(vote_id, VoteConfig, asobi_id:generate()),
    PlayerIds = maps:keys(Players),
    Weights = merge_vote_weights(VoteConfig, PlayerIds, Frustration, FBonus),
    FullConfig = VoteConfig#{
        vote_id => VoteId,
        match_id => WorldId,
        match_pid => self(),
        eligible => PlayerIds,
        weights => Weights
    },
    case asobi_vote_sup:start_vote(FullConfig) of
        {ok, VotePid} ->
            Active = maps:get(active_votes, State, #{}),
            {keep_state, State#{active_votes => Active#{VoteId => VotePid}}};
        {error, _} ->
            keep_state_and_data
    end.

handle_cast_vote(From, PlayerId, VoteId, OptionId, State) ->
    Active = maps:get(active_votes, State, #{}),
    case maps:get(VoteId, Active, undefined) of
        undefined ->
            {keep_state_and_data, [{reply, From, {error, vote_not_found}}]};
        VotePid ->
            Result = asobi_vote_server:cast_vote(VotePid, PlayerId, OptionId),
            {keep_state_and_data, [{reply, From, Result}]}
    end.

handle_use_veto(From, PlayerId, VoteId, #{veto_tokens := Tokens} = State) ->
    Active = maps:get(active_votes, State, #{}),
    Remaining = maps:get(PlayerId, Tokens, 0),
    case {maps:get(VoteId, Active, undefined), Remaining} of
        {undefined, _} ->
            {keep_state_and_data, [{reply, From, {error, vote_not_found}}]};
        {_, 0} ->
            {keep_state_and_data, [{reply, From, {error, no_veto_tokens}}]};
        {VotePid, N} ->
            case asobi_vote_server:cast_veto(VotePid, PlayerId) of
                ok ->
                    {keep_state, State#{veto_tokens => Tokens#{PlayerId => N - 1}}, [
                        {reply, From, ok}
                    ]};
                {error, _} = Err ->
                    {keep_state_and_data, [{reply, From, Err}]}
            end
    end.

handle_vote_resolved(
    VoteId,
    Template,
    Result,
    #{
        game_module := Mod,
        game_state := GS,
        vote_frustration := Frustration
    } = State
) ->
    Active = maps:remove(VoteId, maps:get(active_votes, State, #{})),
    Frustration1 = update_frustration(Result, Frustration),
    case erlang:function_exported(Mod, vote_resolved, 3) of
        true ->
            {ok, GS1} = Mod:vote_resolved(Template, Result, GS),
            {keep_state, State#{
                active_votes => Active,
                game_state => GS1,
                vote_frustration => Frustration1
            }};
        false ->
            {keep_state, State#{active_votes => Active, vote_frustration => Frustration1}}
    end.

merge_vote_weights(VoteConfig, PlayerIds, Frustration, FBonus) ->
    FWeights = build_frustration_weights(PlayerIds, Frustration, FBonus),
    BaseWeights =
        case maps:get(weights, VoteConfig, #{}) of
            BW when is_map(BW) -> BW;
            _ -> #{}
        end,
    maps:merge(FWeights, BaseWeights).

-spec build_frustration_weights([term()], map(), number()) -> #{term() => number()}.
build_frustration_weights([], _Frustration, _FBonus) ->
    #{};
build_frustration_weights([PId | Rest], Frustration, FBonus) ->
    FVal =
        case maps:get(PId, Frustration, 0) of
            N when is_number(N) -> N;
            _ -> 0
        end,
    Acc = build_frustration_weights(Rest, Frustration, FBonus),
    Acc#{PId => 1 + FVal * FBonus}.

update_frustration(#{winner := undefined}, Frustration) ->
    Frustration;
update_frustration(#{winner := Winner, votes_cast := VotesCast}, Frustration) ->
    maps:fold(
        fun(PlayerId, Vote, Acc) ->
            case Vote =:= Winner of
                true -> maps:remove(PlayerId, Acc);
                false -> Acc#{PlayerId => maps:get(PlayerId, Acc, 0) + 1}
            end
        end,
        Frustration,
        VotesCast
    );
update_frustration(_Result, Frustration) ->
    Frustration.

%% --- Internal: Persistence ---

persist_result(#{world_id := WorldId, players := Players} = State) ->
    CS = kura_changeset:cast(
        asobi_match_record,
        #{},
        #{
            id => WorldId,
            mode => maps:get(mode, State, undefined),
            status => ~"finished",
            players => maps:keys(Players),
            result => maps:get(result, State, #{}),
            started_at => maps:get(started_at, State, undefined),
            finished_at => erlang:system_time(millisecond)
        },
        [id, mode, status, players, result, started_at, finished_at]
    ),
    _ = asobi_repo:insert(CS),
    ok.

notify_players(Event, #{players := Players, world_id := WorldId} = State) ->
    Payload =
        case Event of
            finished ->
                #{world_id => WorldId, result => maps:get(result, State, #{})};
            phase_changed ->
                case maps:get(phase_state, State, undefined) of
                    undefined -> #{world_id => WorldId};
                    PS -> maps:merge(#{world_id => WorldId}, asobi_phase:info(PS))
                end
        end,
    maps:foreach(
        fun(PlayerId, _Meta) ->
            asobi_presence:send(PlayerId, {world_event, Event, Payload})
        end,
        Players
    ).

world_info(Status, #{world_id := WorldId, players := Players} = State) ->
    Base = #{
        world_id => WorldId,
        status => Status,
        player_count => map_size(Players),
        max_players => maps:get(max_players, State, 500),
        players => maps:keys(Players),
        mode => maps:get(mode, State, undefined),
        grid_size => maps:get(grid_size, State),
        started_at => maps:get(started_at, State, undefined)
    },
    case maps:get(phase_state, State, undefined) of
        undefined -> Base;
        PS -> Base#{phase => asobi_phase:info(PS)}
    end.

%% --- Internal: Reconnection ---

%% Resolution order:
%%   1. Explicit `reconnect` policy in Config (expert mode — full asobi_reconnect
%%      policy with during_grace, on_reconnect, on_expire, etc.).
%%   2. `player_ttl_ms` > 0 — synthesize a simple grace-then-remove policy.
%%   3. Otherwise undefined — DOWN handler decides based on player_ttl_ms
%%      (0 = immediate cleanup, -1 = keep forever).
init_reconnect(Config) ->
    case maps:get(reconnect, Config, undefined) of
        Policy when is_map(Policy) ->
            asobi_reconnect:new(Policy);
        undefined ->
            case maps:get(player_ttl_ms, Config, 0) of
                Ms when is_integer(Ms), Ms > 0 ->
                    asobi_reconnect:new(#{
                        grace_period => Ms,
                        during_grace => removed,
                        on_reconnect => respawn,
                        on_expire => remove,
                        pause_match => false,
                        max_offline_total => infinity
                    });
                _ ->
                    undefined
            end
    end.

tick_reconnect(#{reconnect_state := undefined} = State) ->
    State;
tick_reconnect(#{reconnect_state := RS, tick_rate := TickRate} = State) ->
    {Events, RS1} = asobi_reconnect:tick(TickRate, RS),
    State1 = State#{reconnect_state => RS1},
    handle_reconnect_events(Events, State1).

handle_reconnect_events([], State) ->
    State;
handle_reconnect_events([{grace_expired, PlayerId, Action} | Rest], State) ->
    State1 =
        case Action of
            remove ->
                #{world_id := WorldId} = State,
                forget_player_world(PlayerId),
                asobi_telemetry:world_player_left(WorldId, PlayerId),
                State2 = remove_player_from_zones(PlayerId, State),
                Players = maps:remove(PlayerId, maps:get(players, State2)),
                State2#{players => Players};
            _ ->
                State
        end,
    handle_reconnect_events(Rest, State1);
handle_reconnect_events([_ | Rest], State) ->
    handle_reconnect_events(Rest, State).

find_player_by_pid(Pid, #{players := Players}) ->
    maps:fold(
        fun
            (PlayerId, #{session_pid := SPid}, none) when SPid =:= Pid ->
                {ok, PlayerId};
            (_, _, Acc) ->
                Acc
        end,
        none,
        Players
    ).

resolve_siblings(#{instance_sup := InstanceSup}) ->
    ZoneSupPid = asobi_world_instance:get_child(InstanceSup, asobi_zone_sup),
    TickerPid = asobi_world_instance:get_child(InstanceSup, asobi_world_ticker),
    ZoneManagerPid = asobi_world_instance:get_child(InstanceSup, asobi_zone_manager),
    {ZoneSupPid, TickerPid, ZoneManagerPid}.

%% --- Internal: Phases ---

tick_phases(_DeltaMs, #{phase_state := undefined} = State) ->
    State;
tick_phases(
    DeltaMs,
    #{
        phase_state := PS,
        game_module := Mod,
        game_state := GS,
        world_id := WorldId
    } = State
) ->
    OldPhase = asobi_phase:current(PS),
    {Events, PS1} = asobi_phase:tick(DeltaMs, PS),
    NewPhase = asobi_phase:current(PS1),
    case OldPhase =/= NewPhase of
        true ->
            asobi_telemetry:world_phase_changed(
                WorldId,
                case OldPhase of
                    undefined -> ~"none";
                    P -> P
                end,
                case NewPhase of
                    undefined -> ~"complete";
                    P -> P
                end
            ),
            %% Broadcast phase change to all players
            notify_players(phase_changed, State#{phase_state => PS1});
        false ->
            ok
    end,
    %% Periodically send phase info (every ~50 ticks = ~2.5s)
    case erlang:system_time(second) rem 3 of
        0 ->
            PhaseInfo2 = asobi_phase:info(PS1),
            maps:foreach(
                fun(PlayerId, _) ->
                    asobi_presence:send(PlayerId, {world_event, phase_changed, PhaseInfo2})
                end,
                maps:get(players, State, #{})
            );
        _ ->
            ok
    end,
    GS1 = handle_phase_events(Events, Mod, GS),
    State#{phase_state => PS1, game_state => GS1}.

notify_phase_player_joined(#{phase_state := undefined} = State) ->
    State;
notify_phase_player_joined(
    #{
        phase_state := PS,
        players := Players,
        game_module := Mod,
        game_state := GS
    } = State
) ->
    Count = map_size(Players),
    {Events, PS1} = asobi_phase:notify({player_joined, Count}, PS),
    GS1 = handle_phase_events(Events, Mod, GS),
    State#{phase_state => PS1, game_state => GS1}.

handle_phase_events([], _Mod, GS) ->
    GS;
handle_phase_events([{phase_started, Name} | Rest], Mod, GS) ->
    GS1 =
        case erlang:function_exported(Mod, on_phase_started, 2) of
            true ->
                {ok, GS2} = Mod:on_phase_started(Name, GS),
                GS2;
            false ->
                GS
        end,
    handle_phase_events(Rest, Mod, GS1);
handle_phase_events([{phase_ended, Name} | Rest], Mod, GS) ->
    GS1 =
        case erlang:function_exported(Mod, on_phase_ended, 2) of
            true ->
                {ok, GS2} = Mod:on_phase_ended(Name, GS),
                GS2;
            false ->
                GS
        end,
    handle_phase_events(Rest, Mod, GS1);
handle_phase_events([_Event | Rest], Mod, GS) ->
    handle_phase_events(Rest, Mod, GS).
