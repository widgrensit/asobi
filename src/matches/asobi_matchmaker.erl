-module(asobi_matchmaker).
-behaviour(gen_server).

-export([start_link/0, add/2, remove/2, get_ticket/1, get_queue_stats/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(DEFAULT_TICK, 1000).

-spec start_link() -> gen_server:start_ret().
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec add(binary(), map()) -> {ok, binary()}.
add(PlayerId, Params) ->
    case gen_server:call(?MODULE, {add, PlayerId, Params}) of
        {ok, TicketId} when is_binary(TicketId) -> {ok, TicketId}
    end.

-spec remove(binary(), binary()) -> ok.
remove(PlayerId, TicketId) ->
    gen_server:cast(?MODULE, {remove, PlayerId, TicketId}).

-spec get_ticket(binary()) -> {ok, map()} | {error, not_found}.
get_ticket(TicketId) ->
    case gen_server:call(?MODULE, {get_ticket, TicketId}) of
        {ok, Ticket} when is_map(Ticket) -> {ok, Ticket};
        {error, not_found} -> {error, not_found}
    end.

-spec get_queue_stats() -> {ok, map()}.
get_queue_stats() ->
    case gen_server:call(?MODULE, get_queue_stats) of
        {ok, Stats} when is_map(Stats) -> {ok, Stats}
    end.

-spec init([]) -> {ok, map()}.
init([]) ->
    Cfg = ensure_map(application:get_env(asobi, matchmaker, #{})),
    TickInterval =
        case maps:get(tick_interval, Cfg, ?DEFAULT_TICK) of
            TI when is_integer(TI) -> TI;
            _ -> ?DEFAULT_TICK
        end,
    erlang:send_after(TickInterval, self(), tick),
    MaxWaitSec =
        case maps:get(max_wait_seconds, Cfg, 60) of
            MW when is_integer(MW) -> MW;
            _ -> 60
        end,
    {ok, #{
        tickets => #{},
        tick_interval => TickInterval,
        max_wait => MaxWaitSec * 1000
    }}.

-spec handle_call(term(), gen_server:from(), map()) -> {reply, term(), map()}.
handle_call({add, PlayerId, Params}, _From, #{tickets := Tickets} = State) when is_map(Params) ->
    TicketId = generate_id(),
    Ticket = #{
        id => TicketId,
        player_id => PlayerId,
        mode => maps:get(mode, Params, ~"default"),
        properties => maps:get(properties, Params, #{}),
        party => maps:get(party, Params, [PlayerId]),
        submitted_at => erlang:system_time(millisecond),
        status => pending
    },
    asobi_telemetry:matchmaker_queued(PlayerId, maps:get(mode, Ticket)),
    {reply, {ok, TicketId}, State#{tickets => Tickets#{TicketId => Ticket}}};
handle_call({get_ticket, TicketId}, _From, #{tickets := Tickets} = State) ->
    case Tickets of
        #{TicketId := Ticket} -> {reply, {ok, Ticket}, State};
        _ -> {reply, {error, not_found}, State}
    end;
handle_call(get_queue_stats, _From, #{tickets := Tickets} = State) ->
    Now = erlang:system_time(millisecond),
    ByMode = maps:fold(
        fun(_Id, #{mode := Mode}, Acc) ->
            Acc#{Mode => maps:get(Mode, Acc, 0) + 1}
        end,
        #{},
        Tickets
    ),
    OldestAge = maps:fold(
        fun(_Id, #{submitted_at := T}, Oldest) ->
            Age = Now - T,
            case Age > Oldest of
                true -> Age;
                false -> Oldest
            end
        end,
        0,
        Tickets
    ),
    Stats = #{
        total => map_size(Tickets),
        by_mode => ByMode,
        oldest_age_ms => OldestAge
    },
    {reply, {ok, Stats}, State};
handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

-spec handle_cast(term(), map()) -> {noreply, map()}.
handle_cast({remove, PlayerId, TicketId}, #{tickets := Tickets} = State) ->
    asobi_telemetry:matchmaker_removed(PlayerId, cancelled),
    {noreply, State#{tickets => maps:remove(TicketId, Tickets)}};
handle_cast(_Msg, State) ->
    {noreply, State}.

-spec handle_info(term(), map()) -> {noreply, map()}.
handle_info(tick, #{tickets := Tickets, tick_interval := Interval, max_wait := MaxWait} = State) ->
    Now = erlang:system_time(millisecond),
    {Matched, Expired, Remaining} = process_tickets(Tickets, Now, MaxWait),
    FailedGroups = spawn_matches(Matched),
    notify_expired(Expired),
    Remaining1 = lists:foldl(
        fun(T, Acc) when is_map(T), is_map(Acc) -> Acc#{maps:get(id, T) => T} end,
        Remaining,
        lists:flatten(FailedGroups)
    ),
    erlang:send_after(Interval, self(), tick),
    {noreply, State#{tickets => Remaining1}};
handle_info(_Info, State) ->
    {noreply, State}.

-spec terminate(term(), map()) -> ok.
terminate(_Reason, _State) ->
    ok.

%% --- Internal ---

-spec process_tickets(map(), integer(), integer()) -> {[[map()]], [map()], map()}.
process_tickets(Tickets, Now, MaxWait) ->
    {Pending, Expired} = maps:fold(
        fun(_Id, #{submitted_at := Sub} = T, {P, E}) ->
            case (Now - Sub) > MaxWait of
                true -> {P, [T | E]};
                false -> {[T | P], E}
            end
        end,
        {[], []},
        Tickets
    ),
    ByMode = group_by_mode(Pending),
    {Matched, Unmatched} = match_all_modes(ByMode),
    Remaining = ensure_map(
        lists:foldl(
            fun(T, Acc) when is_map(T), is_map(Acc) -> Acc#{maps:get(id, T) => T} end,
            #{},
            lists:flatten(Unmatched)
        )
    ),
    {Matched, Expired, Remaining}.

-spec group_by_mode([map()]) -> #{binary() => [map()]}.
group_by_mode(Tickets) ->
    Result = lists:foldl(
        fun(#{mode := Mode} = Ticket, Acc) when is_map(Acc) ->
            maps:update_with(Mode, fun(List) -> [Ticket | List] end, [Ticket], Acc)
        end,
        #{},
        Tickets
    ),
    case Result of
        Map when is_map(Map) -> ensure_typed_map(Map)
    end.

-spec ensure_typed_map(map()) -> #{binary() => [map()]}.
ensure_typed_map(Map) ->
    maps:fold(
        fun
            (Key, Val, Acc) when is_binary(Key), is_list(Val) ->
                Acc#{Key => [Entry || Entry <- Val, is_map(Entry)]};
            (_Key, _Val, Acc) ->
                Acc
        end,
        #{},
        Map
    ).

-spec match_all_modes(#{binary() => [map()]}) -> {[[map()]], [[map()]]}.
match_all_modes(ByMode) ->
    maps:fold(
        fun(Mode, ModeTickets, {AllMatched, AllUnmatched}) ->
            ModeConfig = mode_config(Mode),
            Strategy = resolve_strategy(ModeConfig),
            {M, U} = Strategy:match(ModeTickets, ModeConfig),
            {M ++ AllMatched, [U | AllUnmatched]}
        end,
        {[], []},
        ByMode
    ).

-spec mode_config(binary()) -> map().
mode_config(Mode) ->
    Modes = ensure_map(application:get_env(asobi, game_modes, #{})),
    case Modes of
        #{Mode := Config} when is_map(Config) -> Config;
        #{Mode := Mod} when is_atom(Mod) -> #{module => Mod};
        _ -> #{}
    end.

-spec resolve_strategy(map()) -> module().
resolve_strategy(#{strategy := Strategy}) when is_atom(Strategy) ->
    case Strategy of
        fill -> asobi_matchmaker_fill;
        skill_based -> asobi_matchmaker_skill;
        Mod -> Mod
    end;
resolve_strategy(_) ->
    asobi_matchmaker_fill.

-spec resolve_game_module(binary()) -> {ok, module(), map()} | {error, not_found}.
resolve_game_module(Mode) ->
    case mode_config(Mode) of
        #{type := world, module := {lua, Script}} ->
            {ok, asobi_lua_world, #{lua_script => Script}};
        #{module := {lua, Script}} ->
            {ok, asobi_lua_match, #{lua_script => Script}};
        #{module := Mod} when is_atom(Mod) ->
            {ok, Mod, #{}};
        _ ->
            {error, not_found}
    end.

-spec spawn_matches([[map()]]) -> [[map()]].
spawn_matches(Groups) ->
    spawn_matches(Groups, []).

spawn_matches([], Failed) ->
    Failed;
spawn_matches([Group | Rest], Failed) ->
    PlayerIds = [maps:get(player_id, T) || T <- Group],
    [First | _] = Group,
    Mode = maps:get(mode, First),
    ModeConfig = mode_config(Mode),
    case maps:get(type, ModeConfig, match) of
        world ->
            spawn_world(Mode, ModeConfig, PlayerIds, Group, Rest, Failed);
        match ->
            spawn_match(Mode, ModeConfig, PlayerIds, Group, Rest, Failed)
    end.

spawn_match(Mode, ModeConfig, PlayerIds, Group, Rest, Failed) ->
    MatchSize = maps:get(match_size, ModeConfig, length(PlayerIds)),
    MaxPlayers = maps:get(max_players, ModeConfig, MatchSize),
    case resolve_game_module(Mode) of
        {ok, GameMod, ExtraConfig} ->
            Config = #{
                mode => Mode,
                game_module => GameMod,
                game_config => ExtraConfig,
                min_players => MatchSize,
                max_players => MaxPlayers
            },
            case asobi_match_sup:start_match(Config) of
                {ok, MatchPid} when is_pid(MatchPid) ->
                    Now = erlang:system_time(millisecond),
                    AvgWait =
                        lists:sum([Now - maps:get(submitted_at, T) || T <- Group]) div
                            max(1, length(Group)),
                    asobi_telemetry:matchmaker_formed(Mode, length(PlayerIds), AvgWait),
                    MatchInfo = asobi_match_server:get_info(MatchPid),
                    lists:foreach(
                        fun(PlayerId) when is_binary(PlayerId) ->
                            _ = asobi_match_server:join(MatchPid, PlayerId),
                            asobi_presence:send(PlayerId, {match_joined, MatchPid}),
                            asobi_presence:send(
                                PlayerId,
                                {match_event, matched, #{
                                    match_id => maps:get(match_id, MatchInfo, undefined),
                                    players => PlayerIds
                                }}
                            )
                        end,
                        PlayerIds
                    ),
                    spawn_matches(Rest, Failed);
                {error, Reason} ->
                    logger:error(#{
                        msg => ~"match spawn failed, re-queuing players",
                        mode => Mode,
                        players => PlayerIds,
                        error => Reason
                    }),
                    spawn_matches(Rest, [Group | Failed])
            end;
        {error, _} ->
            notify_no_game_module(Mode, PlayerIds),
            spawn_matches(Rest, Failed)
    end.

spawn_world(Mode, ModeConfig, PlayerIds, Group, Rest, Failed) ->
    MaxPlayers = maps:get(max_players, ModeConfig, 500),
    case resolve_game_module(Mode) of
        {ok, GameMod, ExtraConfig} ->
            Config = #{
                mode => Mode,
                game_module => GameMod,
                game_config => ExtraConfig,
                max_players => MaxPlayers,
                grid_size => maps:get(grid_size, ModeConfig, 10),
                zone_size => maps:get(zone_size, ModeConfig, 200),
                tick_rate => maps:get(tick_rate, ModeConfig, 50),
                view_radius => maps:get(view_radius, ModeConfig, 1)
            },
            %% Spawn world asynchronously to avoid blocking the matchmaker
            SpawnGroup = Group,
            SpawnPlayerIds = PlayerIds,
            spawn(fun() ->
                try
                    case asobi_world_instance_sup:start_world(Config) of
                        {ok, InstancePid} when is_pid(InstancePid) ->
                            Now = erlang:system_time(millisecond),
                            AvgWait =
                                lists:sum([Now - maps:get(submitted_at, T) || T <- SpawnGroup]) div
                                    max(1, length(SpawnGroup)),
                            asobi_telemetry:matchmaker_formed(Mode, length(SpawnPlayerIds), AvgWait),
                            WorldPid = asobi_world_instance:get_child(InstancePid, asobi_world_server),
                            logger:notice(#{msg => ~"world spawn complete", world_pid => WorldPid, instance_pid => InstancePid}),
                            WorldInfo = asobi_world_server:get_info(WorldPid),
                            WorldId = maps:get(world_id, WorldInfo, undefined),
                            lists:foreach(
                                fun(PlayerId) when is_binary(PlayerId) ->
                                    JoinResult = asobi_world_server:join(WorldPid, PlayerId),
                                    logger:notice(#{msg => ~"player joined world", player_id => PlayerId, result => JoinResult}),
                                    asobi_presence:send(
                                        PlayerId,
                                        {match_event, matched, #{
                                            match_id => WorldId,
                                            mode => Mode,
                                            player_ids => SpawnPlayerIds
                                        }}
                                    )
                                end,
                                SpawnPlayerIds
                            );
                        {error, Reason} ->
                            logger:error(#{
                                msg => ~"world spawn failed",
                                mode => Mode,
                                players => SpawnPlayerIds,
                                error => Reason
                            })
                    end
                catch
                    Class:Reason2:Stack ->
                        logger:error(#{
                            msg => ~"world spawn crashed",
                            mode => Mode,
                            players => SpawnPlayerIds,
                            class => Class,
                            error => Reason2,
                            stacktrace => Stack
                        })
                end
            end),
            spawn_matches(Rest, Failed);
        {error, _} ->
            notify_no_game_module(Mode, PlayerIds),
            spawn_matches(Rest, Failed)
    end.

notify_no_game_module(Mode, PlayerIds) ->
    logger:warning(#{msg => ~"no game module for mode", mode => Mode}),
    lists:foreach(
        fun(PlayerId) when is_binary(PlayerId) ->
            asobi_presence:send(
                PlayerId,
                {match_event, matchmaker_failed, #{reason => ~"no_game_module"}}
            )
        end,
        PlayerIds
    ).

-spec notify_expired([map()]) -> ok.
notify_expired([]) ->
    ok;
notify_expired([#{player_id := PlayerId, id := TicketId} | Rest]) ->
    asobi_presence:send(PlayerId, {match_event, matchmaker_expired, #{ticket_id => TicketId}}),
    notify_expired(Rest).

-spec generate_id() -> binary().
generate_id() ->
    asobi_id:generate().

-spec ensure_map(term()) -> #{term() => term()}.
ensure_map(M) when is_map(M) -> M;
ensure_map(_) -> #{}.
