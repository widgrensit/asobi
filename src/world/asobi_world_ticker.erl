-module(asobi_world_ticker).
-behaviour(gen_server).

-export([start_link/1]).
-export([tick_done/3, set_zones/3, set_zone_manager/3, get_tick/1]).
-export([promote_zone/2, demote_zone/2, remove_zone/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

%% #313: a world tick is the fan-out to every zone plus the fan-in of their
%% tick_done replies, which is the saturation signal an operator watching a
%% world server wants. At the default 50ms tick rate that is 20 events per
%% second per world - too hot for a raw sink - so sample roughly once a second
%% and carry the window's worst tick alongside the sampled one. Override with
%% `tick_sample_interval_ms` in the ticker config.
-define(DEFAULT_TICK_SAMPLE_INTERVAL_MS, 1000).

%% --- Public API ---

-spec start_link(map()) -> gen_server:start_ret().
start_link(Config) ->
    gen_server:start_link(?MODULE, Config, []).

-spec tick_done(pid(), pid(), non_neg_integer()) -> ok.
tick_done(TickerPid, ZonePid, TickN) ->
    gen_server:cast(TickerPid, {tick_done, ZonePid, TickN}).

-spec set_zones(pid(), [pid()], pid()) -> ok.
set_zones(TickerPid, Zones, WorldPid) ->
    gen_server:cast(TickerPid, {set_zones, Zones, WorldPid}).

-spec set_zone_manager(pid(), pid(), pid()) -> ok.
set_zone_manager(TickerPid, ZoneManagerPid, WorldPid) ->
    gen_server:cast(TickerPid, {set_zone_manager, ZoneManagerPid, WorldPid}).

-spec get_tick(pid()) -> non_neg_integer().
get_tick(TickerPid) ->
    case gen_server:call(TickerPid, get_tick) of
        N when is_integer(N), N >= 0 -> N
    end.

-spec promote_zone(pid(), pid()) -> ok.
promote_zone(TickerPid, ZonePid) ->
    gen_server:cast(TickerPid, {promote_zone, ZonePid}).

-spec demote_zone(pid(), pid()) -> ok.
demote_zone(TickerPid, ZonePid) ->
    gen_server:cast(TickerPid, {demote_zone, ZonePid}).

-spec remove_zone(pid(), pid()) -> ok.
remove_zone(TickerPid, ZonePid) ->
    gen_server:cast(TickerPid, {remove_zone, ZonePid}).

%% --- gen_server callbacks ---

-spec init(map()) -> {ok, map()}.
init(Config) ->
    TickRate = maps:get(tick_rate, Config, 50),
    WorldPid = maps:get(world_pid, Config, undefined),
    ZoneManager = maps:get(zone_manager, Config, undefined),
    ColdTickDivisor = maps:get(cold_tick_divisor, Config, 10),
    {ok, #{
        tick => 0,
        tick_rate => TickRate,
        world_id => maps:get(world_id, Config, undefined),
        world_pid => WorldPid,
        zone_manager => ZoneManager,
        hot_zones => [],
        cold_zones => [],
        cold_tick_divisor => ColdTickDivisor,
        tick_count => 0,
        pending => #{},
        outstanding => 0,
        last_post_tick => 0,
        running => false,
        tick_started_at => undefined,
        tick_zone_count => 0,
        max_duration_ms => 0,
        sampled_ticks => 0,
        sample_every => sample_every(TickRate, Config)
    }}.

sample_every(TickRate, Config) ->
    IntervalMs = maps:get(
        tick_sample_interval_ms, Config, ?DEFAULT_TICK_SAMPLE_INTERVAL_MS
    ),
    max(1, IntervalMs div max(TickRate, 1)).

-spec handle_call(term(), gen_server:from(), map()) -> {reply, term(), map()}.
handle_call(get_tick, _From, #{tick := Tick} = State) ->
    {reply, Tick, State};
handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

-spec handle_cast(term(), map()) -> {noreply, map()}.
handle_cast({set_zones, Zones, WorldPid}, State) ->
    {noreply, start_ticking(State#{hot_zones => Zones, world_pid => WorldPid})};
handle_cast({set_zone_manager, ZoneManagerPid, WorldPid}, State) ->
    {noreply, start_ticking(State#{zone_manager => ZoneManagerPid, world_pid => WorldPid})};
handle_cast({promote_zone, ZonePid}, #{hot_zones := Hot, cold_zones := Cold} = State) ->
    Cold1 = lists:delete(ZonePid, Cold),
    Hot1 =
        case lists:member(ZonePid, Hot) of
            true -> Hot;
            false -> [ZonePid | Hot]
        end,
    {noreply, State#{hot_zones => Hot1, cold_zones => Cold1}};
handle_cast({demote_zone, ZonePid}, #{hot_zones := Hot, cold_zones := Cold} = State) ->
    Hot1 = lists:delete(ZonePid, Hot),
    Cold1 =
        case lists:member(ZonePid, Cold) of
            true -> Cold;
            false -> [ZonePid | Cold]
        end,
    {noreply, State#{hot_zones => Hot1, cold_zones => Cold1}};
handle_cast({remove_zone, ZonePid}, #{hot_zones := Hot, cold_zones := Cold} = State) ->
    {noreply, State#{
        hot_zones => lists:delete(ZonePid, Hot),
        cold_zones => lists:delete(ZonePid, Cold)
    }};
%% A reply frees the zone whatever tick it carries: a zone only ever has one
%% tick in flight, so `tick_done` means "this zone is idle again". Matching the
%% reply against the ticker's current tick instead - as this did before #426 -
%% would leave a zone that replied late stuck in `pending` forever, and a
%% zone stuck in `pending` is a zone that never ticks again. The tick number
%% still decides which *tick* retired, just not which *zone* did.
handle_cast(
    {tick_done, ZonePid, TickN},
    #{tick := CurrentTick, pending := Pending} = State
) when is_integer(TickN) ->
    case maps:take(ZonePid, Pending) of
        error ->
            {noreply, State};
        {DispatchedTick, Pending1} ->
            State1 = State#{pending => Pending1},
            case DispatchedTick =:= TickN andalso TickN =:= CurrentTick of
                true -> {noreply, retire_outstanding(TickN, State1)};
                false -> {noreply, State1}
            end
    end;
handle_cast(_Msg, State) ->
    {noreply, State}.

-spec handle_info(term(), map()) -> {noreply, map()}.
handle_info(tick, #{running := false} = State) ->
    {noreply, State};
handle_info(
    tick,
    #{
        tick := Tick,
        tick_rate := TickRate,
        tick_count := TickCount,
        cold_tick_divisor := ColdTickDivisor,
        hot_zones := StaticHot,
        cold_zones := StaticCold,
        zone_manager := ZoneManager,
        pending := Pending,
        world_id := WorldId
    } = State
) ->
    NextTick = Tick + 1,
    NextTickCount = TickCount + 1,
    %% Under a zone manager the active set is the manager's, but which of those
    %% zones are cold is still this ticker's own bookkeeping - it is fed by
    %% asobi_zone's promote/demote casts. Before widgrensit/asobi#543 this
    %% branch discarded `cold_zones` outright. That was not the only reason
    %% `cold_tick_divisor` was inert: nothing anywhere called promote_zone/2 or
    %% demote_zone/2, and `set_zones/3` (the only path that populates the static
    %% lists) has no caller in src/ either, so no world of any shape ever had a
    %% cold zone. This branch is what would have kept it inert for a lazy world
    %% even after the zone side started classifying itself.
    %%
    %% Partitioning the manager's list also prunes the cold set: a zone that has
    %% been reaped is absent from `AllZones` and so drops out of `cold_zones`
    %% below without needing a `remove_zone` cast to arrive.
    {Hot, Cold} =
        case ZoneManager of
            undefined ->
                {StaticHot, StaticCold};
            ZMPid ->
                AllZones = asobi_zone_manager:get_active_zones(ZMPid),
                ColdSet = maps:from_keys(StaticCold, []),
                lists:partition(fun(Z) -> not is_map_key(Z, ColdSet) end, AllZones)
        end,
    TickCold = (NextTickCount rem ColdTickDivisor) =:= 0,
    %% `uniq` because a zone dispatched twice in one tick replies twice, and
    %% the second reply finds nothing left in `pending` to retire - the tick
    %% would then never complete and the world would stop posting.
    Candidates =
        case TickCold of
            true -> lists:uniq(Hot ++ Cold);
            false -> lists:uniq(Hot)
        end,
    %% #426: a zone that has not retired its previous tick is skipped rather
    %% than sent another one. Without this the fan-out is open-loop - a zone
    %% whose `zone_tick` outruns `tick_rate` takes casts faster than it can
    %% retire them and its mailbox grows without bound, which on a Lua world
    %% is terminal: the upkeep that would recover it (a Luerl collection,
    %% releasing entities so the reaper can stop the zone) is itself carried
    %% by a tick, so it queues behind the backlog exactly when it is needed.
    %% Dropping a tick is strictly better than queueing one - the zone tick is
    %% idempotent upkeep and the next tick carries the same work.
    Pending0 = maps:with(Candidates, Pending),
    {ZonesToTick, Skipped} = lists:partition(
        fun(Z) -> not maps:is_key(Z, Pending0) end, Candidates
    ),
    report_skipped(WorldId, Skipped),
    tick_zones(ZonesToTick, NextTick),
    erlang:send_after(TickRate, self(), tick),
    State1 = State#{
        tick => NextTick,
        tick_count => NextTickCount,
        hot_zones => Hot,
        cold_zones => Cold,
        tick_started_at => erlang:monotonic_time(millisecond),
        tick_zone_count => length(ZonesToTick),
        pending => maps:merge(Pending0, maps:from_keys(ZonesToTick, NextTick)),
        outstanding => length(ZonesToTick)
    },
    case ZonesToTick of
        [] -> {noreply, complete_tick(maybe_post_tick(NextTick, State1))};
        _ -> {noreply, State1}
    end;
handle_info(_Info, State) ->
    {noreply, State}.

start_ticking(#{running := true} = State) ->
    State;
start_ticking(#{tick_rate := TickRate} = State) ->
    erlang:send_after(TickRate, self(), tick),
    State#{running => true}.

retire_outstanding(TickN, #{outstanding := Outstanding} = State) ->
    case max(0, Outstanding - 1) of
        0 -> complete_tick(maybe_post_tick(TickN, State#{outstanding => 0}));
        N -> State#{outstanding => N}
    end.

%% The world's `post_tick` drives phase timers and reconnect deadlines, so it
%% must never run backwards or twice for the same tick. A tick whose fan-in
%% completes after a later tick has already posted is simply not posted.
maybe_post_tick(TickN, #{last_post_tick := Last, world_pid := WorldPid} = State) when
    TickN > Last
->
    asobi_world_server:post_tick(WorldPid, TickN),
    State#{last_post_tick => TickN};
maybe_post_tick(_TickN, State) ->
    State.

report_skipped(_WorldId, []) ->
    ok;
report_skipped(WorldId, Skipped) ->
    asobi_telemetry:zone_tick_skipped(WorldId, length(Skipped)).

%% A tick that never fans in (a zone died mid-tick) is simply never sampled -
%% the next fan-out overwrites tick_started_at. Emitting a bogus duration for
%% it would be worse than the gap, and the zone's own DOWN is the signal for
%% that failure.
complete_tick(#{tick_started_at := undefined} = State) ->
    State;
complete_tick(
    #{
        tick_started_at := StartedAt,
        tick_zone_count := ZoneCount,
        max_duration_ms := MaxSoFar,
        sampled_ticks := Sampled,
        sample_every := SampleEvery,
        world_id := WorldId
    } = State
) ->
    DurationMs = erlang:monotonic_time(millisecond) - StartedAt,
    MaxDurationMs = max(MaxSoFar, DurationMs),
    case Sampled + 1 >= SampleEvery of
        true ->
            asobi_telemetry:world_tick(WorldId, DurationMs, MaxDurationMs, ZoneCount),
            State#{tick_started_at => undefined, max_duration_ms => 0, sampled_ticks => 0};
        false ->
            State#{
                tick_started_at => undefined,
                max_duration_ms => MaxDurationMs,
                sampled_ticks => Sampled + 1
            }
    end.

-spec tick_zones([term()], non_neg_integer()) -> ok.
tick_zones([], _NextTick) ->
    ok;
tick_zones([Z | Rest], NextTick) when is_pid(Z) ->
    asobi_zone:tick(Z, NextTick),
    tick_zones(Rest, NextTick);
tick_zones([_ | Rest], NextTick) ->
    tick_zones(Rest, NextTick).
