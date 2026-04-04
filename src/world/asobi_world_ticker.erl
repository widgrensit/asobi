-module(asobi_world_ticker).
-behaviour(gen_server).

-export([start_link/1]).
-export([tick_done/3, set_zones/3, get_tick/1]).
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

-spec get_tick(pid()) -> non_neg_integer().
get_tick(TickerPid) ->
    gen_server:call(TickerPid, get_tick).

%% --- gen_server callbacks ---

-spec init(map()) -> {ok, map()}.
init(Config) ->
    TickRate = maps:get(tick_rate, Config, 50),
    WorldPid = maps:get(world_pid, Config, undefined),
    {ok, #{
        tick => 0,
        tick_rate => TickRate,
        world_pid => WorldPid,
        zones => [],
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
    {noreply, State#{zones => Zones, world_pid => WorldPid, running => true}};
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
        zones := Zones
    } = State
) ->
    NextTick = Tick + 1,
    Pending = maps:from_keys(Zones, true),
    lists:foreach(fun(Z) -> asobi_zone:tick(Z, NextTick) end, Zones),
    erlang:send_after(TickRate, self(), tick),
    {noreply, State#{tick => NextTick, pending => Pending}};
handle_info(_Info, State) ->
    {noreply, State}.
