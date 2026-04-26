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
-export([ensure_zone/2, get_zone/2, touch_zone/2, release_zone/2]).
-export([get_active_zones/1, zone_terminated/2, pre_warm/1]).
-export([register_zone/3, set_zone_config/2, set_initial_zone_states/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(REAP_INTERVAL, 10_000).
-define(DEFAULT_IDLE_TIMEOUT, 30_000).
-define(DEFAULT_MAX_ACTIVE, 10_000).

%% --- Public API ---

-doc "Start the zone manager.".
-spec start_link(map()) -> gen_server:start_ret().
start_link(Opts) ->
    gen_server:start_link(?MODULE, Opts, []).

-doc "Return existing zone or start a new one. ETS fast path first.".
-spec ensure_zone(pid() | atom(), {integer(), integer()}) -> {ok, pid()} | {error, term()}.
ensure_zone(Ref, Coords) ->
    case ets_lookup(Ref, Coords) of
        {ok, Pid} ->
            {ok, Pid};
        not_loaded ->
            case gen_server:call(Ref, {ensure_zone, Coords}) of
                {ok, P} when is_pid(P) -> {ok, P};
                {error, _} = Err -> Err
            end
    end.

-doc "Non-creating lookup. ETS only.".
-spec get_zone(pid() | atom(), {integer(), integer()}) -> {ok, pid()} | not_loaded.
get_zone(Ref, Coords) ->
    ets_lookup(Ref, Coords).

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
    [Pid || {_Coords, Pid} <- ets:tab2list(Ref)];
get_active_zones(Ref) when is_pid(Ref) ->
    narrow_pid_list(gen_server:call(Ref, get_active_zones)).

-spec narrow_pid_list(term()) -> [pid()].
narrow_pid_list([]) -> [];
narrow_pid_list([P | Rest]) when is_pid(P) -> [P | narrow_pid_list(Rest)].

-doc "Called by zone on terminate. Cleans up ETS entry.".
-spec zone_terminated(pid() | atom(), {integer(), integer()}) -> ok.
zone_terminated(Ref, Coords) ->
    gen_server:cast(Ref, {zone_terminated, Coords}).

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
            {reply, {ok, Pid}, touch(Coords, State)};
        [] ->
            case start_zone(Coords, State) of
                {ok, Pid, State1} ->
                    {reply, {ok, Pid}, State1};
                {error, Reason} ->
                    {reply, {error, Reason}, State}
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
handle_cast({zone_terminated, Coords}, State) ->
    {noreply, cleanup_zone(Coords, State)};
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
handle_info({'DOWN', MonRef, process, _Pid, _Reason}, #{zone_monitors := Monitors} = State) ->
    case maps:get(MonRef, Monitors, undefined) of
        undefined ->
            {noreply, State};
        Coords ->
            {noreply, cleanup_zone(Coords, State)}
    end;
handle_info(_Info, State) ->
    {noreply, State}.

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
        initial_zone_states := InitialStates
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
        zone_monitors := Monitors
    } = State
) ->
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

reap_idle_zones(
    #{
        world_id := WorldId,
        zone_last_active := Active,
        idle_timeout := Timeout,
        ets_tab := Tab,
        zone_sup := ZoneSup
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
    lists:foldl(
        fun(Coords, SAcc) ->
            case ets:lookup(Tab, Coords) of
                [{Coords, Pid}] ->
                    snapshot_before_reap(WorldId, Coords, Pid),
                    SAcc1 = cleanup_zone(Coords, SAcc),
                    _ = terminate_zone(ZoneSup, Pid),
                    SAcc1;
                [] ->
                    cleanup_zone(Coords, SAcc)
            end
        end,
        State,
        Expired
    ).

snapshot_before_reap(WorldId, Coords, Pid) ->
    try
        Entities = asobi_zone:get_entities(Pid),
        case map_size(Entities) of
            0 ->
                ok;
            _ ->
                asobi_zone_snapshotter:snapshot_sync(#{
                    world_id => WorldId,
                    coords => Coords,
                    entities => Entities,
                    zone_state => #{},
                    entity_timers => #{},
                    spawner_state => #{},
                    tick => 0
                })
        end
    catch
        _:_ -> ok
    end.

terminate_zone(ZoneSup, Pid) ->
    try
        supervisor:terminate_child(ZoneSup, Pid)
    catch
        _:_ -> ok
    end.

touch(Coords, #{zone_last_active := Active} = State) ->
    Now = erlang:monotonic_time(millisecond),
    State#{zone_last_active => Active#{Coords => Now}}.

schedule_reap() ->
    Ref = make_ref(),
    erlang:send_after(?REAP_INTERVAL, self(), {reap_idle, Ref}),
    Ref.

ets_lookup(Ref, Coords) when is_atom(Ref) ->
    case ets:lookup(Ref, Coords) of
        [{Coords, Pid}] -> {ok, Pid};
        [] -> not_loaded
    end;
ets_lookup(Ref, Coords) when is_pid(Ref) ->
    case gen_server:call(Ref, {lookup_zone, Coords}) of
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
