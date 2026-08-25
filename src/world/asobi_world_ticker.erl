-module(asobi_world_ticker).
-behaviour(gen_server).

-export([start_link/1]).
-export([tick_done/3, set_zones/3, set_zone_manager/3, get_tick/1]).
-export([promote_zone/2, demote_zone/2, add_zone/2, remove_zone/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-include_lib("kernel/include/logger.hrl").

%% #313: a world tick is the fan-out to every zone plus the fan-in of their
%% tick_done replies, which is the saturation signal an operator watching a
%% world server wants. At the default 50ms tick rate that is 20 events per
%% second per world - too hot for a raw sink - so sample roughly once a second
%% and carry the window's worst tick alongside the sampled one. Override with
%% `tick_sample_interval_ms` in the ticker config.
-define(DEFAULT_TICK_SAMPLE_INTERVAL_MS, 1000).
-define(DEFAULT_TICK_RATE, 50).
-define(DEFAULT_COLD_DIVISOR, 10).

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

-doc """
Take ownership of a zone, hot, from the moment it exists.

Before widgrensit/asobi#560 the ticker asked the zone manager for the active
set on EVERY tick, and the manager answered with `ets:tab2list/1` - a full
table copy plus a list rebuild, 20 times a second on a world with thousands of
loaded zones, before a single zone had been ticked. The set only changes when
a zone opens or closes, so it is pushed here instead and the manager is off
the per-tick path entirely (with widgrensit/asobi#559, off the tick path full
stop).

The ticker monitors what it is told about, so a reaped or crashed zone drops
out on its `DOWN` without needing `remove_zone/2` to arrive - which is the
self-healing the old partition-against-the-manager's-list gave for free.
""".
-spec add_zone(pid(), pid()) -> ok.
add_zone(TickerPid, ZonePid) ->
    gen_server:cast(TickerPid, {add_zone, ZonePid}).

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
    %% Hardened here, not at each reader: start_ticking/1 feeds this straight
    %% to erlang:send_after/3, and sample_every/2 divides by it. Reading it raw
    %% let the two disagree about the same field.
    TickRate = pos_int(maps:get(tick_rate, Config, ?DEFAULT_TICK_RATE), ?DEFAULT_TICK_RATE),
    WorldPid = maps:get(world_pid, Config, undefined),
    ZoneManager = maps:get(zone_manager, Config, undefined),
    ColdTickDivisor = cold_divisor(maps:get(cold_tick_divisor, Config, ?DEFAULT_COLD_DIVISOR)),
    {ok, #{
        tick => 0,
        tick_rate => TickRate,
        world_id => maps:get(world_id, Config, undefined),
        world_pid => WorldPid,
        %% Diagnostic only since widgrensit/asobi#560 - the ticker owns its own
        %% active set and never asks the manager for anything. Kept so
        %% `sys:get_state/1` still says which manager this ticker belongs to.
        %% `set_zone_manager/3`'s remaining effect is start_ticking/1, which is
        %% what actually starts the world: do not delete that call as dead
        %% plumbing on the strength of this field being unread.
        zone_manager => ZoneManager,
        %% Maps used as sets: the tick loop derives its candidate list from
        %% these every tick, and `lists:uniq/1` on a list of thousands of zones
        %% is per-tick work a map's key set gives for nothing. Kept disjoint by
        %% construction, so `maps:keys(Hot) ++ maps:keys(Cold)` has no
        %% duplicates and needs no `uniq`.
        hot_zones => #{},
        cold_zones => #{},
        %% One monitor per known zone, so a zone that dies leaves both sets
        %% without anyone having to tell us.
        zone_monitors => #{},
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

-spec sample_every(pos_integer(), map()) -> pos_integer().
sample_every(TickRate, Config) ->
    IntervalMs = non_neg_int(
        maps:get(tick_sample_interval_ms, Config, ?DEFAULT_TICK_SAMPLE_INTERVAL_MS)
    ),
    pos_int(IntervalMs div TickRate, 1).

%% A Lua game cannot deliver a bad tick_rate - asobi_lua_config guards
%% is_integer and > 0 upstream - but a hand-written Erlang `game_modes` map
%% can, and that used to be a badarith inside the tick loop.
-spec pos_int(term(), pos_integer()) -> pos_integer().
pos_int(V, _Default) when is_integer(V), V > 0 -> V;
pos_int(_V, Default) -> Default.

%% max_duration_ms is reset to 0 every sample, so it is non-negative rather
%% than positive - pos_int/2 would be the wrong shape here.
-spec non_neg_int(term()) -> non_neg_integer().
non_neg_int(V) when is_integer(V), V >= 0 -> V;
non_neg_int(_V) -> 0.

-spec larger(integer(), integer()) -> integer().
larger(A, B) when A >= B -> A;
larger(_A, B) -> B.

-spec handle_call(term(), gen_server:from(), map()) -> {reply, term(), map()}.
handle_call(get_tick, _From, #{tick := Tick} = State) ->
    {reply, Tick, State};
handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

-spec handle_cast(term(), map()) -> {noreply, map()}.
%% Replaces the set rather than adding to it, which is what "set" has always
%% meant here - and now that the ticker holds a monitor per zone, the ones it
%% is dropping have to be released too.
handle_cast({set_zones, Zones, WorldPid}, State) when is_list(Zones) ->
    State1 = forget_all(maps:keys(maps:get(zone_monitors, State)), State),
    {noreply, start_ticking(add_all(Zones, State1#{world_pid => WorldPid}))};
handle_cast({set_zone_manager, ZoneManagerPid, WorldPid}, State) ->
    {noreply, start_ticking(State#{zone_manager => ZoneManagerPid, world_pid => WorldPid})};
handle_cast({add_zone, ZonePid}, State) when is_pid(ZonePid) ->
    {noreply, add_known(ZonePid, State)};
%% Promotion doubles as registration: a zone that warms up before its opener's
%% `add_zone` lands must not be left out of the tick.
handle_cast({promote_zone, ZonePid}, #{hot_zones := Hot, cold_zones := Cold} = State) when
    is_pid(ZonePid)
->
    State1 = watch(ZonePid, State),
    {noreply, State1#{
        hot_zones => Hot#{ZonePid => ok},
        cold_zones => maps:remove(ZonePid, Cold)
    }};
%% Demotion registers an unknown zone as COLD, which at `cold_tick_divisor = 0`
%% means it never ticks. Safe because the only sender is `reclassify/1`, which
%% runs inside the zone's own `do_tick` - so the ticker has already dispatched
%% to it and therefore already knows it.
handle_cast({demote_zone, ZonePid}, #{hot_zones := Hot, cold_zones := Cold} = State) when
    is_pid(ZonePid)
->
    State1 = watch(ZonePid, State),
    {noreply, State1#{
        hot_zones => maps:remove(ZonePid, Hot),
        cold_zones => Cold#{ZonePid => ok}
    }};
handle_cast({remove_zone, ZonePid}, State) when is_pid(ZonePid) ->
    {noreply, forget(ZonePid, State)};
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
        hot_zones := Hot,
        cold_zones := Cold,
        pending := Pending,
        world_id := WorldId
    } = State
) ->
    NextTick = Tick + 1,
    NextTickCount = TickCount + 1,
    %% The hot/cold split is this ticker's own bookkeeping, fed by asobi_zone's
    %% add/promote/demote casts and pruned by the zones' own `DOWN`s
    %% (widgrensit/asobi#560). It used to be re-derived from the zone manager
    %% every tick, which cost a full `ets:tab2list/1` of the world's loaded
    %% zones - plus, when the manager was addressed by pid, a `gen_server` call
    %% into the same process the join and crossing paths go through.
    %%
    TickCold = tick_cold(NextTickCount, ColdTickDivisor),
    %% No `lists:uniq/1`: the two sets are disjoint map key sets.
    Candidates =
        case TickCold of
            true -> maps:keys(Hot) ++ maps:keys(Cold);
            false -> maps:keys(Hot)
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
        tick_started_at => erlang:monotonic_time(millisecond),
        tick_zone_count => length(ZonesToTick),
        pending => maps:merge(Pending0, maps:from_keys(ZonesToTick, NextTick)),
        outstanding => length(ZonesToTick)
    },
    case ZonesToTick of
        [] -> {noreply, complete_tick(maybe_post_tick(NextTick, State1))};
        _ -> {noreply, State1}
    end;
handle_info({'DOWN', MonRef, process, ZonePid, _Reason}, #{zone_monitors := Mons} = State) when
    is_pid(ZonePid)
->
    case maps:get(ZonePid, Mons, undefined) of
        MonRef -> {noreply, forget(ZonePid, State)};
        _ -> {noreply, State}
    end;
handle_info(_Info, State) ->
    {noreply, State}.

%% `0` means an idle zone is not ticked at all: `warm_up/1` on the message that
%% creates the work is then the only transition back, which is ADR 0016's
%% decision 2 doing a load-bearing job rather than an optimisation. See ADR
%% 0021 and widgrensit/asobi#561.
-spec tick_cold(pos_integer(), non_neg_integer()) -> boolean().
tick_cold(_TickCount, 0) -> false;
tick_cold(TickCount, Divisor) -> (TickCount rem Divisor) =:= 0.

%% Hardened here rather than at the reader, for the same reason `tick_rate` is:
%% a Lua game cannot deliver a bad value (`asobi_lua_config` guards it) but a
%% hand-written Erlang `game_modes` map can.
%%
%% A bad value takes the DOCUMENTED DEFAULT, loudly - never the never-tick
%% regime. Folding `"10"` or `-1` into 0 would hand a world the most aggressive
%% setting in the system by typo, and ADR 0021 is explicit that at 0 the whole
%% thing rests on `warm_up/1`: that is a property a world opts into, not one it
%% lands in silently.
-spec cold_divisor(term()) -> non_neg_integer().
cold_divisor(D) when is_integer(D), D >= 0 ->
    D;
cold_divisor(D) ->
    ?LOG_WARNING(#{
        msg => ~"cold_tick_divisor must be a non-negative integer; using the default",
        value => io_lib:format("~P", [D, 4]),
        default => ?DEFAULT_COLD_DIVISOR
    }),
    ?DEFAULT_COLD_DIVISOR.

%% Explicit recursion: see docs/eqwalizer-idioms.md.
-spec add_all([term()], map()) -> map().
add_all([], State) -> State;
add_all([ZonePid | Rest], State) -> add_all(Rest, add_known(ZonePid, State)).

-spec forget_all([term()], map()) -> map().
forget_all([], State) ->
    State;
forget_all([ZonePid | Rest], State) when is_pid(ZonePid) ->
    forget_all(Rest, forget(ZonePid, State));
forget_all([_ | Rest], State) ->
    forget_all(Rest, State).

%% A newly-known zone starts hot: it has not ticked, so it has not established
%% that it is idle - the same reason asobi_zone's own `cold` starts false.
-spec add_known(term(), map()) -> map().
add_known(ZonePid, #{hot_zones := Hot, cold_zones := Cold} = State) when is_pid(ZonePid) ->
    case is_map_key(ZonePid, Hot) orelse is_map_key(ZonePid, Cold) of
        true -> State;
        false -> (watch(ZonePid, State))#{hot_zones => Hot#{ZonePid => ok}}
    end;
add_known(_ZonePid, State) ->
    State.

-spec watch(pid(), map()) -> map().
watch(ZonePid, #{zone_monitors := Mons} = State) ->
    case is_map_key(ZonePid, Mons) of
        true -> State;
        false -> State#{zone_monitors => Mons#{ZonePid => monitor(process, ZonePid)}}
    end.

-spec forget(pid(), map()) -> map().
forget(ZonePid, #{hot_zones := Hot, cold_zones := Cold, zone_monitors := Mons} = State) ->
    Mons1 =
        case maps:take(ZonePid, Mons) of
            {MonRef, Rest} ->
                demonitor(MonRef, [flush]),
                Rest;
            error ->
                Mons
        end,
    State#{
        hot_zones => maps:remove(ZonePid, Hot),
        cold_zones => maps:remove(ZonePid, Cold),
        zone_monitors => Mons1
    }.

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
    MaxDurationMs = larger(non_neg_int(MaxSoFar), DurationMs),
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
