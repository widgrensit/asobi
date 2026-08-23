-module(asobi_zone_manager).
-behaviour(gen_server).

-moduledoc """
Lazy zone lifecycle manager for the world server.

Replaces the static zone_pids map with on-demand zone creation and idle
reaping. For large worlds (2000x2000 grids), spawning all zones at startup
is untenable — this module creates zones on first access and reaps them
after an idle timeout.

Hot-path lookups go through ETS directly, bypassing the gen_server.
""".

-export([start_link/1]).
-export([ensure_zone/2, ensure_zone/3, get_zone/2, touch_zone/2, release_zone/2, revive_zone/3]).
-export([get_active_zones/1, zone_terminated/3, pre_warm/1]).
-export([register_zone/3, set_zone_config/2, set_initial_zone_states/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(REAP_INTERVAL, 10_000).
-define(DEFAULT_IDLE_TIMEOUT, 30_000).
-define(DEFAULT_MAX_ACTIVE, 10_000).
-define(DEFAULT_CALL_TIMEOUT, 5_000).

%% --- Public API ---

-doc "Start the zone manager.".
-spec start_link(map()) -> gen_server:start_ret().
start_link(Opts) ->
    gen_server:start_link(?MODULE, Opts, []).

-doc """
Return existing zone or start a new one. ETS fast path first.

The third element of a successful result tells the caller whether this call
is what brought the zone into existence (`created`) or whether it was already
running (`existing`) - callers that need to backfill subscribers whose
interest ring already covered these coords (widgrensit/asobi#275) only need
to act on `created`.
""".
-spec ensure_zone(pid() | atom(), {integer(), integer()}) ->
    {ok, pid(), created | existing} | {error, term()}.
ensure_zone(Ref, Coords) ->
    ensure_zone(Ref, Coords, ?DEFAULT_CALL_TIMEOUT).

-doc """
As `ensure_zone/2`, with an explicit call timeout. Callers on a hot path
that must not stall on a busy manager (`asobi_zone`'s per-tick crossing
check, widgrensit/asobi#271) pass a tighter bound than the gen_server
default and treat a timeout as "not available this tick".
""".
-spec ensure_zone(pid() | atom(), {integer(), integer()}, timeout()) ->
    {ok, pid(), created | existing} | {error, term()}.
ensure_zone(Ref, Coords, Timeout) ->
    case ets_lookup(Ref, Coords, Timeout) of
        {ok, Pid} ->
            {ok, Pid, existing};
        not_loaded ->
            case gen_server:call(Ref, {ensure_zone, Coords}, Timeout) of
                {ok, P, created} when is_pid(P) -> {ok, P, created};
                {ok, P, existing} when is_pid(P) -> {ok, P, existing};
                {error, _} = Err -> Err
            end
    end.

-doc "Non-creating lookup. ETS only.".
-spec get_zone(pid() | atom(), {integer(), integer()}) -> {ok, pid()} | not_loaded.
get_zone(Ref, Coords) ->
    ets_lookup(Ref, Coords).

-doc """
Replace a zone that died under a caller holding its pid.

`ensure_zone/2` hands out a pid without a lease on it, so a genuinely-idle
zone can still be reaped in the gap between the lookup and the caller proving
it occupied (widgrensit/asobi#283). The caller that notices this cannot just
retry `ensure_zone/2`: the ETS slot still points at the dead pid until the
manager has processed its `DOWN`, so the retry would hand back the same
corpse. This waits for that `DOWN` (the zone's `terminate/2` snapshot has
already run by then, so the replacement loads current state) and starts a
fresh zone.

Returns the already-live zone when someone else got there first.
""".
-spec revive_zone(pid() | atom(), {integer(), integer()}, pid()) ->
    {ok, pid(), created | existing} | {error, term()}.
revive_zone(Ref, Coords, DeadPid) when is_pid(DeadPid) ->
    case gen_server:call(Ref, {revive_zone, Coords, DeadPid}) of
        {ok, P, created} when is_pid(P) -> {ok, P, created};
        {ok, P, existing} when is_pid(P) -> {ok, P, existing};
        {error, _} = Err -> Err
    end.

-doc "Reset idle timer for a zone. Fire-and-forget.".
-spec touch_zone(pid() | atom(), {integer(), integer()}) -> ok.
touch_zone(Ref, Coords) ->
    gen_server:cast(Ref, {touch_zone, Coords}).

-doc "Hint that zone can be unloaded.".
-spec release_zone(pid() | atom(), {integer(), integer()}) -> ok.
release_zone(Ref, Coords) ->
    gen_server:cast(Ref, {release_zone, Coords}).

-doc "Return all active zone pids. For the ticker.".
-spec get_active_zones(pid() | atom()) -> [pid()].
get_active_zones(Ref) when is_atom(Ref) ->
    [Pid || {_Coords, Pid} <- ets:tab2list(Ref), is_pid(Pid)];
get_active_zones(Ref) when is_pid(Ref) ->
    narrow_pid_list(gen_server:call(Ref, get_active_zones)).

-spec narrow_pid_list(term()) -> [pid()].
narrow_pid_list([]) -> [];
narrow_pid_list([P | Rest]) when is_pid(P) -> [P | narrow_pid_list(Rest)].

-doc "Called by zone on terminate. Cleans up ETS entry.".
-spec zone_terminated(pid() | atom(), {integer(), integer()}, pid()) -> ok.
zone_terminated(Ref, Coords, ZonePid) ->
    gen_server:cast(Ref, {zone_terminated, Coords, ZonePid}).

-doc "Spawn all zones in grid. Backward compat for small grids.".
-spec pre_warm(pid() | atom()) -> ok.
pre_warm(Ref) ->
    ok = gen_server:call(Ref, pre_warm, 60_000).

-doc "Register an externally-spawned zone with the manager.".
-spec register_zone(pid() | atom(), {integer(), integer()}, pid()) -> ok.
register_zone(Ref, Coords, ZonePid) ->
    ok = gen_server:call(Ref, {register_zone, Coords, ZonePid}).

-doc "Update the base zone config used when spawning new zones.".
-spec set_zone_config(pid() | atom(), map()) -> ok.
set_zone_config(Ref, Config) ->
    ok = gen_server:call(Ref, {set_zone_config, Config}).

-doc """
Provide per-coord initial zone_state. Used to thread per-zone state from
`GameMod:generate_world/2` (e.g. lua_state for the asobi_lua_world bridge,
or station/planet seeds for sc_game) through to each zone's init. Without
this, zones would all start with empty zone_state and any callback that
needs per-zone setup would silently no-op.
""".
-spec set_initial_zone_states(pid() | atom(), map()) -> ok.
set_initial_zone_states(Ref, ZoneStates) when is_map(ZoneStates) ->
    ok = gen_server:call(Ref, {set_initial_zone_states, ZoneStates}).

%% --- gen_server callbacks ---

-spec init(map()) -> {ok, map()}.
init(Opts) ->
    WorldId = maps:get(world_id, Opts),
    Name = maps:get(name, Opts, undefined),
    Tab =
        case Name of
            undefined ->
                ets:new(asobi_zone_mgr, [set, public, {read_concurrency, true}]);
            N when is_atom(N) ->
                ets:new(N, [set, public, named_table, {read_concurrency, true}])
        end,
    ZoneSup =
        case maps:get(zone_sup, Opts, undefined) of
            undefined ->
                erlang:send(self(), resolve_zone_sup),
                undefined;
            Pid ->
                Pid
        end,
    ReapRef = schedule_reap(),
    {ok, #{
        world_id => WorldId,
        name => Name,
        instance_sup => maps:get(instance_sup, Opts, undefined),
        zone_sup => ZoneSup,
        ets_tab => Tab,
        zone_last_active => #{},
        zone_monitors => #{},
        idle_timeout => maps:get(idle_timeout, Opts, ?DEFAULT_IDLE_TIMEOUT),
        max_active_zones => maps:get(max_active_zones, Opts, ?DEFAULT_MAX_ACTIVE),
        grid_size => maps:get(grid_size, Opts),
        zone_size => maps:get(zone_size, Opts),
        zone_config => maps:get(zone_config, Opts, #{}),
        initial_zone_states => maps:get(initial_zone_states, Opts, #{}),
        reap_ref => ReapRef
    }}.

-spec handle_call(term(), gen_server:from(), map()) -> {reply, term(), map()}.
handle_call({ensure_zone, Coords}, _From, #{ets_tab := Tab} = State) ->
    case ets:lookup(Tab, Coords) of
        [{Coords, Pid}] ->
            {reply, {ok, Pid, existing}, touch(Coords, State)};
        [] ->
            case start_zone(Coords, State) of
                {ok, Pid, State1} ->
                    {reply, {ok, Pid, created}, State1};
                {error, Reason} ->
                    {reply, {error, Reason}, State}
            end
    end;
handle_call({revive_zone, {ZX, ZY} = Coords, DeadPid}, _From, #{ets_tab := Tab} = State) when
    is_integer(ZX), is_integer(ZY), is_pid(DeadPid)
->
    case ets:lookup(Tab, Coords) of
        [{Coords, DeadPid}] ->
            case await_zone_down(Coords, DeadPid, State) of
                {ok, State1} ->
                    case start_zone(Coords, State1) of
                        {ok, Pid, State2} -> {reply, {ok, Pid, created}, State2};
                        {error, Reason} -> {reply, {error, Reason}, State1}
                    end;
                timeout ->
                    {reply, {error, zone_stopping}, State}
            end;
        [{Coords, Pid}] ->
            {reply, {ok, Pid, existing}, touch(Coords, State)};
        [] ->
            case start_zone(Coords, State) of
                {ok, Pid, State1} -> {reply, {ok, Pid, created}, State1};
                {error, Reason} -> {reply, {error, Reason}, State}
            end
    end;
handle_call(pre_warm, _From, #{grid_size := GridSize} = State) ->
    AllCoords = [{X, Y} || X <- lists:seq(0, GridSize - 1), Y <- lists:seq(0, GridSize - 1)],
    State1 = prewarm_zones(AllCoords, State),
    {reply, ok, State1};
handle_call(
    {register_zone, Coords, ZonePid},
    _From,
    #{
        ets_tab := Tab,
        zone_last_active := Active,
        zone_monitors := Monitors
    } = State
) when is_pid(ZonePid) ->
    ets:insert(Tab, {Coords, ZonePid}),
    MonRef = monitor(process, ZonePid),
    Now = erlang:monotonic_time(millisecond),
    State1 = State#{
        zone_last_active => Active#{Coords => Now},
        zone_monitors => Monitors#{MonRef => Coords, Coords => MonRef}
    },
    {reply, ok, State1};
handle_call({set_zone_config, Config}, _From, State) ->
    {reply, ok, State#{zone_config => Config}};
handle_call({set_initial_zone_states, ZoneStates}, _From, State) ->
    {reply, ok, State#{initial_zone_states => ZoneStates}};
handle_call({lookup_zone, Coords}, _From, #{ets_tab := Tab} = State) ->
    Result =
        case ets:lookup(Tab, Coords) of
            [{Coords, Pid}] -> {ok, Pid};
            [] -> not_loaded
        end,
    {reply, Result, State};
handle_call(get_active_zones, _From, #{ets_tab := Tab} = State) ->
    {reply, [Pid || {_Coords, Pid} <- ets:tab2list(Tab)], State};
handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

-spec handle_cast(term(), map()) -> {noreply, map()}.
handle_cast({touch_zone, Coords}, State) ->
    {noreply, touch(Coords, State)};
handle_cast({release_zone, Coords}, #{zone_last_active := Active, idle_timeout := Timeout} = State) ->
    Stale = erlang:monotonic_time(millisecond) - Timeout - 1,
    {noreply, State#{zone_last_active => Active#{Coords => Stale}}};
handle_cast({zone_terminated, Coords, ZonePid}, #{ets_tab := Tab} = State) ->
    %% Only clean up if this coords still maps to the pid that terminated -
    %% a reaped zone's slot may already have been recreated.
    case ets:lookup(Tab, Coords) of
        [{Coords, ZonePid}] -> {noreply, cleanup_zone(Coords, State)};
        _ -> {noreply, State}
    end;
handle_cast(_Msg, State) ->
    {noreply, State}.

-spec handle_info(term(), map()) -> {noreply, map()}.
handle_info({reap_idle, Ref}, #{reap_ref := Ref} = State) ->
    State1 = reap_idle_zones(State),
    State2 = State1#{reap_ref => schedule_reap()},
    {noreply, State2};
handle_info({reap_idle, _OldRef}, State) ->
    {noreply, State};
handle_info(resolve_zone_sup, #{instance_sup := InstanceSup} = State) ->
    ZoneSup = asobi_world_instance:get_child(InstanceSup, asobi_zone_sup),
    {noreply, State#{zone_sup => ZoneSup}};
handle_info(
    {'DOWN', MonRef, process, Pid, _Reason},
    #{zone_monitors := Monitors, ets_tab := Tab} = State
) ->
    case maps:get(MonRef, Monitors, undefined) of
        undefined ->
            {noreply, State};
        Coords ->
            case ets:lookup(Tab, Coords) of
                [{Coords, Pid}] ->
                    {noreply, cleanup_zone(Coords, State)};
                _ ->
                    %% Stale monitor: the coords was recreated with a new pid.
                    %% Drop just this monitor mapping, leave the live zone.
                    {noreply, State#{zone_monitors => maps:remove(MonRef, Monitors)}}
            end
    end;
handle_info(_Info, State) ->
    {noreply, State}.

%% No zone/closed events here on purpose: this process does not trap exits, so
%% a supervisor shutdown kills it without running terminate/2 at all, and the
%% instance supervisor stops the manager before the zone supervisor, so the
%% zones' DOWNs are never processed either. A consumer deriving a live-zone
%% gauge from opened minus closed must key it on world_id and drop the world's
%% counters when the world ends - see ADR 0005.
-spec terminate(term(), map()) -> ok.
terminate(_Reason, #{ets_tab := Tab}) ->
    ets:delete(Tab),
    ok.

%% --- Internal ---

start_zone(
    Coords,
    #{
        ets_tab := Tab,
        zone_sup := ZoneSup,
        zone_last_active := Active,
        zone_monitors := Monitors,
        max_active_zones := MaxActive,
        zone_config := BaseConfig,
        initial_zone_states := InitialStates,
        world_id := WorldId
    } = State
) ->
    case ets:info(Tab, size) >= MaxActive of
        true ->
            {error, max_zones_reached};
        false ->
            Config0 = BaseConfig#{coords => Coords},
            Config =
                case maps:get(Coords, InitialStates, undefined) of
                    undefined -> Config0;
                    ZS when is_map(ZS) -> Config0#{zone_state => ZS};
                    _ -> Config0
                end,
            case asobi_zone_sup:start_zone(ZoneSup, Config) of
                {ok, Pid} ->
                    ets:insert(Tab, {Coords, Pid}),
                    asobi_telemetry:zone_opened(WorldId, Coords),
                    MonRef = monitor(process, Pid),
                    Now = erlang:monotonic_time(millisecond),
                    State1 = State#{
                        zone_last_active => Active#{Coords => Now},
                        zone_monitors => Monitors#{MonRef => Coords, Coords => MonRef}
                    },
                    {ok, Pid, State1};
                {error, _} = Err ->
                    Err
            end
    end.

cleanup_zone(
    Coords,
    #{
        ets_tab := Tab,
        zone_last_active := Active,
        zone_monitors := Monitors,
        world_id := WorldId
    } = State
) ->
    %% cleanup_zone/2 is reachable more than once for the same coords (a DOWN
    %% racing await_zone_down/3, for one), so gate the close on the row still
    %% being there - a live-zone gauge built from opened minus closed would go
    %% negative otherwise.
    case ets:member(Tab, Coords) of
        true -> asobi_telemetry:zone_closed(WorldId, Coords);
        false -> ok
    end,
    %% The zone's own terminate/2 clears this too, but it does not run when the
    %% zone is killed rather than stopped - and a stale band row keeps a dead
    %% entity visible to every neighbour until the coords are next occupied.
    %% Clearing it here covers the reaped and the crashed alike, and it is
    %% idempotent.
    asobi_zone_border:clear(
        maps:get(border_tab, maps:get(zone_config, State, #{}), undefined), Coords
    ),
    ets:delete(Tab, Coords),
    Monitors1 =
        case maps:get(Coords, Monitors, undefined) of
            undefined ->
                Monitors;
            MonRef ->
                demonitor(MonRef, [flush]),
                maps:without([Coords, MonRef], Monitors)
        end,
    State#{
        zone_last_active => maps:remove(Coords, Active),
        zone_monitors => Monitors1
    }.

%% The manager owns a monitor on every zone it has in ETS, so the DOWN for a
%% zone a caller has just seen die is either already in this mailbox or on its
%% way. Consuming it here (instead of returning and letting the normal
%% handle_info clean up later) is what makes revive_zone/3 a single atomic
%% step from the caller's point of view. The bound is a backstop for a zone
%% that turns out not to be dying at all - reply an error rather than start a
%% second zone over a live one.
-spec await_zone_down({integer(), integer()}, pid(), map()) -> {ok, map()} | timeout.
await_zone_down(Coords, ZonePid, #{zone_monitors := Monitors} = State) ->
    case maps:get(Coords, Monitors, undefined) of
        undefined ->
            {ok, cleanup_zone(Coords, State)};
        MonRef ->
            receive
                {'DOWN', MonRef, process, ZonePid, _Reason} ->
                    {ok, cleanup_zone(Coords, State)}
            after 1_000 ->
                timeout
            end
    end.

reap_idle_zones(
    #{
        zone_last_active := Active,
        idle_timeout := Timeout,
        ets_tab := Tab
    } = State
) ->
    Now = erlang:monotonic_time(millisecond),
    Expired = maps:fold(
        fun(Coords, LastActive, Acc) ->
            case Now - LastActive > Timeout of
                true -> [Coords | Acc];
                false -> Acc
            end
        end,
        [],
        Active
    ),
    reap_expired(Expired, Tab, State).

%% Explicit recursion: see docs/eqwalizer-idioms.md.
-spec reap_expired([{integer(), integer()}], ets:table(), map()) -> map().
reap_expired([], _Tab, State) ->
    State;
reap_expired([Coords | Rest], Tab, State) ->
    case ets:lookup(Tab, Coords) of
        [{Coords, Pid}] when is_pid(Pid) ->
            %% Stop gracefully so the zone writes a final snapshot via
            %% terminate/2. Keep the ets slot + monitor until it is actually
            %% gone: cleanup runs on the pid-guarded DOWN / zone_terminated, so
            %% a request can't recreate the zone (and load a stale snapshot)
            %% until the old one finished.
            asobi_zone:reap(Pid),
            reap_expired(Rest, Tab, State);
        _ ->
            reap_expired(Rest, Tab, cleanup_zone(Coords, State))
    end.

touch(Coords, #{zone_last_active := Active} = State) ->
    Now = erlang:monotonic_time(millisecond),
    State#{zone_last_active => Active#{Coords => Now}}.

schedule_reap() ->
    Ref = make_ref(),
    erlang:send_after(?REAP_INTERVAL, self(), {reap_idle, Ref}),
    Ref.

ets_lookup(Ref, Coords) ->
    ets_lookup(Ref, Coords, ?DEFAULT_CALL_TIMEOUT).

ets_lookup(Ref, Coords, _Timeout) when is_atom(Ref) ->
    case ets:lookup(Ref, Coords) of
        [{Coords, Pid}] -> {ok, Pid};
        [] -> not_loaded
    end;
ets_lookup(Ref, Coords, Timeout) when is_pid(Ref) ->
    case gen_server:call(Ref, {lookup_zone, Coords}, Timeout) of
        {ok, P} when is_pid(P) -> {ok, P};
        not_loaded -> not_loaded
    end.

-spec prewarm_zones([{integer(), integer()}], map()) -> map().
prewarm_zones([], State) ->
    State;
prewarm_zones([Coords | Rest], #{ets_tab := Tab} = State) ->
    State1 =
        case ets:lookup(Tab, Coords) of
            [{_, _}] ->
                State;
            [] ->
                case start_zone(Coords, State) of
                    {ok, _Pid, S1} -> S1;
                    {error, _} -> State
                end
        end,
    prewarm_zones(Rest, State1).
