-module(asobi_world_server).
-behaviour(gen_statem).

-export([start_link/1, join/2, leave/2, post_tick/2, get_info/1, cancel/1]).
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
    gen_statem:call(Pid, {join, PlayerId}).

-spec leave(pid(), binary()) -> ok.
leave(Pid, PlayerId) ->
    gen_statem:cast(Pid, {leave, PlayerId}).

-spec post_tick(pid(), non_neg_integer()) -> ok.
post_tick(Pid, TickN) ->
    gen_statem:cast(Pid, {post_tick, TickN}).

-spec get_info(pid()) -> map().
get_info(Pid) ->
    gen_statem:call(Pid, get_info).

-spec cancel(pid()) -> ok.
cancel(Pid) ->
    gen_statem:cast(Pid, cancel).

-spec start_vote(pid(), map()) -> {ok, pid()} | {error, term()}.
start_vote(Pid, VoteConfig) ->
    gen_statem:call(Pid, {start_vote, VoteConfig}).

-spec cast_vote(pid(), binary(), binary(), binary()) -> ok | {error, term()}.
cast_vote(Pid, PlayerId, VoteId, OptionId) ->
    gen_statem:call(Pid, {cast_vote, PlayerId, VoteId, OptionId}).

-spec use_veto(pid(), binary(), binary()) -> ok | {error, term()}.
use_veto(Pid, PlayerId, VoteId) ->
    gen_statem:call(Pid, {use_veto, PlayerId, VoteId}).

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
    GameConfig = maps:get(game_config, Config, #{}),
    {ok, GameState} = GameMod:init(GameConfig),
    GridSize = maps:get(grid_size, Config, ?DEFAULT_GRID_SIZE),
    ZoneSize = maps:get(zone_size, Config, ?DEFAULT_ZONE_SIZE),
    TickRate = maps:get(tick_rate, Config, ?DEFAULT_TICK_RATE),
    MaxPlayers = maps:get(max_players, Config, ?DEFAULT_MAX_PLAYERS),
    ViewRadius = maps:get(view_radius, Config, ?DEFAULT_VIEW_RADIUS),
    VetoTokensPerPlayer = maps:get(veto_tokens_per_player, Config, 0),
    FrustrationBonus = maps:get(frustration_bonus, Config, 0.5),
    {ZoneSupPid, TickerPid} = resolve_siblings(Config),
    PhaseState =
        case erlang:function_exported(GameMod, phases, 1) of
            true ->
                Phases = GameMod:phases(GameConfig),
                asobi_phase:init(Phases);
            false ->
                undefined
        end,
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
        zone_pids => #{},
        zone_sup_pid => ZoneSupPid,
        ticker_pid => TickerPid,
        started_at => undefined,
        vote_frustration => #{},
        veto_tokens => #{},
        veto_tokens_per_player => VetoTokensPerPlayer,
        frustration_bonus => FrustrationBonus,
        active_votes => #{},
        phase_state => PhaseState
    },
    {ok, loading, State}.

%% --- loading state ---

-spec loading(gen_statem:event_type() | enter, term(), map()) ->
    gen_statem:state_enter_result(atom()).
loading(enter, _OldState, State) ->
    State1 = spawn_zones(State),
    {keep_state, State1, [{state_timeout, 0, zones_ready}]};
loading(state_timeout, zones_ready, State) ->
    {next_state, running, State#{started_at => erlang:system_time(millisecond)}};
loading({call, From}, get_info, State) ->
    {keep_state_and_data, [{reply, From, world_info(loading, State)}]};
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
        zone_pids := ZonePids,
        world_id := WorldId
    } = State
) ->
    Zones = maps:values(ZonePids),
    asobi_world_ticker:set_zones(TickerPid, Zones, self()),
    asobi_telemetry:world_started(WorldId, maps:get(mode, State, undefined)),
    keep_state_and_data;
running({call, From}, {join, PlayerId}, State) ->
    handle_join(From, PlayerId, State);
running(cast, {leave, PlayerId}, State) ->
    handle_leave(PlayerId, State);
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
            State1 = tick_phases(TickRate, State#{game_state => GS1}),
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
running({call, From}, get_info, State) ->
    {keep_state_and_data, [{reply, From, world_info(running, State)}]};
running({call, From}, {start_vote, VoteConfig}, State) ->
    handle_start_vote(From, VoteConfig, State);
running({call, From}, {cast_vote, PlayerId, VoteId, OptionId}, State) ->
    handle_cast_vote(From, PlayerId, VoteId, OptionId, State);
running({call, From}, {use_veto, PlayerId, VoteId}, State) ->
    handle_use_veto(From, PlayerId, VoteId, State);
running(cast, cancel, State) ->
    {next_state, finished, State#{result => #{status => ~"cancelled"}}};
running(info, {vote_resolved, VoteId, Template, Result}, State) ->
    handle_vote_resolved(VoteId, Template, Result, State);
running(info, {vote_vetoed, VoteId, _Template}, State) ->
    Active = maps:remove(VoteId, maps:get(active_votes, State, #{})),
    {keep_state, State#{active_votes => Active}}.

%% --- finished state ---

-spec finished(gen_statem:event_type() | enter, term(), map()) ->
    gen_statem:state_enter_result(atom()).
finished(enter, _OldState, #{world_id := WorldId} = State) ->
    DurationMs =
        case maps:get(started_at, State, undefined) of
            undefined -> 0;
            StartedAt -> erlang:system_time(millisecond) - StartedAt
        end,
    asobi_telemetry:world_finished(WorldId, DurationMs, maps:get(result, State, #{})),
    persist_result(State),
    notify_players(finished, State),
    {keep_state_and_data, [{state_timeout, 5000, cleanup}]};
finished(state_timeout, cleanup, State) ->
    {stop, normal, State};
finished({call, From}, get_info, State) ->
    {keep_state_and_data, [{reply, From, world_info(finished, State)}]};
finished(_EventType, _Event, _State) ->
    keep_state_and_data.

-spec terminate(term(), atom(), map()) -> ok.
terminate(_Reason, _StateName, #{world_id := WorldId}) ->
    pg:leave(?PG_SCOPE, {asobi_world_server, WorldId}, self()),
    ok.

%% --- Internal: Zone Management ---

spawn_zones(
    #{
        grid_size := GridSize,
        game_module := GameMod,
        config := Config,
        zone_sup_pid := ZoneSupPid,
        ticker_pid := TickerPid,
        world_id := WorldId
    } = State
) ->
    Seed = maps:get(seed, Config, erlang:system_time(millisecond)),
    ZoneStates = generate_zone_states(GameMod, Seed, Config, GridSize),
    AllCoords = [{X, Y} || X <- lists:seq(0, GridSize - 1), Y <- lists:seq(0, GridSize - 1)],
    ZonePids = lists:foldl(
        fun(Coords, Acc) ->
            ZoneState = maps:get(Coords, ZoneStates, #{}),
            ZoneConfig = #{
                world_id => WorldId,
                coords => Coords,
                ticker_pid => TickerPid,
                game_module => GameMod,
                zone_state => ZoneState
            },
            {ok, Pid} = asobi_zone_sup:start_zone(ZoneSupPid, ZoneConfig),
            Acc#{Coords => Pid}
        end,
        #{},
        AllCoords
    ),
    State#{zone_pids => ZonePids}.

generate_zone_states(GameMod, Seed, Config, _GridSize) ->
    case erlang:function_exported(GameMod, generate_world, 2) of
        true ->
            {ok, ZoneStates} = GameMod:generate_world(Seed, Config),
            ZoneStates;
        false ->
            #{}
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
                    State2 = place_player(PlayerId, SpawnPos, State1),
                    Players1 = Players#{
                        PlayerId => #{
                            joined_at => erlang:system_time(millisecond),
                            position => SpawnPos
                        }
                    },
                    VetoTokens = maps:get(veto_tokens, State2),
                    VetoCount = maps:get(veto_tokens_per_player, State2),
                    State3 = State2#{
                        players => Players1,
                        veto_tokens => VetoTokens#{PlayerId => VetoCount}
                    },
                    asobi_telemetry:world_player_joined(WorldId, PlayerId),
                    State4 = notify_phase_player_joined(State3),
                    {keep_state, State4, [{reply, From, ok}]};
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
            State1 = remove_player_from_zones(PlayerId, State),
            Players1 = maps:remove(PlayerId, Players),
            case map_size(Players1) of
                0 ->
                    {next_state, finished, State1#{
                        players => Players1, game_state => GS1, result => #{status => ~"empty"}
                    }};
                _ ->
                    {keep_state, State1#{players => Players1, game_state => GS1}}
            end
    end.

place_player(
    PlayerId,
    {X, Y} = _Pos,
    #{
        zone_pids := ZonePids,
        view_radius := ViewRadius,
        zone_size := ZoneSize,
        grid_size := GridSize
    } = State
) ->
    ZoneCoords = pos_to_zone({X, Y}, ZoneSize),
    ZonePid = maps:get(ZoneCoords, ZonePids),
    PlayerPid = find_player_pid(PlayerId),
    asobi_zone:add_entity(ZonePid, PlayerId, #{x => X, y => Y, type => ~"player"}),
    InterestZones = interest_zones(ZoneCoords, ViewRadius, GridSize),
    lists:foreach(
        fun(Coords) ->
            case maps:get(Coords, ZonePids, undefined) of
                undefined -> ok;
                ZPid -> asobi_zone:subscribe(ZPid, {PlayerId, PlayerPid})
            end
        end,
        InterestZones
    ),
    PlayerZones = maps:get(player_zones, State),
    State#{
        player_zones => PlayerZones#{PlayerId => #{zone => ZoneCoords, interest => InterestZones}}
    }.

remove_player_from_zones(
    PlayerId,
    #{
        player_zones := PlayerZones,
        zone_pids := ZonePids
    } = State
) ->
    case maps:get(PlayerId, PlayerZones, undefined) of
        undefined ->
            State;
        #{zone := ZoneCoords, interest := InterestZones} ->
            ZonePid = maps:get(ZoneCoords, ZonePids),
            asobi_zone:remove_entity(ZonePid, PlayerId),
            lists:foreach(
                fun(Coords) ->
                    case maps:get(Coords, ZonePids, undefined) of
                        undefined -> ok;
                        ZPid -> asobi_zone:unsubscribe(ZPid, PlayerId)
                    end
                end,
                InterestZones
            ),
            State#{player_zones => maps:remove(PlayerId, PlayerZones)}
    end.

%% --- Internal: Spatial ---

-spec pos_to_zone({number(), number()}, non_neg_integer()) ->
    {non_neg_integer(), non_neg_integer()}.
pos_to_zone({X, Y}, ZoneSize) ->
    {max(0, trunc(X) div ZoneSize), max(0, trunc(Y) div ZoneSize)}.

-spec interest_zones({integer(), integer()}, non_neg_integer(), non_neg_integer()) ->
    [{integer(), integer()}].
interest_zones({ZX, ZY}, Radius, GridSize) ->
    [
        {X, Y}
     || X <- lists:seq(max(0, ZX - Radius), min(GridSize - 1, ZX + Radius)),
        Y <- lists:seq(max(0, ZY - Radius), min(GridSize - 1, ZY + Radius))
    ].

find_player_pid(PlayerId) ->
    case pg:get_members(?PG_SCOPE, {player, PlayerId}) of
        [Pid | _] -> Pid;
        [] -> self()
    end.

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
    FWeights = lists:foldl(
        fun(PId, Acc) ->
            FVal =
                case maps:get(PId, Frustration, 0) of
                    N when is_number(N) -> N;
                    _ -> 0
                end,
            Acc#{PId => 1 + FVal * FBonus}
        end,
        #{},
        PlayerIds
    ),
    BaseWeights =
        case maps:get(weights, VoteConfig, #{}) of
            BW when is_map(BW) -> BW;
            _ -> #{}
        end,
    maps:merge(FWeights, BaseWeights).

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
            finished -> #{world_id => WorldId, result => maps:get(result, State, #{})}
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
        players => maps:keys(Players),
        mode => maps:get(mode, State, undefined),
        grid_size => maps:get(grid_size, State)
    },
    case maps:get(phase_state, State, undefined) of
        undefined -> Base;
        PS -> Base#{phase => asobi_phase:info(PS)}
    end.

resolve_siblings(#{zone_sup_pid := ZSP, ticker_pid := TP}) ->
    {ZSP, TP};
resolve_siblings(#{instance_sup := InstanceSup}) ->
    ZoneSupPid = asobi_world_instance:get_child(InstanceSup, asobi_zone_sup),
    TickerPid = asobi_world_instance:get_child(InstanceSup, asobi_world_ticker),
    {ZoneSupPid, TickerPid}.

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
            );
        false ->
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
