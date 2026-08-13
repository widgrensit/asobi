-module(asobi_world_server).
-moduledoc """
A persistent, zoned world: the `gen_statem` behind large session games
(`game_type = "world"`). It partitions space into a grid of `asobi_zone`
processes, moves players between zones as they travel, runs a world-level
`post_tick`, and drives voting. Use it for MMO-style shared spaces; for
transient matches use `asobi_match_server` instead.
""".
-behaviour(gen_statem).

-include_lib("kernel/include/logger.hrl").

-export([
    start_link/1,
    join/2,
    join/3,
    join/4,
    leave/2,
    move_player/3,
    move_player/4,
    post_tick/2,
    get_info/1,
    get_info/2,
    cancel/1
]).
-export([listing_info/1]).
-export_type([listing/0]).
-export([spawn_at/3, spawn_at/4]).
-export([zone_created/3]).
-export([reconnect/2]).
-export([start_vote/2, cast_vote/4, use_veto/3]).
-export([whereis/1]).
-export([pos_to_zone/3]).
-export([callback_mode/0, init/1, terminate/3]).
-export([loading/3, running/3, finished/3]).

-define(PG_SCOPE, nova_scope).
-define(DEFAULT_GRID_SIZE, 10).
-define(DEFAULT_ZONE_SIZE, 200).
-define(DEFAULT_TICK_RATE, 50).
-define(DEFAULT_MAX_PLAYERS, 500).
-define(DEFAULT_VIEW_RADIUS, 1).
%% Fraction of zone_size a position must clear past a zone's own rectangle
%% before asobi_zone treats it as a real crossing rather than jitter -
%% widgrensit/asobi#248. A fixed fraction, not absolute units, since it
%% should scale with whatever zone_size a world picks; games wanting a
%% tighter or looser boundary can override rehome_margin per world.
-define(DEFAULT_REHOME_MARGIN, 0.15).
%% #304: mirrors asobi_ws_handler's ?WS_MAX_PAYLOAD_BYTES. game.broadcast's
%% payload is fanned out to every player in the world, so an unbounded
%% payload multiplies egress bandwidth and per-socket buffer memory by
%% player count; bound it the same way the inbound frame is bounded.
-define(MAX_BROADCAST_PAYLOAD_BYTES, 65536).

%% --- Public API ---

-spec start_link(map()) -> gen_statem:start_ret().
start_link(Config) ->
    gen_statem:start_link(?MODULE, Config, []).

-spec join(pid(), binary()) -> ok | {error, term()}.
join(Pid, PlayerId) ->
    case gen_statem:call(Pid, {join, PlayerId, #{}}) of
        {ok, _ZonePid} -> ok;
        {error, _} = Err -> Err
    end.

%% Variant of join/2 that also synchronously binds zone_pid into the caller's
%% asobi_player_session via SessionPid before returning. Use this from the WS
%% handler so an immediately-following world.input isn't dropped while the async
%% {world_joined,...} notification is still in flight.
-spec join(pid(), binary(), pid()) -> ok | {error, term()}.
join(Pid, PlayerId, SessionPid) when is_pid(SessionPid) ->
    join(Pid, PlayerId, SessionPid, #{}).

-doc """
As `join/3`, plus an opaque join context from the client. asobi does not
interpret it; it reaches the game module's `join/3` if it exports one.
""".
-spec join(pid(), binary(), pid(), map()) -> ok | {error, term()}.
join(Pid, PlayerId, SessionPid, Ctx) when is_pid(SessionPid), is_map(Ctx) ->
    case gen_statem:call(Pid, {join, PlayerId, Ctx}) of
        {ok, ZonePid} when is_pid(ZonePid) ->
            ok = asobi_player_session:set_zone(SessionPid, Pid, ZonePid),
            ok;
        {error, _} = Err ->
            Err
    end.

-spec leave(pid(), binary()) -> ok.
leave(Pid, PlayerId) ->
    gen_statem:cast(Pid, {leave, PlayerId}).

-doc """
Tell the world server a zone was just created by something other than a
player join or crossing - `asobi_zone` creating a neighbour to receive a
crossing NPC (widgrensit/asobi#271). The world server owns `player_zones`,
so only it can subscribe the already-connected players whose interest ring
already covered those coords (widgrensit/asobi#275).
""".
-spec zone_created(pid(), {integer(), integer()}, pid()) -> ok.
zone_created(Pid, Coords, ZonePid) when is_pid(ZonePid) ->
    gen_statem:cast(Pid, {zone_created, Coords, ZonePid}).

-spec move_player(pid(), binary(), {number(), number()}) -> ok.
move_player(Pid, PlayerId, NewPos) ->
    gen_statem:cast(Pid, {move_player, PlayerId, NewPos, undefined}).

-doc """
As `move_player/3`, but for a caller that already holds the entity's full
state (asobi_zone's resolve_zone_crossings/1). `Entity` is written into the
target zone as-is instead of being reconstructed as `#{x, y, type}` only, so
fields a game script keeps beyond position - health, inventory, whatever -
survive the zone boundary. See widgrensit/asobi#248.
""".
-spec move_player(pid(), binary(), {number(), number()}, map()) -> ok.
move_player(Pid, PlayerId, NewPos, Entity) when is_map(Entity) ->
    gen_statem:cast(Pid, {move_player, PlayerId, NewPos, Entity}).

-spec post_tick(pid(), non_neg_integer()) -> ok.
post_tick(Pid, TickN) ->
    gen_statem:cast(Pid, {post_tick, TickN}).

-spec get_info(pid()) -> map().
get_info(Pid) ->
    case gen_statem:call(Pid, get_info) of
        M when is_map(M) -> M
    end.

%% asobi#194: skips the roster; see asobi_discovery:enumerate/3's doc.
-spec get_info(pid(), listing) -> map().
get_info(Pid, listing) ->
    case gen_statem:call(Pid, {get_info, listing}) of
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
    RehomeMargin = maps:get(rehome_margin, Config, ?DEFAULT_REHOME_MARGIN),
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
        rehome_margin => RehomeMargin,
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
        listed => maps:get(listed, Config, true),
        quick_play => maps:get(quick_play, Config, true),
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
loading({call, From}, {get_info, listing}, State) ->
    {keep_state_and_data, [{reply, From, world_info(loading, State, false)}]};
loading({call, _From}, {join, _PlayerId}, _State) ->
    %% Postpone join until we transition to running. Otherwise the call
    %% would crash with function_clause and the caller would time out.
    {keep_state_and_data, [postpone]};
%% asobi#466: any other call during loading must reply, not function_clause -
%% an unanswered {call, From} crashes the world and hangs the caller's call.
loading({call, From}, _Request, _State) ->
    {keep_state_and_data, [{reply, From, {error, world_not_ready}}]};
%% A zone's post-tick crossing check (asobi_zone:resolve_zone_crossings/1)
%% can fire on a pre-warmed zone recovered from a snapshot before the world
%% has finished loading. Without this, that cast is a function_clause and
%% kills the world instead of just running once we reach running.
loading(cast, {move_player, _PlayerId, _NewPos, _Entity}, _State) ->
    {keep_state_and_data, [postpone]};
loading(cast, {zone_created, _Coords, _ZonePid}, _State) ->
    {keep_state_and_data, [postpone]};
%% A world script broadcasting during generate_world/init reaches the world
%% server while it is still loading. Without this clause that is a
%% function_clause and the world dies before it ever runs.
loading(cast, {broadcast_event, Event, Payload}, State) ->
    broadcast_world_event(Event, Payload, State),
    keep_state_and_data;
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
running({call, From}, {join, PlayerId, Ctx}, State) ->
    handle_join(From, PlayerId, Ctx, State);
running(cast, {leave, PlayerId}, State) ->
    handle_leave(PlayerId, State);
running(cast, {move_player, PlayerId, NewPos, Entity}, State) ->
    handle_move(PlayerId, NewPos, Entity, State);
running(cast, {zone_created, Coords, ZonePid}, #{player_zones := PlayerZones}) ->
    backfill_zone_subscribers(Coords, ZonePid, undefined, PlayerZones),
    keep_state_and_data;
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
running({call, From}, {get_info, listing}, State) ->
    {keep_state_and_data, [{reply, From, world_info(running, State, false)}]};
running({call, From}, {start_vote, VoteConfig}, State) ->
    handle_start_vote(From, VoteConfig, State);
running({call, From}, {cast_vote, PlayerId, VoteId, OptionId}, State) when
    is_binary(PlayerId), (is_binary(OptionId) orelse is_list(OptionId))
->
    handle_cast_vote(From, PlayerId, VoteId, OptionId, State);
%% asobi#462: this path was guard-free and forwarded an unvalidated option
%% straight to asobi_vote_server. A valid option_id is a binary
%% (plurality/weighted) or a list of binaries (approval/ranked - see
%% asobi_vote_server:validate_option/2); anything else (a JSON number, bool,
%% null or object) hits this fallback and degrades to the invalid_option
%% asobi_vote_server already reports for a bad option, never forwarding the
%% junk. A list that carries a non-binary passes the guard and is rejected
%% downstream by validate_option, also as invalid_option, with no crash.
running({call, From}, {cast_vote, _PlayerId, _VoteId, _OptionId}, _State) ->
    {keep_state_and_data, [{reply, From, {error, invalid_option}}]};
running({call, From}, {use_veto, PlayerId, VoteId}, State) when is_binary(PlayerId) ->
    handle_use_veto(From, PlayerId, VoteId, State);
running({call, From}, {use_veto, _PlayerId, _VoteId}, _State) ->
    {keep_state_and_data, [{reply, From, {error, invalid_option}}]};
running(
    cast,
    {spawn_at, TemplateId, {X, Y} = Pos, Overrides},
    #{
        zone_manager_pid := ZMPid,
        zone_size := ZS,
        grid_size := GridSize,
        world_id := WorldId,
        player_zones := PlayerZones
    } = _State
) when is_binary(TemplateId), is_number(X), is_number(Y), is_map(Overrides) ->
    Coords = pos_to_zone(Pos, ZS, GridSize),
    case asobi_zone_manager:ensure_zone(ZMPid, Coords) of
        {ok, ZonePid, ZoneStatus} ->
            asobi_zone:spawn_entity(ZonePid, TemplateId, Pos, Overrides),
            %% asobi#275: a script-driven spawn can lazily create a zone just
            %% as a player crossing can - same backfill is needed, just with
            %% no acting player of its own to exclude.
            case ZoneStatus of
                created -> backfill_zone_subscribers(Coords, ZonePid, undefined, PlayerZones);
                existing -> ok
            end,
            keep_state_and_data;
        {error, Reason} ->
            %% asobi#251: same "spawn something, hear nothing" pattern
            %% #247/#249 fixed elsewhere - a game.spawn call whose zone
            %% couldn't be created (e.g. max_zones_reached) used to drop
            %% with no signal at all.
            ?LOG_WARNING(#{
                event => spawn_at_zone_unavailable,
                world_id => WorldId,
                coords => Coords,
                template_id => TemplateId,
                reason => Reason
            }),
            asobi_telemetry:game_error(zone_unavailable, #{
                world_id => WorldId, coords => Coords, reason => Reason
            }),
            keep_state_and_data
    end;
running(cast, {broadcast_event, Event, Payload}, State) ->
    broadcast_world_event(Event, Payload, State),
    keep_state_and_data;
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
        zone_manager_pid := ZMPid,
        world_id := WorldId
    } = State,
    case {RS, maps:get(PlayerId, PZ, undefined)} of
        {undefined, _} ->
            {keep_state_and_data, [{reply, From, {error, no_reconnect_policy}}]};
        {_, undefined} ->
            {keep_state_and_data, [{reply, From, {error, not_in_world}}]};
        {_, #{zone := {ZX, ZY}, interest := InterestZones}} when
            is_integer(ZX), is_integer(ZY), is_list(InterestZones)
        ->
            %% asobi#277: checked before touching reconnect_state at all, so
            %% a missing session leaves this a pure no-op (keep_state_and_data
            %% below discards whatever asobi_reconnect:reconnect/2 would have
            %% computed) rather than a monitor(process, undefined) crash -
            %% the caller invoking reconnect/2 IS the reconnecting session, so
            %% it not being pg-registered yet means the reconnect is broken.
            case find_player_pid(PlayerId) of
                undefined ->
                    ?LOG_WARNING(#{
                        event => reconnect_no_live_session,
                        world_id => WorldId,
                        player_id => PlayerId
                    }),
                    {keep_state_and_data, [{reply, From, {error, no_live_session}}]};
                PlayerPid ->
                    ZoneCoords = {ZX, ZY},
                    {_Events, RS1} = asobi_reconnect:reconnect(PlayerId, RS),
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
                    {keep_state, State#{reconnect_state => RS1, players => Players1}, [
                        {reply, From, ok}
                    ]}
            end
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
%% Same reasoning as the match server: a world ending and broadcasting the
%% result in the same callback lands here, and the catch-all below would
%% swallow it silently.
finished(cast, {broadcast_event, Event, Payload}, State) ->
    broadcast_world_event(Event, Payload, State),
    keep_state_and_data;
finished({call, From}, get_info, State) ->
    {keep_state_and_data, [{reply, From, world_info(finished, State)}]};
finished({call, From}, {get_info, listing}, State) ->
    {keep_state_and_data, [{reply, From, world_info(finished, State, false)}]};
%% asobi#469: any other call reaching a finished world during its 5s cleanup
%% window (a late vote.cast/vote.veto while the session still holds world_pid,
%% or any call added later) must reply - an unanswered {call, From} hangs the
%% caller (asobi_ws_handler, an infinity gen_statem:call) until this server
%% stops at its cleanup timeout. Replying not_in_match returns immediately with
%% the same registered 409 the dead/finished-fabric path in vote_call/1 uses,
%% so "the world is over" is one code a client can branch on. Only non-call
%% events reach the swallow catch-all below now.
finished({call, From}, _Request, _State) ->
    {keep_state_and_data, [{reply, From, {error, not_in_match}}]};
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
        zone_size := ZoneSize,
        grid_size := GridSize,
        rehome_margin := RehomeMargin,
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
        game_config => maps:get(game_config, Config, #{}),
        world_server_pid => self(),
        spawn_templates => Templates,
        persistence => Persistence,
        snapshot_interval => maps:get(snapshot_interval, Config, 600),
        %% How many simulation ticks per wire delta. Default 3 (so at the 50ms
        %% tick_rate deltas go out every 150ms); a mode sets `broadcast_interval`
        %% to decimate less - 1 means every tick, which is what client-side
        %% prediction wants for the tightest correction latency.
        broadcast_interval => maps:get(broadcast_interval, Config, 3),
        zone_manager_pid => ZoneManagerPid,
        terrain_store_pid => TerrainStorePid,
        %% So a zone can decide crossings with the same clamped math - see
        %% resolve_zone_crossings/1 in asobi_zone.
        zone_size => ZoneSize,
        grid_size => GridSize,
        rehome_margin => RehomeMargin
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
    restore_entities(AllCoords, Entities, ZoneManagerPid, WorldId),
    State#{game_state => GS1}.

-spec restore_entities([term()], map(), pid() | atom(), binary()) -> ok.
restore_entities([], _Entities, _ZoneManagerPid, _WorldId) ->
    ok;
restore_entities([{CX, CY} = Coords | Rest], Entities, ZoneManagerPid, WorldId) when
    is_integer(CX), is_integer(CY)
->
    RecoveredEnts = maps:get(Coords, Entities, #{}),
    case map_size(RecoveredEnts) of
        0 ->
            ok;
        _ ->
            %% asobi#258: see place_player/4 for why this isn't a bare match.
            case asobi_zone_manager:ensure_zone(ZoneManagerPid, Coords) of
                {error, Reason} ->
                    %% ERROR, not WARNING: unlike the routine capacity
                    %% rejections on the runtime join/move paths, this drops
                    %% previously-persisted entity state for the zone - real
                    %% data loss, not just backpressure (asobi#258 review).
                    ?LOG_ERROR(#{
                        event => restore_entities_zone_unavailable,
                        world_id => WorldId,
                        coords => Coords,
                        entity_count => map_size(RecoveredEnts),
                        reason => Reason
                    }),
                    asobi_telemetry:game_error(zone_unavailable, #{
                        world_id => WorldId, coords => Coords, reason => Reason
                    });
                {ok, ZonePid, _Status} ->
                    maps:foreach(
                        fun(EId, EState) -> asobi_zone:add_entity(ZonePid, EId, EState) end,
                        RecoveredEnts
                    )
            end
    end,
    restore_entities(Rest, Entities, ZoneManagerPid, WorldId);
restore_entities([_ | Rest], Entities, ZoneManagerPid, WorldId) ->
    restore_entities(Rest, Entities, ZoneManagerPid, WorldId).

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
    Ctx,
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
            case asobi_game_join:invoke(Mod, PlayerId, Ctx, GS) of
                {ok, GS1} ->
                    {ok, SpawnPos} = Mod:spawn_position(PlayerId, GS1),
                    State1 = State#{game_state => GS1},
                    case place_player(PlayerId, SpawnPos, State1) of
                        {error, Reason, _State1} ->
                            %% keep_state_and_data discards GS1, rolling the game
                            %% module's join back along with the rejected placement
                            %% rather than leaving it out of sync with a client that
                            %% was told the join failed (asobi#258).
                            ?LOG_WARNING(#{
                                event => join_zone_unavailable,
                                world_id => WorldId,
                                player_id => PlayerId,
                                reason => Reason
                            }),
                            asobi_telemetry:game_error(zone_unavailable, #{
                                world_id => WorldId, reason => Reason
                            }),
                            {keep_state_and_data, [{reply, From, {error, zone_unavailable}}]};
                        {ok, State2, ZonePid} ->
                            %% Monitor player session for reconnection handling.
                            %% asobi#277: place_player/4 already degrades
                            %% gracefully if this player has no live session
                            %% (its subscribe becomes a no-op); do the same
                            %% here rather than crashing on
                            %% monitor(process, undefined).
                            PlayerPid = find_player_pid(PlayerId),
                            MonRef =
                                case PlayerPid of
                                    undefined ->
                                        ?LOG_WARNING(#{
                                            event => join_no_live_session,
                                            world_id => WorldId,
                                            player_id => PlayerId
                                        }),
                                        undefined;
                                    _ ->
                                        erlang:monitor(process, PlayerPid)
                                end,
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
                            ZoneCoords = pos_to_zone(
                                SpawnPos, maps:get(zone_size, State3), maps:get(grid_size, State3)
                            ),
                            asobi_world_chat:player_joined(
                                PlayerId, ZoneCoords, maps:get(chat_state, State3)
                            ),
                            State4 = notify_phase_player_joined(State3),
                            %% Cancel any pending empty_grace timer — this player rescued
                            %% the world from the grace window. The cancel is a no-op if
                            %% no timer is pending.
                            {keep_state, State4, [
                                {reply, From, {ok, ZonePid}},
                                {{timeout, empty_grace}, infinity, undefined}
                            ]}
                    end;
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

%% asobi#258: ensure_zone/2 can fail (e.g. max_zones_reached); a bare
%% {ok, ZonePid} = ... match here used to crash the whole world gen_statem -
%% every player in it - on what should be a per-player placement failure.
%% Callers get a tagged result and decide their own safe fallback.
%%
%% Called at join, where there is no prior entity to preserve.
-spec place_player(binary(), {number(), number()}, map()) ->
    {ok, map(), pid()} | {error, term(), map()}.
place_player(PlayerId, {X, Y} = Pos, State) ->
    place_player(PlayerId, Pos, #{x => X, y => Y, type => ~"player"}, State).

-spec place_player(binary(), {number(), number()}, map(), map()) ->
    {ok, map(), pid()} | {error, term(), map()}.
place_player(
    PlayerId,
    {X, Y} = _Pos,
    Entity,
    #{
        zone_manager_pid := ZMPid,
        view_radius := ViewRadius,
        zone_size := ZoneSize,
        grid_size := GridSize
    } = State
) ->
    ZoneCoords = pos_to_zone({X, Y}, ZoneSize, GridSize),
    case asobi_zone_manager:ensure_zone(ZMPid, ZoneCoords) of
        {error, Reason} ->
            {error, Reason, State};
        {ok, ZonePid, ZoneStatus} ->
            PlayerPid = find_player_pid(PlayerId),
            InterestZones = interest_zones(ZoneCoords, ViewRadius, GridSize),
            PlayerZones = maps:get(player_zones, State),
            Bind = #{
                world_id => maps:get(world_id, State),
                zone_manager_pid => ZMPid,
                coords => ZoneCoords,
                player_id => PlayerId,
                entity => Entity,
                player_pid => PlayerPid,
                player_zones => PlayerZones,
                subscribe_zones => InterestZones
            },
            case bind_player_zone(Bind, ZonePid, ZoneStatus) of
                {error, Reason} ->
                    {error, Reason, State};
                {ok, BoundZonePid} ->
                    State1 = State#{
                        player_zones => PlayerZones#{
                            PlayerId => #{zone => ZoneCoords, interest => InterestZones}
                        }
                    },
                    {ok, State1, BoundZonePid}
            end
    end.

%% Puts the player's entity in the zone and makes that stick.
%%
%% The drain call is asobi#248: without it a world.input cast from the WS
%% handler can race past the add_entity cast (different sender = no FIFO) and
%% the zone's next tick runs apply_inputs against an entities map missing the
%% player - the Lua handle_input's "if not e then return entities end" guard
%% then silently drops the input. The call forces the zone to process its
%% mailbox up to here before the caller replies to the WS handler.
%%
%% asobi#283: the zone can also be gone by now. ensure_zone/2 hands out a pid
%% without a lease, so a zone that is genuinely empty when the manager's reap
%% sweep fires stops even though this placement is already in flight against
%% it - dropping add_entity on the floor and, before this, exiting the whole
%% world gen_statem with `normal` on the drain call. Once the entity is in,
%% the zone declines further reaps itself, so a single retry against a
%% replacement zone is enough.
-spec bind_player_zone(map(), pid(), created | existing) -> {ok, pid()} | {error, term()}.
bind_player_zone(Bind, ZonePid, ZoneStatus) ->
    bind_player_zone(Bind, ZonePid, ZoneStatus, 1).

-spec bind_player_zone(map(), pid(), created | existing, pos_integer()) ->
    {ok, pid()} | {error, term()}.
bind_player_zone(Bind, ZonePid, ZoneStatus, Attempt) ->
    #{
        world_id := WorldId,
        zone_manager_pid := ZMPid,
        coords := Coords,
        player_id := PlayerId,
        entity := Entity,
        player_pid := PlayerPid,
        player_zones := PlayerZones,
        subscribe_zones := SubscribeZones
    } = Bind,
    asobi_zone:add_entity(ZonePid, PlayerId, Entity),
    asobi_presence:send(PlayerId, {world_joined, self(), ZonePid}),
    subscribe_interest_zones(SubscribeZones, ZMPid, PlayerId, PlayerPid),
    case PlayerPid of
        undefined -> ok;
        _ -> asobi_zone:subscribe(ZonePid, {PlayerId, PlayerPid})
    end,
    case ZoneStatus of
        created -> backfill_zone_subscribers(Coords, ZonePid, PlayerId, PlayerZones);
        existing -> ok
    end,
    case asobi_zone:sync(ZonePid) of
        ok ->
            {ok, ZonePid};
        zone_gone when Attempt >= 2 ->
            {error, zone_gone};
        zone_gone ->
            ?LOG_WARNING(#{
                event => zone_reaped_during_placement,
                world_id => WorldId,
                player_id => PlayerId,
                coords => Coords
            }),
            case asobi_zone_manager:revive_zone(ZMPid, Coords, ZonePid) of
                {ok, NewZonePid, NewStatus} ->
                    bind_player_zone(Bind, NewZonePid, NewStatus, Attempt + 1);
                {error, _} = Err ->
                    Err
            end
    end.

%% asobi#275: a zone coming into existence has to pick up every already-known
%% player whose interest ring already covers it - the ring-diff subscribe path
%% only fires for zones newly entering a player's ring, never for one that was
%% already there but unloaded at the time. ExcludePlayerId is whichever player
%% caused this creation - they are subscribed separately by the caller (with
%% the full context of their own crossing/join), so skip them here.
%%
%% Resolves other players' pids via find_player_pid/1 - safe since asobi#277
%% made it return undefined instead of falling back to self() for a player
%% with no live pg registration. A player_zones entry outlives disconnection
%% (kept around for reconnect, see the {reconnect_state := RS} clause above),
%% so a player here can legitimately have no live session; undefined lets
%% this skip them instead of subscribing the world server's own pid as their
%% "session".
-spec backfill_zone_subscribers({integer(), integer()}, pid(), binary() | undefined, map()) -> ok.
backfill_zone_subscribers(ZoneCoords, ZonePid, ExcludePlayerId, PlayerZones) ->
    maps:foreach(
        fun
            (PlayerId, _) when PlayerId =:= ExcludePlayerId ->
                ok;
            (PlayerId, #{interest := Interest}) ->
                case lists:member(ZoneCoords, Interest) of
                    true ->
                        case find_player_pid(PlayerId) of
                            undefined -> ok;
                            PlayerPid -> asobi_zone:subscribe(ZonePid, {PlayerId, PlayerPid})
                        end;
                    false ->
                        ok
                end
        end,
        PlayerZones
    ).

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
            %% release_zone unconditionally backdates the zone past its idle
            %% timeout (asobi_zone_manager.erl) - it does not itself check for
            %% other occupants despite what its name suggests. Do that check
            %% here instead, from player_zones already in hand: releasing a
            %% zone another player is still standing in risks the reaper
            %% killing it inside the backdate-to-reap-sweep race window,
            %% dropping every subscriber with nothing to re-subscribe them.
            %% See widgrensit/asobi#248.
            case zone_still_occupied(ZoneCoords, PlayerId, PlayerZones) of
                true -> ok;
                false -> asobi_zone_manager:release_zone(ZMPid, ZoneCoords)
            end,
            State#{player_zones => maps:remove(PlayerId, PlayerZones)}
    end.

%% "Occupied" covers both a player standing in the zone (its `zone`) and one
%% merely watching it from a neighbouring cell (in its `interest` ring) -
%% releasing a zone the latter is still subscribed to risks the same reaper
%% race, just for a subscriber the zone never itself notices leaving.
-spec zone_still_occupied({integer(), integer()}, binary(), map()) -> boolean().
zone_still_occupied(ZoneCoords, LeavingPlayerId, PlayerZones) ->
    lists:any(
        fun
            (#{zone := Zone}) when Zone =:= ZoneCoords ->
                true;
            (#{interest := Interest}) when is_list(Interest) ->
                lists:member(ZoneCoords, Interest);
            (_) ->
                false
        end,
        maps:values(maps:remove(LeavingPlayerId, PlayerZones))
    ).

handle_move(
    PlayerId,
    {X, Y} = NewPos,
    MaybeEntity,
    #{
        world_id := WorldId,
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
        #{zone := OldZoneCoords, interest := OldInterest} ->
            NewZoneCoords = pos_to_zone(NewPos, ZoneSize, GridSize),
            %% move_player/3 (existing test/external callers) passes no
            %% entity; move_player/4 (asobi_zone:resolve_zone_crossings/1)
            %% passes the entity's current full state so fields beyond x/y/type
            %% survive the crossing. See widgrensit/asobi#248.
            Entity =
                case MaybeEntity of
                    undefined -> #{x => X, y => Y, type => ~"player"};
                    Map when is_map(Map) -> Map
                end,
            case OldZoneCoords =:= NewZoneCoords of
                true ->
                    case asobi_zone_manager:get_zone(ZMPid, OldZoneCoords) of
                        {ok, ZonePid} ->
                            asobi_zone:add_entity(ZonePid, PlayerId, Entity);
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
                    %% asobi#258: check the destination zone BEFORE removing the
                    %% player from their current one - a crash-free version of
                    %% this same ordering would still have stranded them
                    %% zoneless on failure. Pre-checking keeps a failed crossing
                    %% a pure no-op instead.
                    case asobi_zone_manager:ensure_zone(ZMPid, NewZoneCoords) of
                        {error, Reason} ->
                            ?LOG_WARNING(#{
                                event => move_zone_unavailable,
                                world_id => WorldId,
                                player_id => PlayerId,
                                coords => NewZoneCoords,
                                reason => Reason
                            }),
                            asobi_telemetry:game_error(zone_unavailable, #{
                                world_id => WorldId, coords => NewZoneCoords, reason => Reason
                            }),
                            keep_state_and_data;
                        {ok, NewZonePid, ZoneStatus} ->
                            %% A single-step crossing keeps most of the ring in
                            %% common (radius 1 keeps 6 of 9 zones on an
                            %% orthogonal move) - touching only the zones that
                            %% actually entered or left avoids an unsubscribe/
                            %% resubscribe (and the full zone snapshot resend
                            %% subscribing triggers) for every zone that didn't
                            %% change. See widgrensit/asobi#248.
                            NewInterest = interest_zones(NewZoneCoords, ViewRadius, GridSize),
                            ToUnsubscribe = OldInterest -- NewInterest,
                            %% NewZoneCoords is itself always part of NewInterest
                            %% (the ring includes its own centre), so a one-step
                            %% crossing where it was already a ring neighbour
                            %% never appears in this diff. asobi#275: subscribe
                            %% is idempotent for an already-subscribed pid, so
                            %% NewZoneCoords is dropped here and subscribed
                            %% unconditionally below instead of relying on the
                            %% diff to have subscribed it correctly the first
                            %% time it entered the ring (it may not have - see
                            %% backfill_zone_subscribers/4).
                            ToSubscribe = (NewInterest -- OldInterest) -- [NewZoneCoords],

                            %% asobi#277: PlayerPid is undefined if this
                            %% crossing player somehow has no live session -
                            %% nothing to subscribe or notify in that case.
                            %%
                            %% asobi#275 (inside bind_player_zone/3): this
                            %% crossing may be what brought the zone into
                            %% existence - any other already-connected player
                            %% whose interest ring already covers it (a
                            %% stationary neighbour, most commonly) tried to
                            %% subscribe while it was not_loaded and was
                            %% silently skipped, with nothing to retry it since.
                            %%
                            %% asobi#283: binding runs before the player is
                            %% taken out of the old zone, for the same reason
                            %% asobi#258 pre-checks the destination - a
                            %% destination that turns out to be unusable leaves
                            %% the crossing a no-op instead of stranding the
                            %% player zoneless.
                            PlayerPid = find_player_pid(PlayerId),
                            Bind = #{
                                world_id => WorldId,
                                zone_manager_pid => ZMPid,
                                coords => NewZoneCoords,
                                player_id => PlayerId,
                                entity => Entity,
                                player_pid => PlayerPid,
                                player_zones => PlayerZones,
                                subscribe_zones => ToSubscribe
                            },
                            case bind_player_zone(Bind, NewZonePid, ZoneStatus) of
                                {error, BindReason} ->
                                    ?LOG_WARNING(#{
                                        event => move_zone_unavailable,
                                        world_id => WorldId,
                                        player_id => PlayerId,
                                        coords => NewZoneCoords,
                                        reason => BindReason
                                    }),
                                    asobi_telemetry:game_error(zone_unavailable, #{
                                        world_id => WorldId,
                                        coords => NewZoneCoords,
                                        reason => BindReason
                                    }),
                                    keep_state_and_data;
                                {ok, BoundZonePid} ->
                                    case asobi_zone_manager:get_zone(ZMPid, OldZoneCoords) of
                                        {ok, OldZonePid} ->
                                            asobi_zone:remove_entity(OldZonePid, PlayerId);
                                        not_loaded ->
                                            ok
                                    end,
                                    unsubscribe_interest_zones(ToUnsubscribe, ZMPid, PlayerId),

                                    asobi_world_chat:player_zone_changed(
                                        PlayerId, OldZoneCoords, NewZoneCoords, GridSize, ChatState
                                    ),

                                    PlayerZones1 = maps:remove(PlayerId, PlayerZones),
                                    %% The old zone is often still in the player's own
                                    %% new ring (see ToUnsubscribe above) -
                                    %% zone_still_occupied/3 only knows about other
                                    %% players, so check that first.
                                    case
                                        lists:member(OldZoneCoords, NewInterest) orelse
                                            zone_still_occupied(
                                                OldZoneCoords, PlayerId, PlayerZones1
                                            )
                                    of
                                        true ->
                                            ok;
                                        false ->
                                            asobi_zone_manager:release_zone(ZMPid, OldZoneCoords)
                                    end,

                                    _ =
                                        case PlayerPid of
                                            undefined ->
                                                ok;
                                            _ ->
                                                PlayerPid !
                                                    {asobi_message,
                                                        {world_zone_changed, BoundZonePid}}
                                        end,
                                    Players1 = maps:update_with(
                                        PlayerId,
                                        fun(Meta) -> Meta#{position => NewPos} end,
                                        Players
                                    ),
                                    {keep_state, State#{
                                        players => Players1,
                                        player_zones => PlayerZones1#{
                                            PlayerId => #{
                                                zone => NewZoneCoords, interest => NewInterest
                                            }
                                        }
                                    }}
                            end
                    end
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

%% Only clamps the low end - not safe for a position past the world's far
%% edge. pos_to_zone/3 below is what every other module should call.
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

-doc """
As `pos_to_zone/2`, additionally clamped to `0 .. GridSize - 1` on both axes.
Use this wherever a player's current zone is derived from position. See
widgrensit/asobi#248.
""".
-spec pos_to_zone({number(), number()}, non_neg_integer(), pos_integer()) ->
    {non_neg_integer(), non_neg_integer()}.
pos_to_zone(Pos, ZoneSize, GridSize) when is_integer(GridSize), GridSize > 0 ->
    {ZX, ZY} = pos_to_zone(Pos, ZoneSize),
    {min(ZX, GridSize - 1), min(ZY, GridSize - 1)}.

-spec interest_zones({integer(), integer()}, non_neg_integer(), non_neg_integer()) ->
    [{integer(), integer()}].
interest_zones(Coords, Radius, GridSize) ->
    asobi_zone_grid:ring(Coords, Radius, GridSize).

%% asobi#277: used to fall back to self() when a player had no live pg
%% registration - meant for "the player currently acting" call sites, where
%% the caller's own session is always registered before it ever reaches
%% here. But a player_zones entry outlives disconnection (kept around for
%% reconnect), so that invariant isn't structural - a future caller reaching
%% this with a disconnected player would have silently subscribed/monitored
%% the world server itself as that player's "session". undefined makes the
%% no-live-session case something every caller has to handle explicitly.
-spec find_player_pid(binary()) -> pid() | undefined.
find_player_pid(PlayerId) ->
    case pg:get_members(?PG_SCOPE, {player, PlayerId}) of
        [Pid | _] -> Pid;
        [] -> undefined
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

-spec subscribe_interest_zones([term()], pid() | atom(), binary(), pid() | undefined) -> ok.
subscribe_interest_zones(_Zones, _ZMPid, _PlayerId, undefined) ->
    %% asobi#277: no live session to subscribe - nothing to do.
    ok;
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

%% asobi#329: the millisecond stamps used to go in raw and every insert
%% failed the `utc_datetime` cast, silently - no world ever reached
%% match_records. Player stats stay out of this path on purpose: a world is
%% a persistent space, not a scored game, so "one world visit is one game
%% played" is a product call rather than a bug fix.
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
            started_at => asobi_match_record:to_timestamp(maps:get(started_at, State, undefined)),
            finished_at => asobi_match_record:to_timestamp(erlang:system_time(millisecond))
        },
        [id, mode, status, players, result, started_at, finished_at]
    ),
    case asobi_repo:insert(CS) of
        {ok, _} ->
            ok;
        {error, Reason} ->
            ?LOG_WARNING(#{
                event => world_record_persist_failed, world_id => WorldId, reason => Reason
            }),
            ok
    end.

-doc """
Fan a game-authored event out to every player in the world.

`notify_players/2` builds payloads for specific lifecycle events; this is
the general path a Lua `game.broadcast` reaches. asobi_lua binds the world
server pid as `match_pid` in world and zone contexts, so `game.broadcast`
from a world script casts `{broadcast_event, ...}` here.
""".
broadcast_world_event(Event, Payload, #{players := Players, world_id := WorldId}) ->
    case payload_within_limit(Payload) of
        true ->
            maps:foreach(
                fun(PlayerId, _Meta) ->
                    asobi_presence:send(PlayerId, {world_event, Event, Payload})
                end,
                Players
            );
        false ->
            ?LOG_WARNING(#{
                msg => ~"game_broadcast_rejected",
                namespace => ~"world",
                reason => ~"payload_too_large",
                world_id => WorldId
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

world_info(Status, State) ->
    world_info(Status, State, true).

world_info(Status, #{world_id := WorldId, players := Players} = State, IncludeRoster) ->
    Base0 = #{
        world_id => WorldId,
        status => Status,
        player_count => map_size(Players),
        max_players => maps:get(max_players, State, 500),
        mode => maps:get(mode, State, undefined),
        grid_size => maps:get(grid_size, State),
        started_at => maps:get(started_at, State, undefined),
        listed => maps:get(listed, State, true),
        quick_play => maps:get(quick_play, State, true)
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

-doc "What a non-member may see. Every key is optional: `maps:with/2` keeps only what the world set.".
-type listing() :: #{
    world_id => binary(),
    status => atom(),
    player_count => non_neg_integer(),
    max_players => pos_integer(),
    mode => binary() | undefined,
    grid_size => non_neg_integer(),
    started_at => integer() | undefined,
    phase => map()
}.

-doc """
Projection of `get_info/1` for callers who are not members of the world.

`get_info/1` carries the full `players` roster. Discovery and the join
reply are open to any authenticated player, so they get identity, mode,
status, capacity and phase only.

The projection descends into `phase`: `asobi_phase:info/1` evolves
independently and its `config` is game-authored, so allowlisting only the
top level would leak whatever a future phase field happens to carry.
""".
-spec listing_info(map()) -> listing().
listing_info(Info) ->
    Base = maps:with(
        [world_id, status, player_count, max_players, mode, grid_size, started_at],
        Info
    ),
    case maps:get(phase, Info, undefined) of
        Phase when is_map(Phase) ->
            Base#{phase => maps:with([status, phase, remaining_ms, start_condition], Phase)};
        _ ->
            Base
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
