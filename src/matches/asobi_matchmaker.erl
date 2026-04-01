-module(asobi_matchmaker).
-behaviour(gen_server).

-export([start_link/0, add/2, remove/2, get_ticket/1]).
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
    {reply, {ok, TicketId}, State#{tickets => Tickets#{TicketId => Ticket}}};
handle_call({get_ticket, TicketId}, _From, #{tickets := Tickets} = State) ->
    case Tickets of
        #{TicketId := Ticket} -> {reply, {ok, Ticket}, State};
        _ -> {reply, {error, not_found}, State}
    end;
handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

-spec handle_cast(term(), map()) -> {noreply, map()}.
handle_cast({remove, _PlayerId, TicketId}, #{tickets := Tickets} = State) ->
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
    {Matched, Unmatched} = match_groups(ByMode),
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

-spec match_groups(#{binary() => [map()]}) -> {[[map()]], [[map()]]}.
match_groups(ByMode) ->
    maps:fold(
        fun(_Mode, ModeTickets, {AllMatched, AllUnmatched}) ->
            {M, U} = try_match(ModeTickets),
            {M ++ AllMatched, [U | AllUnmatched]}
        end,
        {[], []},
        ByMode
    ).

-spec try_match([map()]) -> {[[map()]], [map()]}.
try_match(Tickets) when length(Tickets) < 2 ->
    {[], Tickets};
try_match(Tickets) ->
    Sorted = [
        T
     || T <- lists:sort(fun(A, B) when is_map(A), is_map(B) -> skill(A) =< skill(B) end, Tickets),
        is_map(T)
    ],
    match_sorted(Sorted, [], []).

-spec match_sorted([map()], [[map()]], [map()]) -> {[[map()]], [map()]}.
match_sorted([], Matched, Unmatched) ->
    {Matched, Unmatched};
match_sorted([Last], Matched, Unmatched) ->
    {Matched, [Last | Unmatched]};
match_sorted([A, B | Rest], Matched, Unmatched) ->
    Window = skill_window(A),
    case abs(skill(A) - skill(B)) =< Window of
        true ->
            match_sorted(Rest, [[A, B] | Matched], Unmatched);
        false ->
            match_sorted([B | Rest], Matched, [A | Unmatched])
    end.

-spec skill(map()) -> integer().
skill(#{properties := #{skill := S}}) when is_integer(S) -> S;
skill(#{properties := #{~"skill" := S}}) when is_integer(S) -> S;
skill(_) -> 1000.

-spec skill_window(map()) -> integer().
skill_window(#{submitted_at := Sub}) ->
    WaitSec = (erlang:system_time(millisecond) - Sub) div 1000,
    %% Start with ±200, expand by 50 every 5 seconds
    200 + (WaitSec div 5) * 50.

-spec spawn_matches([[map()]]) -> [[map()]].
spawn_matches(Groups) ->
    spawn_matches(Groups, []).

spawn_matches([], Failed) ->
    Failed;
spawn_matches([Group | Rest], Failed) ->
    PlayerIds = [maps:get(player_id, T) || T <- Group],
    [First | _] = Group,
    Mode = maps:get(mode, First),
    case resolve_game_module(Mode) of
        {ok, GameMod} ->
            Config = #{
                mode => Mode,
                game_module => GameMod,
                game_config => #{},
                min_players => length(PlayerIds),
                max_players => length(PlayerIds)
            },
            case asobi_match_sup:start_match(Config) of
                {ok, MatchPid} when is_pid(MatchPid) ->
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
            logger:warning(#{msg => ~"no game module for mode", mode => Mode}),
            lists:foreach(
                fun(PlayerId) when is_binary(PlayerId) ->
                    asobi_presence:send(
                        PlayerId,
                        {match_event, matchmaker_failed, #{reason => ~"no_game_module"}}
                    )
                end,
                PlayerIds
            ),
            spawn_matches(Rest, Failed)
    end.

-spec resolve_game_module(binary()) -> {ok, module()} | {error, not_found}.
resolve_game_module(Mode) ->
    Modes = ensure_map(application:get_env(asobi, game_modes, #{})),
    case Modes of
        #{Mode := Mod} when is_atom(Mod) -> {ok, Mod};
        _ -> {error, not_found}
    end.

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
