-module(asobi_zone).
-behaviour(gen_server).

-export([start_link/1]).
-export([tick/2, player_input/3, add_entity/3, remove_entity/2]).
-export([subscribe/2, unsubscribe/2]).
-export([get_entities/1, get_subscriber_count/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(PG_SCOPE, nova_scope).

%% --- Public API ---

-spec start_link(map()) -> gen_server:start_ret().
start_link(Config) ->
    gen_server:start_link(?MODULE, Config, []).

-spec tick(pid(), non_neg_integer()) -> ok.
tick(Pid, TickN) ->
    gen_server:cast(Pid, {tick, TickN}).

-spec player_input(pid(), binary(), map()) -> ok.
player_input(Pid, PlayerId, Input) ->
    gen_server:cast(Pid, {input, PlayerId, Input}).

-spec add_entity(pid(), binary(), map()) -> ok.
add_entity(Pid, EntityId, EntityState) ->
    gen_server:cast(Pid, {add_entity, EntityId, EntityState}).

-spec remove_entity(pid(), binary()) -> ok.
remove_entity(Pid, EntityId) ->
    gen_server:cast(Pid, {remove_entity, EntityId}).

-spec subscribe(pid(), {binary(), pid()}) -> ok.
subscribe(Pid, {PlayerId, PlayerPid}) ->
    gen_server:cast(Pid, {subscribe, PlayerId, PlayerPid}).

-spec unsubscribe(pid(), binary()) -> ok.
unsubscribe(Pid, PlayerId) ->
    gen_server:cast(Pid, {unsubscribe, PlayerId}).

-spec get_entities(pid()) -> map().
get_entities(Pid) ->
    gen_server:call(Pid, get_entities).

-spec get_subscriber_count(pid()) -> non_neg_integer().
get_subscriber_count(Pid) ->
    gen_server:call(Pid, get_subscriber_count).

%% --- gen_server callbacks ---

-spec init(map()) -> {ok, map()}.
init(Config) ->
    WorldId = maps:get(world_id, Config),
    Coords = maps:get(coords, Config),
    TickerPid = maps:get(ticker_pid, Config),
    GameModule = maps:get(game_module, Config),
    ZoneState = maps:get(zone_state, Config, #{}),
    pg:join(?PG_SCOPE, {asobi_zone, WorldId, Coords}, self()),
    {ok, #{
        world_id => WorldId,
        coords => Coords,
        ticker_pid => TickerPid,
        game_module => GameModule,
        entities => #{},
        prev_entities => #{},
        subscribers => #{},
        zone_state => ZoneState,
        input_queue => [],
        tick => 0
    }}.

-spec handle_call(term(), gen_server:from(), map()) -> {reply, term(), map()}.
handle_call(get_entities, _From, #{entities := Entities} = State) ->
    {reply, Entities, State};
handle_call(get_subscriber_count, _From, #{subscribers := Subs} = State) ->
    {reply, map_size(Subs), State};
handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

-spec handle_cast(term(), map()) -> {noreply, map()}.
handle_cast({tick, TickN}, State) ->
    State1 = do_tick(TickN, State),
    {noreply, State1};
handle_cast({input, PlayerId, Input}, #{input_queue := Queue} = State) ->
    {noreply, State#{input_queue => [{PlayerId, Input} | Queue]}};
handle_cast({add_entity, EntityId, EntityState}, #{entities := Entities} = State) ->
    {noreply, State#{entities => Entities#{EntityId => EntityState}}};
handle_cast({remove_entity, EntityId}, #{entities := Entities} = State) ->
    {noreply, State#{entities => maps:remove(EntityId, Entities)}};
handle_cast({subscribe, PlayerId, PlayerPid}, #{subscribers := Subs} = State) ->
    MonRef = monitor(process, PlayerPid),
    {noreply, State#{subscribers => Subs#{PlayerId => {PlayerPid, MonRef}}}};
handle_cast({unsubscribe, PlayerId}, #{subscribers := Subs} = State) ->
    case maps:get(PlayerId, Subs, undefined) of
        undefined ->
            {noreply, State};
        {_Pid, MonRef} ->
            demonitor(MonRef, [flush]),
            {noreply, State#{subscribers => maps:remove(PlayerId, Subs)}}
    end;
handle_cast(_Msg, State) ->
    {noreply, State}.

-spec handle_info(term(), map()) -> {noreply, map()}.
handle_info({'DOWN', _Ref, process, DownPid, _Reason}, #{subscribers := Subs} = State) ->
    Subs1 = maps:filter(
        fun(_PlayerId, {Pid, _MonRef}) -> Pid =/= DownPid end,
        Subs
    ),
    {noreply, State#{subscribers => Subs1}};
handle_info(_Info, State) ->
    {noreply, State}.

-spec terminate(term(), map()) -> ok.
terminate(_Reason, #{world_id := WorldId, coords := Coords}) ->
    pg:leave(?PG_SCOPE, {asobi_zone, WorldId, Coords}, self()),
    ok.

%% --- Internal ---

do_tick(
    TickN,
    #{
        game_module := GameMod,
        entities := Entities,
        prev_entities := PrevEntities,
        zone_state := ZoneState,
        input_queue := Queue,
        subscribers := Subs,
        ticker_pid := TickerPid
    } = State
) ->
    Entities1 = apply_inputs(GameMod, Queue, Entities),
    {Entities2, ZoneState1} = GameMod:zone_tick(Entities1, ZoneState),
    Deltas = compute_deltas(PrevEntities, Entities2),
    broadcast_deltas(TickN, Deltas, Subs),
    asobi_world_ticker:tick_done(TickerPid, self(), TickN),
    State#{
        entities => Entities2,
        prev_entities => Entities2,
        zone_state => ZoneState1,
        input_queue => [],
        tick => TickN
    }.

apply_inputs(_GameMod, [], Entities) ->
    Entities;
apply_inputs(GameMod, [{PlayerId, Input} | Rest], Entities) ->
    case GameMod:handle_input(PlayerId, Input, Entities) of
        {ok, Entities1} ->
            apply_inputs(GameMod, Rest, Entities1);
        {error, Reason} ->
            logger:warning(#{
                msg => ~"zone input rejected",
                player_id => PlayerId,
                reason => Reason
            }),
            apply_inputs(GameMod, Rest, Entities)
    end.

-spec compute_deltas(map(), map()) -> [term()].
compute_deltas(OldEntities, NewEntities) ->
    Updates = maps:fold(
        fun(Id, NewState, Acc) ->
            case maps:find(Id, OldEntities) of
                {ok, NewState} ->
                    Acc;
                {ok, OldState} ->
                    Diff = maps:filter(
                        fun(K, V) -> maps:get(K, OldState, undefined) =/= V end,
                        NewState
                    ),
                    case map_size(Diff) of
                        0 -> Acc;
                        _ -> [{updated, Id, Diff} | Acc]
                    end;
                error ->
                    [{added, Id, NewState} | Acc]
            end
        end,
        [],
        NewEntities
    ),
    Removed = [
        {removed, Id}
     || Id <- maps:keys(OldEntities), not maps:is_key(Id, NewEntities)
    ],
    Updates ++ Removed.

broadcast_deltas(_TickN, [], _Subs) ->
    ok;
broadcast_deltas(TickN, Deltas, Subs) ->
    Msg = {asobi_message, {zone_delta, TickN, encode_deltas(Deltas)}},
    maps:foreach(
        fun(_PlayerId, {Pid, _MonRef}) -> Pid ! Msg end,
        Subs
    ).

encode_deltas(Deltas) ->
    [encode_delta(D) || D <- Deltas].

encode_delta({updated, Id, Diff}) ->
    Diff#{~"op" => ~"u", ~"id" => Id};
encode_delta({added, Id, FullState}) ->
    FullState#{~"op" => ~"a", ~"id" => Id};
encode_delta({removed, Id}) ->
    #{~"op" => ~"r", ~"id" => Id}.
