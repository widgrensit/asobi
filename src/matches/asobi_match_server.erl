-module(asobi_match_server).
-include_lib("kernel/include/logger.hrl").
-moduledoc """
Per-match `gen_statem` driving the configured game module.

**Trust boundary (F-32)**: asobi is single-tenant by design. The
configured game module (`Mod:join/2`, `Mod:tick/1`, `Mod:handle_input/3`,
phase / vote callbacks, etc.) is *trusted code*. We do not wrap
callbacks in `try/catch` — a crash in the game module is treated as a
bug worth surfacing, not a security boundary to harden against. The
match supervisor restarts the match server up to 10 times in 60s
(transient + intensity 10) before the entire `asobi_match_sup` falls
over, intentionally taking the lobby with it so an obviously broken
game cannot keep churning silently.

In multi-tenant or sandboxed contexts (`asobi_lua`) callbacks are run
through a Lua sandbox that has its own fault-isolation; that wrapper is
the place to put callback hardening.
""".
-behaviour(gen_statem).

-export([start_link/1, join/2, leave/2, handle_input/3, get_info/1, pause/1, resume/1, cancel/1]).
-export([whereis/1]).

-define(PG_SCOPE, nova_scope).
-export([start_vote/2, cast_vote/4, use_veto/3, broadcast_event/3]).
-export([callback_mode/0, init/1, terminate/3]).
-export([waiting/3, running/3, paused/3, finished/3]).

%% 10 ticks/sec
-define(DEFAULT_TICK_RATE, 100).
-define(DEFAULT_MIN_PLAYERS, 2).
-define(DEFAULT_MAX_PLAYERS, 10).
-define(WAITING_TIMEOUT, 60000).
-define(STATE_TABLE, asobi_match_state).

%% --- Public API ---

-spec start_link(map()) -> gen_statem:start_ret().
start_link(Config) ->
    gen_statem:start_link(?MODULE, Config, []).

-spec join(pid(), binary()) -> ok | {error, term()}.
join(Pid, PlayerId) ->
    case gen_statem:call(Pid, {join, PlayerId}) of
        ok -> ok;
        {error, _} = Err -> Err
    end.

-spec leave(pid(), binary()) -> ok.
leave(Pid, PlayerId) ->
    gen_statem:cast(Pid, {leave, PlayerId}).

-spec handle_input(pid(), binary(), map()) -> ok.
handle_input(Pid, PlayerId, Input) ->
    gen_statem:cast(Pid, {input, PlayerId, Input}).

-spec get_info(pid()) -> map().
get_info(Pid) ->
    case gen_statem:call(Pid, get_info) of
        Info when is_map(Info) -> Info;
        _ -> #{}
    end.

-spec pause(pid()) -> ok | {error, term()}.
pause(Pid) ->
    case gen_statem:call(Pid, pause) of
        ok -> ok;
        {error, _} = Err -> Err
    end.

-spec resume(pid()) -> ok | {error, term()}.
resume(Pid) ->
    case gen_statem:call(Pid, resume) of
        ok -> ok;
        {error, _} = Err -> Err
    end.

-spec cancel(pid()) -> ok.
cancel(Pid) ->
    gen_statem:cast(Pid, cancel).

-spec start_vote(pid(), map()) -> {ok, pid()} | {error, term()}.
start_vote(Pid, VoteConfig) ->
    case gen_statem:call(Pid, {start_vote, VoteConfig}) of
        {ok, VotePid} when is_pid(VotePid) -> {ok, VotePid};
        {error, _} = Err -> Err
    end.

-spec cast_vote(pid(), binary(), binary(), binary()) -> ok | {error, term()}.
cast_vote(Pid, PlayerId, VoteId, OptionId) ->
    case gen_statem:call(Pid, {cast_vote, PlayerId, VoteId, OptionId}) of
        ok -> ok;
        {error, _} = Err -> Err
    end.

-spec use_veto(pid(), binary(), binary()) -> ok | {error, term()}.
use_veto(Pid, PlayerId, VoteId) ->
    case gen_statem:call(Pid, {use_veto, PlayerId, VoteId}) of
        ok -> ok;
        {error, _} = Err -> Err
    end.

-spec broadcast_event(pid(), atom() | binary(), map()) -> ok.
broadcast_event(Pid, Event, Payload) ->
    gen_statem:cast(Pid, {broadcast_event, Event, Payload}).

-spec whereis(binary()) -> {ok, pid()} | error.
whereis(MatchId) ->
    case pg:get_members(?PG_SCOPE, {asobi_match_server, MatchId}) of
        [Pid | _] -> {ok, Pid};
        [] -> error
    end.

%% --- gen_statem callbacks ---

-spec callback_mode() -> gen_statem:callback_mode_result().
callback_mode() -> [state_functions, state_enter].

-spec init(map()) -> {ok, atom(), map()}.
init(Config) ->
    MatchId = maps:get(match_id, Config, generate_id()),
    pg:join(?PG_SCOPE, {asobi_match_server, MatchId}, self()),
    case recover_state(MatchId) of
        {ok, SavedStatus, SavedState} ->
            ?LOG_NOTICE(#{msg => ~"match recovered", match_id => MatchId, status => SavedStatus}),
            {ok, SavedStatus, SavedState};
        none ->
            GameMod = maps:get(game_module, Config),
            GameConfig0 = maps:get(game_config, Config, #{}),
            GameConfig = GameConfig0#{match_id => MatchId},
            {ok, GameState0} = GameMod:init(GameConfig),
            VetoTokensPerPlayer = maps:get(veto_tokens_per_player, Config, 0),
            FrustrationBonus = maps:get(frustration_bonus, Config, 0.5),
            {PhaseInitEvents, PhaseState} =
                case erlang:function_exported(GameMod, phases, 1) of
                    true ->
                        Phases = GameMod:phases(GameConfig),
                        asobi_phase:init(Phases);
                    false ->
                        {[], undefined}
                end,
            %% Drive on_phase_started for the auto-started first phase. Without
            %% this, the first phase's start callback silently never fires.
            GameState = handle_phase_events(PhaseInitEvents, GameMod, GameState0),
            State = #{
                match_id => MatchId,
                mode => maps:get(mode, Config, undefined),
                config => Config,
                game_module => GameMod,
                game_state => GameState,
                players => #{},
                input_queue => [],
                tick_rate => maps:get(tick_rate, Config, ?DEFAULT_TICK_RATE),
                min_players => maps:get(min_players, Config, ?DEFAULT_MIN_PLAYERS),
                max_players => maps:get(max_players, Config, ?DEFAULT_MAX_PLAYERS),
                started_at => undefined,
                vote_frustration => #{},
                veto_tokens => #{},
                veto_tokens_per_player => VetoTokensPerPlayer,
                frustration_bonus => FrustrationBonus,
                phase_state => PhaseState,
                reconnect_state => init_reconnect(Config)
            },
            {ok, waiting, State}
    end.

%% --- waiting state ---

-spec waiting(gen_statem:event_type() | enter, term(), map()) ->
    gen_statem:state_enter_result(atom()).
waiting(enter, _OldState, _State) ->
    {keep_state_and_data, [{state_timeout, ?WAITING_TIMEOUT, waiting_timeout}]};
waiting({call, From}, {join, PlayerId}, State) ->
    handle_join(From, PlayerId, State);
waiting({call, From}, get_info, State) ->
    {keep_state_and_data, [{reply, From, match_info(waiting, State)}]};
waiting(state_timeout, waiting_timeout, State) ->
    {stop, {shutdown, timeout}, State};
waiting(cast, {leave, PlayerId}, State) ->
    handle_leave(PlayerId, State);
waiting(cast, cancel, State) ->
    {stop, {shutdown, cancelled}, State}.

%% --- running state ---

-spec running(gen_statem:event_type() | enter, term(), map()) ->
    gen_statem:state_enter_result(atom()).
running(enter, _OldState, #{tick_rate := TickRate, match_id := MatchId} = State) ->
    backup_state(MatchId, running, State),
    asobi_telemetry:match_started(MatchId, maps:get(mode, State, undefined)),
    {keep_state_and_data, [{state_timeout, TickRate, tick}]};
running(state_timeout, tick, #{game_module := Mod, game_state := GS, input_queue := Queue} = State) ->
    GS1 = apply_inputs(Mod, Queue, GS),
    TickRate = maps:get(tick_rate, State),
    case erlang:function_exported(Mod, tick, 1) of
        true ->
            case Mod:tick(GS1) of
                {ok, GS2} ->
                    State1 = State#{game_state => GS2, input_queue => []},
                    State2 = maybe_start_vote(Mod, State1),
                    State3 = tick_reconnect(TickRate, tick_phases(TickRate, State2)),
                    case maps:get(phase_state, State3) of
                        PS when is_map(PS) ->
                            case asobi_phase:info(PS) of
                                #{status := complete} ->
                                    {next_state, finished, State3#{
                                        result => #{status => ~"phases_complete"}
                                    }};
                                _ ->
                                    broadcast_state(State3),
                                    {keep_state, State3, [
                                        {state_timeout, TickRate, tick}
                                    ]}
                            end;
                        _ ->
                            broadcast_state(State3),
                            {keep_state, State3, [{state_timeout, TickRate, tick}]}
                    end;
                {finished, Result, GS2} ->
                    {next_state, finished, State#{game_state => GS2, result => Result}}
            end;
        false ->
            State1 = State#{game_state => GS1, input_queue => []},
            State2 = maybe_start_vote(Mod, State1),
            State3 = tick_phases(TickRate, State2),
            case maps:get(phase_state, State3) of
                PS when is_map(PS) ->
                    case asobi_phase:info(PS) of
                        #{status := complete} ->
                            {next_state, finished, State3#{
                                result => #{status => ~"phases_complete"}
                            }};
                        _ ->
                            broadcast_state(State3),
                            {keep_state, State3, [{state_timeout, TickRate, tick}]}
                    end;
                _ ->
                    broadcast_state(State3),
                    {keep_state, State3, [{state_timeout, TickRate, tick}]}
            end
    end;
running(cast, {input, PlayerId, Input}, #{input_queue := Queue} = State) ->
    {keep_state, State#{input_queue => [{PlayerId, Input} | Queue]}};
running(cast, {leave, PlayerId}, State) ->
    handle_leave(PlayerId, State);
running(cast, cancel, State) ->
    {next_state, finished, State#{result => #{status => ~"cancelled"}}};
running({call, From}, pause, State) ->
    {next_state, paused, State, [{reply, From, ok}]};
running({call, From}, resume, _State) ->
    {keep_state_and_data, [{reply, From, {error, not_paused}}]};
running({call, From}, get_info, State) ->
    {keep_state_and_data, [{reply, From, match_info(running, State)}]};
running({call, From}, {join, PlayerId}, State) ->
    handle_join(From, PlayerId, State);
running(
    {call, From},
    {start_vote, VoteConfig0},
    #{
        match_id := MatchId,
        players := Players,
        vote_frustration := Frustration,
        frustration_bonus := FBonus
    } = State
) when is_map(VoteConfig0) ->
    VoteConfig = VoteConfig0,
    VoteId = maps:get(vote_id, VoteConfig, asobi_id:generate()),
    PlayerIds = maps:keys(Players),
    FrustrationWeightsRaw = lists:foldl(
        fun(PId, Acc) when is_map(Acc) ->
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
    FrustrationWeights =
        case FrustrationWeightsRaw of
            FW when is_map(FW) -> FW
        end,
    BaseWeights =
        case maps:get(weights, VoteConfig, #{}) of
            BW when is_map(BW) -> BW;
            _ -> #{}
        end,
    MergedWeights = maps:merge(FrustrationWeights, BaseWeights),
    FullConfig = VoteConfig#{
        vote_id => VoteId,
        match_id => MatchId,
        match_pid => self(),
        eligible => PlayerIds,
        weights => MergedWeights
    },
    {ok, VotePid} = asobi_vote_sup:start_vote(FullConfig),
    Active = maps:get(active_votes, State, #{}),
    {keep_state, State#{active_votes => Active#{VoteId => VotePid}}, [
        {reply, From, {ok, VotePid}}
    ]};
running({call, From}, {cast_vote, PlayerId, VoteId, OptionId}, State) when
    is_binary(PlayerId), is_binary(OptionId)
->
    Active = maps:get(active_votes, State, #{}),
    case maps:get(VoteId, Active, undefined) of
        undefined ->
            {keep_state_and_data, [{reply, From, {error, vote_not_found}}]};
        VotePid ->
            Result = asobi_vote_server:cast_vote(VotePid, PlayerId, OptionId),
            {keep_state_and_data, [{reply, From, Result}]}
    end;
running({call, From}, {use_veto, PlayerId, VoteId}, #{veto_tokens := Tokens} = State) when
    is_binary(PlayerId)
->
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
                    Tokens1 = Tokens#{PlayerId => N - 1},
                    {keep_state, State#{veto_tokens => Tokens1}, [{reply, From, ok}]};
                {error, _} = Err ->
                    {keep_state_and_data, [{reply, From, Err}]}
            end
    end;
running(cast, {broadcast_event, Event, Payload}, State) ->
    broadcast_match_event(Event, Payload, State),
    keep_state_and_data;
running(
    info, {vote_resolved, VoteId, Template, Result}, #{game_module := Mod, game_state := GS} = State
) ->
    Active = maps:remove(VoteId, maps:get(active_votes, State, #{})),
    State1 = update_frustration(Result, State#{active_votes => Active}),
    case erlang:function_exported(Mod, vote_resolved, 3) of
        true ->
            {ok, GS1} = Mod:vote_resolved(Template, Result, GS),
            {keep_state, State1#{game_state => GS1}};
        false ->
            {keep_state, State1}
    end;
running(info, {vote_vetoed, VoteId, _Template}, State) ->
    Active = maps:remove(VoteId, maps:get(active_votes, State, #{})),
    {keep_state, State#{active_votes => Active}}.

%% --- paused state ---

-spec paused(gen_statem:event_type() | enter, term(), map()) ->
    gen_statem:state_enter_result(atom()).
paused(enter, _OldState, _State) ->
    keep_state_and_data;
paused({call, From}, resume, State) ->
    {next_state, running, State, [{reply, From, ok}]};
paused({call, From}, pause, _State) ->
    {keep_state_and_data, [{reply, From, {error, already_paused}}]};
paused(cast, cancel, State) ->
    {next_state, finished, State#{result => #{status => ~"cancelled"}}};
paused(cast, {leave, PlayerId}, State) ->
    handle_leave(PlayerId, State);
paused({call, From}, get_info, State) ->
    {keep_state_and_data, [{reply, From, match_info(paused, State)}]};
paused(cast, {broadcast_event, Event, Payload}, State) ->
    broadcast_match_event(Event, Payload, State),
    keep_state_and_data;
paused(
    info, {vote_resolved, VoteId, Template, Result}, #{game_module := Mod, game_state := GS} = State
) ->
    Active = maps:remove(VoteId, maps:get(active_votes, State, #{})),
    State1 = State#{active_votes => Active},
    case erlang:function_exported(Mod, vote_resolved, 3) of
        true ->
            {ok, GS1} = Mod:vote_resolved(Template, Result, GS),
            {keep_state, State1#{game_state => GS1}};
        false ->
            {keep_state, State1}
    end;
paused(info, {vote_vetoed, VoteId, _Template}, State) ->
    Active = maps:remove(VoteId, maps:get(active_votes, State, #{})),
    {keep_state, State#{active_votes => Active}};
paused(_EventType, _Event, _State) ->
    keep_state_and_data.

%% --- finished state ---

-spec finished(gen_statem:event_type() | enter, term(), map()) ->
    gen_statem:state_enter_result(atom()).
finished(enter, _OldState, #{match_id := MatchId} = State) ->
    DurationMs =
        case maps:get(started_at, State, undefined) of
            undefined -> 0;
            StartedAt -> erlang:system_time(millisecond) - StartedAt
        end,
    asobi_telemetry:match_finished(MatchId, DurationMs, maps:get(result, State, #{})),
    persist_result(State),
    notify_players(finished, State),
    {keep_state_and_data, [{state_timeout, 5000, cleanup}]};
finished(state_timeout, cleanup, State) ->
    {stop, normal, State};
finished({call, From}, get_info, State) ->
    {keep_state_and_data, [{reply, From, match_info(finished, State)}]};
finished(_EventType, _Event, _State) ->
    keep_state_and_data.

-spec terminate(term(), atom(), map()) -> ok.
terminate(normal, _StateName, #{match_id := MatchId}) ->
    clear_state_backup(MatchId),
    pg:leave(?PG_SCOPE, {asobi_match_server, MatchId}, self()),
    ok;
terminate({shutdown, _}, _StateName, #{match_id := MatchId}) ->
    clear_state_backup(MatchId),
    pg:leave(?PG_SCOPE, {asobi_match_server, MatchId}, self()),
    ok;
terminate(_Reason, StateName, #{match_id := MatchId} = State) ->
    %% Abnormal termination — save state for recovery
    backup_state(MatchId, StateName, State),
    pg:leave(?PG_SCOPE, {asobi_match_server, MatchId}, self()),
    ok.

%% --- Internal ---

handle_join(
    From,
    PlayerId,
    #{players := Players, max_players := Max, game_module := Mod, game_state := GS} = State
) ->
    case map_size(Players) >= Max of
        true ->
            {keep_state_and_data, [{reply, From, {error, match_full}}]};
        false ->
            case Mod:join(PlayerId, GS) of
                {ok, GS1} ->
                    Players1 = Players#{
                        PlayerId => #{joined_at => erlang:system_time(millisecond)}
                    },
                    VetoTokens = maps:get(veto_tokens, State),
                    VetoCount = maps:get(veto_tokens_per_player, State),
                    VetoTokens1 = VetoTokens#{PlayerId => VetoCount},
                    State1 = State#{
                        players => Players1, game_state => GS1, veto_tokens => VetoTokens1
                    },
                    asobi_telemetry:match_player_joined(
                        maps:get(match_id, State), PlayerId
                    ),
                    State2 = notify_phase_player_joined(State1),
                    maybe_start(From, PlayerId, State2);
                {error, Reason} ->
                    {keep_state_and_data, [{reply, From, {error, Reason}}]}
            end
    end.

maybe_start(From, _PlayerId, #{players := Players, min_players := Min} = State) when
    map_size(Players) >= Min
->
    {next_state, running, State#{started_at => erlang:system_time(millisecond)}, [
        {reply, From, ok}
    ]};
maybe_start(From, _PlayerId, State) ->
    {keep_state, State, [{reply, From, ok}]}.

handle_leave(PlayerId, #{players := Players, game_module := Mod, game_state := GS} = State) ->
    case maps:is_key(PlayerId, Players) of
        false ->
            keep_state_and_data;
        true ->
            asobi_telemetry:match_player_left(maps:get(match_id, State), PlayerId),
            {ok, GS1} = Mod:leave(PlayerId, GS),
            Players1 = maps:remove(PlayerId, Players),
            case map_size(Players1) of
                0 ->
                    {stop, {shutdown, empty}, State#{players => Players1, game_state => GS1}};
                _ ->
                    {keep_state, State#{players => Players1, game_state => GS1}}
            end
    end.

apply_inputs(_Mod, [], GS) ->
    GS;
apply_inputs(Mod, [{PlayerId, Input} | Rest], GS) ->
    case Mod:handle_input(PlayerId, Input, GS) of
        {ok, GS1} ->
            apply_inputs(Mod, Rest, GS1);
        {error, Reason} ->
            ?LOG_WARNING(#{
                msg => ~"game input rejected",
                player_id => PlayerId,
                reason => Reason
            }),
            apply_inputs(Mod, Rest, GS)
    end.

broadcast_match_event(Event, Payload, #{players := Players}) ->
    maps:foreach(
        fun(PlayerId, _Meta) ->
            asobi_presence:send(PlayerId, {match_event, Event, Payload})
        end,
        Players
    ).

broadcast_state(#{players := Players, game_module := Mod, game_state := GS}) ->
    maps:foreach(
        fun(PlayerId, _Meta) ->
            PlayerState = Mod:get_state(PlayerId, GS),
            asobi_presence:send(PlayerId, {match_state, PlayerState})
        end,
        Players
    ).

notify_players(Event, #{players := Players, match_id := MatchId} = State) ->
    Payload =
        case Event of
            finished -> #{match_id => MatchId, result => maps:get(result, State, #{})}
        end,
    maps:foreach(
        fun(PlayerId, _Meta) ->
            asobi_presence:send(PlayerId, {match_event, Event, Payload})
        end,
        Players
    ).

persist_result(#{match_id := MatchId, players := Players} = State) ->
    CS = kura_changeset:cast(
        asobi_match_record,
        #{},
        #{
            id => MatchId,
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

match_info(Status, #{match_id := MatchId, players := Players} = State) ->
    Base = #{
        match_id => MatchId,
        status => Status,
        player_count => map_size(Players),
        players => maps:keys(Players),
        mode => maps:get(mode, State, undefined)
    },
    case maps:get(phase_state, State, undefined) of
        undefined -> Base;
        PS -> Base#{phase => asobi_phase:info(PS)}
    end.

maybe_start_vote(Mod, #{game_state := GS} = State) ->
    case erlang:function_exported(Mod, vote_requested, 1) of
        false ->
            State;
        true ->
            case Mod:vote_requested(GS) of
                {ok, VoteConfig} when is_map(VoteConfig) ->
                    do_start_vote(Mod, VoteConfig, State);
                _ ->
                    State
            end
    end.

do_start_vote(
    Mod, VoteConfig, #{match_id := MatchId, players := Players, game_state := GS} = State
) ->
    FullConfig = build_vote_config(VoteConfig, MatchId, Players, State),
    case asobi_vote_sup:start_vote(FullConfig) of
        {ok, VotePid} ->
            VoteId = maps:get(vote_id, FullConfig),
            Active = maps:get(active_votes, State, #{}),
            State1 = State#{active_votes => Active#{VoteId => VotePid}},
            notify_vote_started(Mod, GS, State1);
        {error, _} ->
            State
    end.

build_vote_config(VoteConfig, MatchId, Players, State) ->
    VoteId = maps:get(vote_id, VoteConfig, asobi_id:generate()),
    PlayerIds = maps:keys(Players),
    Weights = merge_vote_weights(VoteConfig, PlayerIds, State),
    VoteConfig#{
        vote_id => VoteId,
        match_id => MatchId,
        match_pid => self(),
        eligible => PlayerIds,
        weights => Weights
    }.

merge_vote_weights(VoteConfig, PlayerIds, State) ->
    Frustration = maps:get(vote_frustration, State, #{}),
    FBonus = maps:get(frustration_bonus, State, 0),
    FWeights = build_frustration_weights(PlayerIds, Frustration, FBonus),
    BaseWeights =
        case maps:get(weights, VoteConfig, #{}) of
            BW when is_map(BW) -> BW;
            _ -> #{}
        end,
    maps:merge(FWeights, BaseWeights).

-spec build_frustration_weights([binary()], map(), number()) -> #{binary() => number()}.
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

notify_vote_started(Mod, GS, State) ->
    case erlang:function_exported(Mod, vote_started, 1) of
        true -> State#{game_state => Mod:vote_started(GS)};
        false -> State
    end.

update_frustration(#{winner := undefined}, State) ->
    State;
update_frustration(
    #{winner := Winner, votes_cast := VotesCast}, #{vote_frustration := Frustration} = State
) ->
    Frustration1 = maps:fold(
        fun(PlayerId, Vote, Acc) ->
            case Vote =:= Winner of
                true -> maps:remove(PlayerId, Acc);
                false -> Acc#{PlayerId => maps:get(PlayerId, Acc, 0) + 1}
            end
        end,
        Frustration,
        VotesCast
    ),
    State#{vote_frustration => Frustration1};
update_frustration(_Result, State) ->
    State.

backup_state(MatchId, Status, State) ->
    try
        %% Strip non-serializable data (pids, active votes)
        SafeState = maps:without([active_votes], State),
        ets:insert(?STATE_TABLE, {MatchId, Status, SafeState})
    catch
        error:badarg -> ok
    end.

recover_state(MatchId) ->
    try
        case ets:lookup(?STATE_TABLE, MatchId) of
            [{MatchId, Status, SavedState}] ->
                ets:delete(?STATE_TABLE, MatchId),
                {ok, Status, SavedState#{input_queue => [], active_votes => #{}}};
            [] ->
                none
        end
    catch
        error:badarg -> none
    end.

clear_state_backup(MatchId) ->
    try
        ets:delete(?STATE_TABLE, MatchId)
    catch
        error:badarg -> ok
    end.

%% --- Internal: Phases ---

tick_phases(_DeltaMs, #{phase_state := undefined} = State) ->
    State;
tick_phases(DeltaMs, #{phase_state := PS, game_module := Mod, game_state := GS} = State) ->
    {Events, PS1} = asobi_phase:tick(DeltaMs, PS),
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

%% --- Internal: Reconnection ---

init_reconnect(Config) ->
    case maps:get(reconnect, Config, undefined) of
        undefined -> undefined;
        Policy when is_map(Policy) -> asobi_reconnect:new(Policy)
    end.

tick_reconnect(_DeltaMs, #{reconnect_state := undefined} = State) ->
    State;
tick_reconnect(DeltaMs, #{reconnect_state := RS} = State) ->
    {Events, RS1} = asobi_reconnect:tick(DeltaMs, RS),
    State1 = State#{reconnect_state => RS1},
    handle_reconnect_events(Events, State1).

handle_reconnect_events([], State) ->
    State;
handle_reconnect_events([{grace_expired, PlayerId, Action} | Rest], State) ->
    State1 =
        case Action of
            remove ->
                #{players := Players, game_module := Mod, game_state := GS} = State,
                case maps:is_key(PlayerId, Players) of
                    false ->
                        State;
                    true ->
                        {ok, GS1} = Mod:leave(PlayerId, GS),
                        State#{
                            players => maps:remove(PlayerId, Players),
                            game_state => GS1
                        }
                end;
            _ ->
                State
        end,
    handle_reconnect_events(Rest, State1);
handle_reconnect_events([_ | Rest], State) ->
    handle_reconnect_events(Rest, State).

generate_id() ->
    asobi_id:generate().
