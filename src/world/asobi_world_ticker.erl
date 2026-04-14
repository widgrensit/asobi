-module(asobi_world_ticker).
-behaviour(gen_server).

-export([start_link/1]).
-export([tick_done/3, set_zones/3, set_zone_manager/3, get_tick/1]).
-export([promote_zone/2, demote_zone/2, remove_zone/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

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
    gen_server:call(TickerPid, get_tick).

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
        world_pid => WorldPid,
        zone_manager => ZoneManager,
        hot_zones => [],
        cold_zones => [],
        cold_tick_divisor => ColdTickDivisor,
        tick_count => 0,
        pending => #{},
        running => false
    }}.

-spec handle_call(term(), gen_server:from(), map()) -> {reply, term(), map()}.
handle_call(get_tick, _From, #{tick := Tick} = State) ->
    {reply, Tick, State};
handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

-spec handle_cast(term(), map()) -> {noreply, map()}.
handle_cast({set_zones, Zones, WorldPid}, #{tick_rate := TickRate} = State) ->
    erlang:send_after(TickRate, self(), tick),
    {noreply, State#{hot_zones => Zones, world_pid => WorldPid, running => true}};
handle_cast({set_zone_manager, ZoneManagerPid, WorldPid}, #{tick_rate := TickRate} = State) ->
    erlang:send_after(TickRate, self(), tick),
    {noreply, State#{zone_manager => ZoneManagerPid, world_pid => WorldPid, running => true}};
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
handle_cast(
    {tick_done, ZonePid, TickN},
    #{
        tick := CurrentTick,
        pending := Pending,
        world_pid := WorldPid
    } = State
) ->
    case TickN =:= CurrentTick of
        true ->
            Pending1 = maps:remove(ZonePid, Pending),
            case map_size(Pending1) of
                0 ->
                    asobi_world_server:post_tick(WorldPid, TickN),
                    {noreply, State#{pending => #{}}};
                _ ->
                    {noreply, State#{pending => Pending1}}
            end;
        false ->
            {noreply, State}
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
        zone_manager := ZoneManager
    } = State
) ->
    NextTick = Tick + 1,
    NextTickCount = TickCount + 1,
    {Hot, Cold} =
        case ZoneManager of
            undefined ->
                {StaticHot, StaticCold};
            ZMPid ->
                AllZones = asobi_zone_manager:get_active_zones(ZMPid),
                {AllZones, []}
        end,
    TickCold = (NextTickCount rem ColdTickDivisor) =:= 0,
    ZonesToTick =
        case TickCold of
            true -> Hot ++ Cold;
            false -> Hot
        end,
    Pending = maps:from_keys(ZonesToTick, true),
    lists:foreach(fun(Z) -> asobi_zone:tick(Z, NextTick) end, ZonesToTick),
    erlang:send_after(TickRate, self(), tick),
    case map_size(Pending) of
        0 ->
            asobi_world_server:post_tick(maps:get(world_pid, State), NextTick),
            {noreply, State#{tick => NextTick, tick_count => NextTickCount, pending => #{}}};
        _ ->
            {noreply, State#{tick => NextTick, tick_count => NextTickCount, pending => Pending}}
    end;
handle_info(_Info, State) ->
    {noreply, State}.
