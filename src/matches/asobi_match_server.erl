-module(asobi_match_server).
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

-include_lib("kernel/include/logger.hrl").

-export([
    start_link/1,
    join/2,
    join/3,
    leave/2,
    handle_input/3,
    get_info/1,
    get_info/2,
    pause/1,
    resume/1,
    cancel/1
]).
-export([reconnect/2]).
-export([listing_info/1]).
-export([whereis/1]).

-define(PG_SCOPE, nova_scope).
-export([start_vote/2, cast_vote/4, use_veto/3, broadcast_event/3, set_joinable/2]).
-export([callback_mode/0, init/1, terminate/3]).
-export([waiting/3, running/3, paused/3, finished/3]).

-include_lib("kernel/include/logger.hrl").

%% 10 ticks/sec
-define(DEFAULT_TICK_RATE, 100).
-define(DEFAULT_MIN_PLAYERS, 2).
-define(DEFAULT_MAX_PLAYERS, 10).
-define(WAITING_TIMEOUT, 60000).
-define(STATE_TABLE, asobi_match_state).
%% #304: mirrors asobi_ws_handler's ?WS_MAX_PAYLOAD_BYTES. game.broadcast's
%% payload is fanned out to every player in the match, so an unbounded
%% payload multiplies egress bandwidth and per-socket buffer memory by
%% player count; bound it the same way the inbound frame is bounded.
-define(MAX_BROADCAST_PAYLOAD_BYTES, 65536).

%% --- Public API ---

-spec start_link(map()) -> gen_statem:start_ret().
start_link(Config) ->
    gen_statem:start_link(?MODULE, Config, []).

-spec join(pid(), binary()) -> ok | {error, term()}.
join(Pid, PlayerId) ->
    join(Pid, PlayerId, #{}).

-doc """
Join carrying an opaque join context from the client. asobi does not
interpret it; it reaches the game module's `join/3` if it exports one.
""".
-spec join(pid(), binary(), map()) -> ok | {error, term()}.
join(Pid, PlayerId, Ctx) when is_map(Ctx) ->
    case gen_statem:call(Pid, {join, PlayerId, Ctx}) of
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

%% asobi#194: mirrors asobi_world_server:get_info/2; see asobi_discovery's doc.
-spec get_info(pid(), listing) -> map().
get_info(Pid, listing) ->
    case gen_statem:call(Pid, {get_info, listing}) of
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

-spec reconnect(pid(), binary()) -> ok | {error, term()}.
reconnect(Pid, PlayerId) when is_binary(PlayerId) ->
    case gen_statem:call(Pid, {reconnect, PlayerId}) of
        ok -> ok;
        {error, _} = Err -> Err
    end.

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

-doc """
Open or close the match to new joins.

A closed match keeps running and keeps its roster; it answers every further
join with `match_locked`. This is the runtime half of joinability - `listed`
decides whether a match is advertised by `m:asobi_match_lobby`, and an
unlisted match is still joinable by id, so hiding a match is not closing it.

Asynchronous because the caller is usually the match's own Lua VM
(`game.match.set_joinable`), which runs inside this process. An Erlang game
module is in the same position - its callbacks run here too - so it closes
its own match with `set_joinable(self(), false)` from `tick/1`, `join/2` or
any other callback.
""".
-spec set_joinable(pid(), boolean()) -> ok.
set_joinable(Pid, Joinable) when is_boolean(Joinable) ->
    gen_statem:cast(Pid, {set_joinable, Joinable}).

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
    %% asobi#482: a flat group as well as the per-id one, so the node-wide match
    %% count is a pg lookup rather than a gen_statem:call per match. Mirrors
    %% asobi_owned_worlds_global on the world side. Unconditional, so a
    %% matchmaker-spawned match counts toward the same node resource as one
    %% created through match.find_or_create. Membership is tied to the process,
    %% so it clears on death with no bookkeeping.
    pg:join(?PG_SCOPE, asobi_live_matches_global, self()),
    case recover_state(MatchId) of
        {ok, SavedStatus, SavedState} ->
            logger:notice(#{msg => ~"match recovered", match_id => MatchId, status => SavedStatus}),
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
                        case GameMod:phases(GameConfig) of
                            [] -> {[], undefined};
                            Phases -> asobi_phase:init(Phases)
                        end;
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
                listed => maps:get(listed, Config, false),
                %% Not read from Config: a match that started closed could
                %% never be joined, so it would sit in `waiting` until the
                %% timeout killed it. Unlike `listed`, this is runtime-only -
                %% `set_joinable/2` is the whole interface.
                joinable => true,
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
waiting({call, From}, {join, PlayerId, Ctx}, State) ->
    handle_join(From, PlayerId, Ctx, State);
waiting({call, From}, get_info, State) ->
    {keep_state_and_data, [{reply, From, match_info(waiting, State)}]};
waiting({call, From}, {get_info, listing}, State) ->
    {keep_state_and_data, [{reply, From, match_info(waiting, State, false)}]};
waiting(state_timeout, waiting_timeout, State) ->
    {stop, {shutdown, timeout}, State};
waiting(cast, {leave, PlayerId}, State) ->
    handle_leave(PlayerId, State);
%% Gathering is exactly when a game wants to tell the room someone arrived.
%% Players are already in `players` and presence is live, so delivery works
%% here identically to `running` - there was simply no clause, and a Lua
%% `game.broadcast` from a join callback crashed the match on function_clause.
waiting(cast, {broadcast_event, Event, Payload}, State) ->
    broadcast_match_event(Event, Payload, State),
    keep_state_and_data;
%% asobi#285: the match hasn't started yet, so no reconnect_state grace
%% applies pre-match-start - a session dying while still gathering players
%% is a leave, same as running's no-reconnect-policy branch. Without this
%% clause the DOWN message hit no clause here and crashed the match server,
%% taking every player already in the lobby down with it.
waiting(info, {'DOWN', _MonRef, process, DownPid, _Reason}, State) when is_pid(DownPid) ->
    case find_player_by_pid(DownPid, State) of
        {ok, PlayerId} -> handle_leave(PlayerId, State);
        none -> keep_state_and_data
    end;
%% asobi#285: without this clause a reconnect/2 call while still waiting hit
%% no clause and crashed the match server (waiting/3 has no catch-all) -
%% handle_reconnect_call/3 already replies {error, no_reconnect_policy} or
%% {error, not_in_match} correctly for this state, it was just unreachable.
waiting({call, From}, {reconnect, PlayerId}, State) when is_binary(PlayerId) ->
    handle_reconnect_call(From, PlayerId, State);
%% asobi#290: asobi_ws_handler casts input as soon as the client holds a
%% match_pid, which can be before the last player has joined - waiting/3 had
%% no clause and no catch-all, so early input crashed the whole match. The
%% input is dropped rather than queued: there is no tick before `running` to
%% apply it, so queuing would both replay stale pre-match input on the first
%% tick and grow without bound for the whole waiting window.
waiting(cast, {input, PlayerId, _Input}, #{match_id := MatchId}) ->
    log_dropped_input(MatchId, PlayerId, match_not_started),
    keep_state_and_data;
%% asobi#290: no votes before the match starts - explicit replies, because
%% waiting/3 deliberately has no catch-all and these would otherwise crash
%% the match with function_clause.
waiting({call, From}, {start_vote, _VoteConfig}, _State) ->
    {keep_state_and_data, [{reply, From, {error, match_not_started}}]};
waiting({call, From}, {cast_vote, _PlayerId, _VoteId, _OptionId}, _State) ->
    {keep_state_and_data, [{reply, From, {error, match_not_started}}]};
waiting({call, From}, {use_veto, _PlayerId, _VoteId}, _State) ->
    {keep_state_and_data, [{reply, From, {error, match_not_started}}]};
waiting(cast, {set_joinable, Joinable}, State) ->
    {keep_state, State#{joinable => Joinable}};
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
                    {State3, Removed} = tick_reconnect(TickRate, tick_phases(TickRate, State2)),
                    case roster_emptied(State3, Removed) of
                        true ->
                            {stop, {shutdown, empty}, State3};
                        false ->
                            case asobi_phase:is_complete(maps:get(phase_state, State3)) of
                                true ->
                                    {next_state, finished, State3#{
                                        result => #{status => ~"phases_complete"}
                                    }};
                                false ->
                                    broadcast_state(State3),
                                    {keep_state, State3, [{state_timeout, TickRate, tick}]}
                            end
                    end;
                {finished, Result, GS2} ->
                    {next_state, finished, State#{game_state => GS2, result => Result}}
            end;
        false ->
            State1 = State#{game_state => GS1, input_queue => []},
            State2 = maybe_start_vote(Mod, State1),
            State3 = tick_phases(TickRate, State2),
            case asobi_phase:is_complete(maps:get(phase_state, State3)) of
                true ->
                    {next_state, finished, State3#{
                        result => #{status => ~"phases_complete"}
                    }};
                false ->
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
running(
    info, {'DOWN', _MonRef, process, DownPid, _Reason}, #{reconnect_state := undefined} = State
) when is_pid(DownPid) ->
    %% No reconnect policy active — a session DOWN is treated as an explicit
    %% leave (player removed from match; match shuts down if empty).
    case find_player_by_pid(DownPid, State) of
        {ok, PlayerId} -> handle_leave(PlayerId, State);
        none -> keep_state_and_data
    end;
running(info, {'DOWN', _MonRef, process, DownPid, _Reason}, #{reconnect_state := RS} = State) when
    is_pid(DownPid)
->
    %% Reconnect policy active — start the grace timer instead of removing
    %% the player. asobi_reconnect:tick/2 (called every match tick by
    %% tick_reconnect/2) will fire grace_expired if the player doesn't come
    %% back in time.
    case find_player_by_pid(DownPid, State) of
        {ok, PlayerId} ->
            Now = erlang:system_time(millisecond),
            {Events, RS1} = asobi_reconnect:disconnect(PlayerId, Now, RS),
            {State1, Removed} = handle_reconnect_events(Events, State#{reconnect_state => RS1}),
            case roster_emptied(State1, Removed) of
                true -> {stop, {shutdown, empty}, State1};
                false -> {keep_state, State1}
            end;
        none ->
            keep_state_and_data
    end;
running({call, From}, {reconnect, PlayerId}, State) when is_binary(PlayerId) ->
    handle_reconnect_call(From, PlayerId, State);
running({call, From}, pause, State) ->
    {next_state, paused, State, [{reply, From, ok}]};
running({call, From}, resume, _State) ->
    {keep_state_and_data, [{reply, From, {error, not_paused}}]};
running({call, From}, get_info, State) ->
    {keep_state_and_data, [{reply, From, match_info(running, State)}]};
running({call, From}, {get_info, listing}, State) ->
    {keep_state_and_data, [{reply, From, match_info(running, State, false)}]};
running({call, From}, {join, PlayerId, Ctx}, State) ->
    handle_join(From, PlayerId, Ctx, State);
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
    is_binary(PlayerId), (is_binary(OptionId) orelse is_list(OptionId))
->
    handle_cast_vote(From, PlayerId, VoteId, OptionId, State);
%% asobi#462: a valid option_id is a binary (plurality/weighted) or a list of
%% binaries (approval/ranked - see asobi_vote_server:validate_option/2). A
%% vote.cast whose option_id is a JSON number, bool, null or object misses the
%% guard above; running/3 has no catch-all, so without this fallback the
%% function_clause crashes the whole match - every player in it - on one
%% malformed frame. Degrade to the invalid_option asobi_vote_server already
%% reports for a bad option, and never forward the junk value on. A list that
%% carries a non-binary passes the guard and is rejected downstream by
%% validate_option, also as invalid_option, with no crash.
running({call, From}, {cast_vote, _PlayerId, _VoteId, _OptionId}, _State) ->
    {keep_state_and_data, [{reply, From, {error, invalid_option}}]};
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
%% asobi#462: mirrors the cast_vote fallback above - a use_veto that misses the
%% is_binary(PlayerId) guard would otherwise crash the whole match on
%% function_clause. PlayerId is always resolved server-side, so this is
%% defence-in-depth, replying the same invalid_option rather than a crash.
running({call, From}, {use_veto, _PlayerId, _VoteId}, _State) ->
    {keep_state_and_data, [{reply, From, {error, invalid_option}}]};
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
    {keep_state, State#{active_votes => Active}};
running(cast, {set_joinable, Joinable}, State) ->
    {keep_state, State#{joinable => Joinable}}.

%% --- paused state ---

-spec paused(gen_statem:event_type() | enter, term(), map()) ->
    gen_statem:state_enter_result(atom()).
paused(enter, _OldState, _State) ->
    keep_state_and_data;
paused({call, From}, resume, State) ->
    {next_state, running, State, [{reply, From, ok}]};
paused({call, From}, pause, _State) ->
    {keep_state_and_data, [{reply, From, {error, already_paused}}]};
%% asobi#285: without this clause a reconnect/2 call while paused fell
%% through to the catch-all below, which never replies - the caller's
%% gen_statem:call/2 (default timeout infinity) would hang forever. Needed
%% now that a session DOWN while paused starts real grace (see the 'DOWN'
%% clauses below): a player in grace during a pause must be able to
%% reconnect before resume/1 is called.
paused({call, From}, {reconnect, PlayerId}, State) when is_binary(PlayerId) ->
    handle_reconnect_call(From, PlayerId, State);
paused(cast, cancel, State) ->
    {next_state, finished, State#{result => #{status => ~"cancelled"}}};
paused(cast, {leave, PlayerId}, State) ->
    handle_leave(PlayerId, State);
paused({call, From}, get_info, State) ->
    {keep_state_and_data, [{reply, From, match_info(paused, State)}]};
paused({call, From}, {get_info, listing}, State) ->
    {keep_state_and_data, [{reply, From, match_info(paused, State, false)}]};
paused(cast, {broadcast_event, Event, Payload}, State) ->
    broadcast_match_event(Event, Payload, State),
    keep_state_and_data;
%% asobi#290: a paused match has no tick to apply input against, so input is
%% dropped, not queued (a long pause would otherwise grow the queue without
%% bound and replay stale input on resume). Explicit clause so the drop is
%% observable instead of being silently swallowed by the catch-all below.
paused(cast, {input, PlayerId, _Input}, #{match_id := MatchId}) ->
    log_dropped_input(MatchId, PlayerId, match_paused),
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
%% asobi#285: mirrors running's pair of 'DOWN' clauses. Without these, a
%% session dying while paused fell through to the catch-all below and was
%% silently swallowed - no grace started, no leave, the player stuck in the
%% roster forever (and, with no reconnect policy, the match could then never
%% empty and never shut down).
paused(
    info, {'DOWN', _MonRef, process, DownPid, _Reason}, #{reconnect_state := undefined} = State
) when is_pid(DownPid) ->
    case find_player_by_pid(DownPid, State) of
        {ok, PlayerId} -> handle_leave(PlayerId, State);
        none -> keep_state_and_data
    end;
paused(info, {'DOWN', _MonRef, process, DownPid, _Reason}, #{reconnect_state := RS} = State) when
    is_pid(DownPid)
->
    case find_player_by_pid(DownPid, State) of
        {ok, PlayerId} ->
            Now = erlang:system_time(millisecond),
            {Events, RS1} = asobi_reconnect:disconnect(PlayerId, Now, RS),
            {State1, Removed} = handle_reconnect_events(Events, State#{reconnect_state => RS1}),
            case roster_emptied(State1, Removed) of
                true -> {stop, {shutdown, empty}, State1};
                false -> {keep_state, State1}
            end;
        none ->
            keep_state_and_data
    end;
%% A pause does not decide joinability, so an operator closing a match while
%% it is paused must still be honoured - the cast catch-all below would drop
%% it silently and the match would reopen on resume.
paused(cast, {set_joinable, Joinable}, State) ->
    {keep_state, State#{joinable => Joinable}};
%% asobi#290: every call with no clause above (start_vote, cast_vote,
%% use_veto, join) used to fall through to the catch-all, which never
%% replies - gen_statem:call/2 defaults to timeout infinity, so the caller
%% hung forever. Replying an error keeps that defect closed for calls added
%% later too; only non-call events reach the catch-all now.
paused({call, From}, _Event, _State) ->
    {keep_state_and_data, [{reply, From, {error, match_paused}}]};
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
finished({call, From}, {get_info, listing}, State) ->
    {keep_state_and_data, [{reply, From, match_info(finished, State, false)}]};
%% A game ending its match from `tick` and broadcasting the result in the
%% same callback lands here. Without this clause the catch-all below
%% swallows it silently, which reads as a client bug. Players are still in
%% `players` for the cleanup window.
finished(cast, {broadcast_event, Event, Payload}, State) ->
    broadcast_match_event(Event, Payload, State),
    keep_state_and_data;
%% asobi#469: any other call landing here while the finished match waits out
%% its 5s cleanup timer (a late vote.cast/vote.veto while the session still
%% holds match_pid, or any call added later) must reply - an unanswered
%% {call, From} hangs the caller (asobi_ws_handler, an infinity
%% gen_statem:call) until this server stops at its cleanup timeout. Replying
%% not_in_match returns immediately with the same registered 409 the
%% dead/finished-fabric path in vote_call/1 uses, so "the match is over" is one
%% code a client can branch on. Only non-call events reach the swallow
%% catch-all below now.
finished({call, From}, _Request, _State) ->
    {keep_state_and_data, [{reply, From, {error, not_in_match}}]};
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

%% Rate-limited: input arrives per client per tick, so an unbounded log here
%% would be a flood channel a client controls.
%% `term()` for the player id: both call sites take it straight off a client
%% frame, and this is a log line - narrowing it to `binary()` would put a
%% function_clause on the path that exists to record a dropped input.
-spec log_dropped_input(binary(), term(), atom()) -> ok.
log_dropped_input(MatchId, PlayerId, Reason) ->
    case asobi_script_log_limiter:allow({?MODULE, input_dropped, MatchId}) of
        {true, Dropped} ->
            ?LOG_INFO(#{
                event => match_input_dropped,
                match_id => MatchId,
                player_id => PlayerId,
                reason => Reason,
                suppressed_since_last => Dropped
            }),
            ok;
        false ->
            ok
    end.

handle_join(
    From,
    PlayerId,
    Ctx,
    #{players := Players, max_players := Max, game_module := Mod, game_state := GS} = State
) ->
    %% Defaulted rather than matched: a match recovered from a backup written
    %% by an older node has no `joinable` key, and such a match must stay
    %% joinable rather than crash the join.
    case {maps:get(joinable, State, true), map_size(Players) >= Max} of
        {false, _} ->
            {keep_state_and_data, [{reply, From, {error, match_locked}}]};
        {true, true} ->
            {keep_state_and_data, [{reply, From, {error, match_full}}]};
        {true, false} ->
            case asobi_game_join:invoke(Mod, PlayerId, Ctx, GS) of
                {ok, GS1} ->
                    %% Monitor the player session so we can run reconnect grace
                    %% (or immediate cleanup) when the WS process dies. Mirrors
                    %% asobi_world_server's handle_join monitor setup.
                    %% asobi#280: no live session degrades gracefully (no
                    %% monitor) rather than crashing on
                    %% monitor(process, undefined).
                    SessionPid = find_player_pid(PlayerId),
                    MonRef =
                        case SessionPid of
                            undefined ->
                                ?LOG_WARNING(#{
                                    event => match_join_no_live_session,
                                    match_id => maps:get(match_id, State),
                                    player_id => PlayerId
                                }),
                                undefined;
                            _ ->
                                erlang:monitor(process, SessionPid)
                        end,
                    Players1 = Players#{
                        PlayerId => #{
                            joined_at => erlang:system_time(millisecond),
                            session_pid => SessionPid,
                            monitor_ref => MonRef
                        }
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
                    %% The session learns its match_pid here, not from
                    %% whoever called join/3. Mirrors asobi_world_server's
                    %% {world_joined, ...}. Without it a player who joined by
                    %% id - `match.join` after `match.list`, ie the backfill
                    %% path - has no match_pid on their session, so their
                    %% `match.input` is answered with `not_in_match` and
                    %% their `match.leave` silently does nothing. The
                    %% matchmaker used to send this itself, and only it, which
                    %% is why the defect was invisible on the matchmade path.
                    asobi_presence:send(PlayerId, {match_joined, self()}),
                    maybe_start(From, State2);
                {error, Reason} ->
                    {keep_state_and_data, [{reply, From, {error, Reason}}]}
            end
    end.

%% `started_at` is stamped on the waiting -> running transition only. Stamping
%% it on every join that clears min_players would let each backfill join into
%% an already-running match restart the clock, so the persisted match record
%% would report a duration measured from the last joiner.
maybe_start(From, #{players := Players, min_players := Min} = State) when
    map_size(Players) >= Min
->
    case maps:get(started_at, State, undefined) of
        undefined ->
            {next_state, running, State#{started_at => erlang:system_time(millisecond)}, [
                {reply, From, ok}
            ]};
        _ ->
            {keep_state, State, [{reply, From, ok}]}
    end;
maybe_start(From, State) ->
    {keep_state, State, [{reply, From, ok}]}.

handle_leave(PlayerId, #{players := Players, game_module := Mod, game_state := GS} = State) ->
    case maps:is_key(PlayerId, Players) of
        false ->
            keep_state_and_data;
        true ->
            asobi_telemetry:match_player_left(maps:get(match_id, State), PlayerId),
            %% The counterpart to `match_joined`: a session that keeps a
            %% match_pid after leaving sends its input to a match it is no
            %% longer in, and never gets the `not_in_match` hint that exists
            %% to make exactly that debuggable (asobi#236).
            asobi_presence:send(PlayerId, {match_left, self()}),
            %% Demonitor the player session if we set one up at join time so
            %% a stale 'DOWN' message can't trigger a second leave path.
            case maps:get(monitor_ref, maps:get(PlayerId, Players, #{}), undefined) of
                undefined -> ok;
                MonRef -> erlang:demonitor(MonRef, [flush])
            end,
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

broadcast_match_event(Event, Payload, #{players := Players, match_id := MatchId}) ->
    case payload_within_limit(Payload) of
        true ->
            maps:foreach(
                fun(PlayerId, _Meta) ->
                    asobi_presence:send(PlayerId, {match_event, Event, Payload})
                end,
                Players
            );
        false ->
            logger:warning(#{
                msg => ~"game_broadcast_rejected",
                namespace => ~"match",
                reason => ~"payload_too_large",
                match_id => MatchId
            })
    end.

%% #304: measured on the encoded wire form (same unit ?WS_MAX_PAYLOAD_BYTES
%% bounds inbound), not the raw Erlang term — a small term can still encode
%% to an oversized JSON payload. An unencodable payload is rejected too,
%% same as an oversized one, rather than crashing every subscriber's
%% json:encode/1 downstream in asobi_ws_handler.
-spec payload_within_limit(map()) -> boolean().
payload_within_limit(Payload) ->
    try iolist_size(json:encode(Payload)) of
        Size -> Size =< ?MAX_BROADCAST_PAYLOAD_BYTES
    catch
        _:_ -> false
    end.

broadcast_state(#{players := Players, game_module := Mod, game_state := GS}) ->
    case erlang:function_exported(Mod, get_state, 1) of
        true ->
            broadcast_shared_state(Mod, GS, Players);
        false ->
            broadcast_per_player_state(Mod, GS, Players)
    end.

%% One get_state/1 call and one encode per tick, whatever the roster is
%% (ADR 0001). Both forms go to asobi_presence because only it knows which
%% roster entries are bots: a bot reads the state as a term and would
%% otherwise have to decode the frame it was handed, once per tick each.
broadcast_shared_state(Mod, GS, Players) ->
    SharedState = Mod:get_state(GS),
    Payload = #{~"type" => ~"match.state", ~"payload" => SharedState},
    PreEncoded = iolist_to_binary(json:encode(Payload)),
    maps:foreach(
        fun(PlayerId, _Meta) ->
            asobi_presence:send_match_state(PlayerId, SharedState, PreEncoded)
        end,
        Players
    ).

broadcast_per_player_state(Mod, GS, Players) ->
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

%% asobi#329: the match record row and the participants' stats counters are
%% one write. `match_records.id` is the match id, so a second pass over a
%% match that already finished (a recovered server re-entering `finished`)
%% loses the insert on the primary key and rolls the counters back with it -
%% that primary key is what makes games_played move exactly once per match.
persist_result(#{match_id := MatchId, players := Players} = State) ->
    Result = maps:get(result, State, #{}),
    CS = kura_changeset:cast(
        asobi_match_record,
        #{},
        #{
            id => MatchId,
            mode => maps:get(mode, State, undefined),
            status => ~"finished",
            players => maps:keys(Players),
            result => Result,
            started_at => asobi_match_record:to_timestamp(maps:get(started_at, State, undefined)),
            finished_at => asobi_match_record:to_timestamp(erlang:system_time(millisecond))
        },
        [id, mode, status, players, result, started_at, finished_at]
    ),
    _ = asobi_repo:transaction(fun() ->
        case asobi_repo:insert(CS) of
            {ok, _} ->
                asobi_player_stats:record_match(maps:keys(Players), Result);
            {error, Reason} ->
                ?LOG_WARNING(#{
                    event => match_record_persist_failed, match_id => MatchId, reason => Reason
                })
        end
    end),
    ok.

match_info(Status, State) ->
    match_info(Status, State, true).

match_info(Status, #{match_id := MatchId, players := Players} = State, IncludeRoster) ->
    Base0 = #{
        match_id => MatchId,
        status => Status,
        player_count => map_size(Players),
        mode => maps:get(mode, State, undefined),
        max_players => maps:get(max_players, State, ?DEFAULT_MAX_PLAYERS),
        listed => maps:get(listed, State, false),
        joinable => maps:get(joinable, State, true)
    },
    Base =
        case IncludeRoster of
            true -> Base0#{players => maps:keys(Players)};
            false -> Base0
        end,
    case maps:get(phase_state, State, undefined) of
        undefined -> Base;
        PS -> Base#{phase => asobi_phase:info(PS)}
    end.

-doc """
Projection of `get_info/1` for callers who are not in the match.

Mirrors `asobi_world_server:listing_info/1`. `get_info/1` carries the full
`players` roster and the server-side `listed` flag; neither reaches a
browsing client. `joinable` does: a client browsing for a match to join has
to be able to tell a match that will take it from one that has closed, and
without it the only way to find out is to attempt the join and be refused.
""".
-spec listing_info(map()) -> map().
listing_info(Info) ->
    Base = maps:with([match_id, status, player_count, max_players, mode, joinable], Info),
    case maps:get(phase, Info, undefined) of
        Phase when is_map(Phase) ->
            Base#{phase => maps:with([status, phase, remaining_ms, start_condition], Phase)};
        _ ->
            Base
    end.

%% asobi#462: extracted from the running/3 cast_vote clause so OptionId is a
%% plain term() here (a binary option or an approval/ranked list) rather than
%% the guard-narrowed union, mirroring asobi_world_server:handle_cast_vote/5.
%% asobi_vote_server:validate_option/2 is the one gate for whether the option
%% is valid, list or scalar.
handle_cast_vote(From, PlayerId, VoteId, OptionId, State) ->
    Active = maps:get(active_votes, State, #{}),
    case maps:get(VoteId, Active, undefined) of
        undefined ->
            {keep_state_and_data, [{reply, From, {error, vote_not_found}}]};
        VotePid ->
            Result = asobi_vote_server:cast_vote(VotePid, PlayerId, OptionId),
            {keep_state_and_data, [{reply, From, Result}]}
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
            %% An ETS read is `term()`; the map guard is the boundary. A row
            %% that is not a map is a corrupt crash-recovery entry, and
            %% recovering nothing is better than restoring a shape the match
            %% server will then index into.
            [{MatchId, Status, SavedState}] when is_map(SavedState) ->
                ets:delete(?STATE_TABLE, MatchId),
                {ok, Status, SavedState#{input_queue => [], active_votes => #{}}};
            [{MatchId, _Status, _SavedState}] ->
                ets:delete(?STATE_TABLE, MatchId),
                none;
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
    {State, false};
tick_reconnect(DeltaMs, #{reconnect_state := RS} = State) ->
    {Events, RS1} = asobi_reconnect:tick(DeltaMs, RS),
    handle_reconnect_events(Events, State#{reconnect_state => RS1}).

handle_reconnect_call(From, PlayerId, #{players := Players, reconnect_state := RS} = State) when
    RS =/= undefined
->
    case maps:is_key(PlayerId, Players) of
        false ->
            {keep_state_and_data, [{reply, From, {error, not_in_match}}]};
        true ->
            %% asobi#280: checked before touching reconnect_state or the old
            %% monitor at all, so a missing session leaves this a pure no-op
            %% rather than a monitor(process, undefined) crash - mirrors the
            %% asobi_world_server handle_reconnect_call fix from asobi#277.
            case find_player_pid(PlayerId) of
                undefined ->
                    ?LOG_WARNING(#{
                        event => match_reconnect_no_live_session,
                        match_id => maps:get(match_id, State),
                        player_id => PlayerId
                    }),
                    {keep_state_and_data, [{reply, From, {error, no_live_session}}]};
                NewSessionPid ->
                    {_Events, RS1} = asobi_reconnect:reconnect(PlayerId, RS),
                    %% Re-monitor: the new session pid is whoever is currently
                    %% registered as the WS owner for this player_id.
                    PlayerMeta0 = maps:get(PlayerId, Players),
                    case maps:get(monitor_ref, PlayerMeta0, undefined) of
                        undefined -> ok;
                        OldRef -> erlang:demonitor(OldRef, [flush])
                    end,
                    NewMonRef = erlang:monitor(process, NewSessionPid),
                    PlayerMeta1 = PlayerMeta0#{
                        session_pid => NewSessionPid,
                        monitor_ref => NewMonRef
                    },
                    Players1 = Players#{PlayerId => PlayerMeta1},
                    {keep_state, State#{reconnect_state => RS1, players => Players1}, [
                        {reply, From, ok}
                    ]}
            end
    end;
handle_reconnect_call(From, _PlayerId, _State) ->
    {keep_state_and_data, [{reply, From, {error, no_reconnect_policy}}]}.

%% widgrensit/asobi#280: fall back to undefined rather than self() when a
%% player has no live pg-registered session, mirroring the asobi#277 fix in
%% asobi_world_server - self() would silently monitor/track this match
%% server's own pid as that player's session instead of failing visibly.
-spec find_player_pid(binary()) -> pid() | undefined.
find_player_pid(PlayerId) ->
    case pg:get_members(?PG_SCOPE, {player, PlayerId}) of
        [Pid | _] -> Pid;
        [] -> undefined
    end.

-spec find_player_by_pid(pid(), map()) -> {ok, binary()} | none.
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

handle_reconnect_events(Events, State) ->
    handle_reconnect_events(Events, State, false).

handle_reconnect_events([], State, Removed) ->
    {State, Removed};
handle_reconnect_events([{grace_expired, PlayerId, remove} | Rest], State, Removed) ->
    #{players := Players, game_module := Mod, game_state := GS} = State,
    case maps:is_key(PlayerId, Players) of
        false ->
            handle_reconnect_events(Rest, State, Removed);
        true ->
            {ok, GS1} = Mod:leave(PlayerId, GS),
            State1 = State#{
                players => maps:remove(PlayerId, Players),
                game_state => GS1
            },
            handle_reconnect_events(Rest, State1, true)
    end;
handle_reconnect_events([_ | Rest], State, Removed) ->
    handle_reconnect_events(Rest, State, Removed).

%% asobi#292: grace expiry removes a player without going through
%% handle_leave/2, so the "last player gone" shutdown has to be applied by
%% every caller of handle_reconnect_events/2 as well.
roster_emptied(_State, false) ->
    false;
roster_emptied(#{players := Players}, true) ->
    map_size(Players) =:= 0.

generate_id() ->
    asobi_id:generate().
