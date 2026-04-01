-module(asobi_match_server).
-behaviour(gen_statem).

-export([start_link/1, join/2, leave/2, handle_input/3, get_info/1, pause/1, resume/1, cancel/1]).
-export([start_vote/2, cast_vote/4, broadcast_event/3]).
-export([callback_mode/0, init/1, terminate/3]).
-export([waiting/3, running/3, paused/3, finished/3]).

%% 10 ticks/sec
-define(DEFAULT_TICK_RATE, 100).
-define(DEFAULT_MIN_PLAYERS, 2).
-define(DEFAULT_MAX_PLAYERS, 10).
-define(WAITING_TIMEOUT, 60000).

%% --- Public API ---

-spec start_link(map()) -> {ok, pid()}.
start_link(Config) ->
    gen_statem:start_link(?MODULE, Config, []).

-spec join(pid(), binary()) -> ok | {error, term()}.
join(Pid, PlayerId) ->
    gen_statem:call(Pid, {join, PlayerId}).

-spec leave(pid(), binary()) -> ok.
leave(Pid, PlayerId) ->
    gen_statem:cast(Pid, {leave, PlayerId}).

-spec handle_input(pid(), binary(), map()) -> ok.
handle_input(Pid, PlayerId, Input) ->
    gen_statem:cast(Pid, {input, PlayerId, Input}).

-spec get_info(pid()) -> map().
get_info(Pid) ->
    gen_statem:call(Pid, get_info).

-spec pause(pid()) -> ok | {error, term()}.
pause(Pid) ->
    gen_statem:call(Pid, pause).

-spec resume(pid()) -> ok | {error, term()}.
resume(Pid) ->
    gen_statem:call(Pid, resume).

-spec cancel(pid()) -> ok.
cancel(Pid) ->
    gen_statem:cast(Pid, cancel).

-spec start_vote(pid(), map()) -> {ok, pid()} | {error, term()}.
start_vote(Pid, VoteConfig) ->
    gen_statem:call(Pid, {start_vote, VoteConfig}).

-spec cast_vote(pid(), binary(), binary(), binary()) -> ok | {error, term()}.
cast_vote(Pid, PlayerId, VoteId, OptionId) ->
    gen_statem:call(Pid, {cast_vote, PlayerId, VoteId, OptionId}).

-spec broadcast_event(pid(), atom(), map()) -> ok.
broadcast_event(Pid, Event, Payload) ->
    gen_statem:cast(Pid, {broadcast_event, Event, Payload}).

%% --- gen_statem callbacks ---

-spec callback_mode() -> [atom()].
callback_mode() -> [state_functions, state_enter].

-spec init(map()) -> {ok, waiting, map()}.
init(Config) ->
    MatchId = maps:get(match_id, Config, generate_id()),
    GameMod = maps:get(game_module, Config),
    GameConfig = maps:get(game_config, Config, #{}),
    {ok, GameState} = GameMod:init(GameConfig),
    State = #{
        match_id => MatchId,
        game_module => GameMod,
        game_state => GameState,
        players => #{},
        input_queue => [],
        tick_rate => maps:get(tick_rate, Config, ?DEFAULT_TICK_RATE),
        min_players => maps:get(min_players, Config, ?DEFAULT_MIN_PLAYERS),
        max_players => maps:get(max_players, Config, ?DEFAULT_MAX_PLAYERS),
        started_at => undefined
    },
    {ok, waiting, State}.

%% --- waiting state ---

-spec waiting(gen_statem:event_type(), term(), map()) -> gen_statem:state_enter_result(atom()).
waiting(enter, _OldState, _State) ->
    {keep_state_and_data, [{state_timeout, ?WAITING_TIMEOUT, waiting_timeout}]};
waiting({call, From}, {join, PlayerId}, State) ->
    handle_join(From, PlayerId, State);
waiting({call, From}, get_info, State) ->
    {keep_state_and_data, [{reply, From, match_info(waiting, State)}]};
waiting(state_timeout, waiting_timeout, State) ->
    {stop, {shutdown, timeout}, State};
waiting(cast, {leave, PlayerId}, State) ->
    handle_leave(PlayerId, State).

%% --- running state ---

-spec running(gen_statem:event_type(), term(), map()) -> gen_statem:state_enter_result(atom()).
running(enter, _OldState, #{tick_rate := TickRate} = _State) ->
    {keep_state_and_data, [{state_timeout, TickRate, tick}]};
running(state_timeout, tick, #{game_module := Mod, game_state := GS, input_queue := Queue} = State) ->
    GS1 = apply_inputs(Mod, Queue, GS),
    case erlang:function_exported(Mod, tick, 1) of
        true ->
            case Mod:tick(GS1) of
                {ok, GS2} ->
                    broadcast_state(State#{game_state => GS2}),
                    {keep_state, State#{game_state => GS2, input_queue => []}, [
                        {state_timeout, maps:get(tick_rate, State), tick}
                    ]};
                {finished, Result, GS2} ->
                    {next_state, finished, State#{game_state => GS2, result => Result}}
            end;
        false ->
            broadcast_state(State#{game_state => GS1}),
            {keep_state, State#{game_state => GS1, input_queue => []}, [
                {state_timeout, maps:get(tick_rate, State), tick}
            ]}
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
running({call, From}, {start_vote, VoteConfig}, #{match_id := MatchId, players := Players} = State) ->
    VoteId = maps:get(vote_id, VoteConfig, asobi_id:generate()),
    FullConfig = VoteConfig#{
        vote_id => VoteId,
        match_id => MatchId,
        match_pid => self(),
        eligible => maps:keys(Players)
    },
    {ok, VotePid} = asobi_vote_sup:start_vote(FullConfig),
    Active = maps:get(active_votes, State, #{}),
    {keep_state, State#{active_votes => Active#{VoteId => VotePid}}, [
        {reply, From, {ok, VotePid}}
    ]};
running({call, From}, {cast_vote, PlayerId, VoteId, OptionId}, State) ->
    Active = maps:get(active_votes, State, #{}),
    case maps:get(VoteId, Active, undefined) of
        undefined ->
            {keep_state_and_data, [{reply, From, {error, vote_not_found}}]};
        VotePid ->
            Result = asobi_vote_server:cast_vote(VotePid, PlayerId, OptionId),
            {keep_state_and_data, [{reply, From, Result}]}
    end;
running(cast, {broadcast_event, Event, Payload}, State) ->
    broadcast_match_event(Event, Payload, State),
    keep_state_and_data;
running(
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
running(info, {vote_vetoed, VoteId, _Template}, State) ->
    Active = maps:remove(VoteId, maps:get(active_votes, State, #{})),
    {keep_state, State#{active_votes => Active}}.

%% --- paused state ---

-spec paused(gen_statem:event_type(), term(), map()) -> gen_statem:state_enter_result(atom()).
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

-spec finished(gen_statem:event_type(), term(), map()) -> gen_statem:state_enter_result(atom()).
finished(enter, _OldState, State) ->
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
terminate(_Reason, _StateName, _State) ->
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
                    State1 = State#{players => Players1, game_state => GS1},
                    maybe_start(From, PlayerId, State1);
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
            logger:warning(#{
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

match_info(Status, #{match_id := MatchId, players := Players}) ->
    #{
        match_id => MatchId,
        status => Status,
        player_count => map_size(Players),
        players => maps:keys(Players)
    }.

generate_id() ->
    asobi_id:generate().
