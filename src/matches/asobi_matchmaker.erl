-module(asobi_matchmaker).
-behaviour(gen_server).

-export([start_link/0, add/2, remove/2, get_ticket/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(DEFAULT_TICK, 1000).
-define(DEFAULT_MAX_WAIT, 60000).

-spec start_link() -> {ok, pid()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec add(binary(), map()) -> {ok, binary()}.
add(PlayerId, Params) ->
    gen_server:call(?MODULE, {add, PlayerId, Params}).

-spec remove(binary(), binary()) -> ok.
remove(PlayerId, TicketId) ->
    gen_server:cast(?MODULE, {remove, PlayerId, TicketId}).

-spec get_ticket(binary()) -> {ok, map()} | {error, not_found}.
get_ticket(TicketId) ->
    gen_server:call(?MODULE, {get_ticket, TicketId}).

-spec init([]) -> {ok, map()}.
init([]) ->
    Cfg = application:get_env(asobi, matchmaker, #{}),
    TickInterval = maps:get(tick_interval, Cfg, ?DEFAULT_TICK),
    erlang:send_after(TickInterval, self(), tick),
    {ok, #{
        tickets => #{},
        tick_interval => TickInterval,
        max_wait => maps:get(max_wait_seconds, Cfg, 60) * 1000
    }}.

-spec handle_call(term(), gen_server:from(), map()) -> {reply, term(), map()}.
handle_call({add, PlayerId, Params}, _From, #{tickets := Tickets} = State) ->
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
    case maps:find(TicketId, Tickets) of
        {ok, Ticket} -> {reply, {ok, Ticket}, State};
        error -> {reply, {error, not_found}, State}
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
    spawn_matches(Matched),
    notify_expired(Expired),
    erlang:send_after(Interval, self(), tick),
    {noreply, State#{tickets => Remaining}};
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
    Remaining = lists:foldl(
        fun(T, Acc) -> Acc#{maps:get(id, T) => T} end,
        #{},
        lists:flatten(Unmatched)
    ),
    {Matched, Expired, Remaining}.

-spec group_by_mode([map()]) -> #{binary() => [map()]}.
group_by_mode(Tickets) ->
    lists:foldl(
        fun(#{mode := Mode} = T, Acc) ->
            maps:update_with(Mode, fun(L) -> [T | L] end, [T], Acc)
        end,
        #{},
        Tickets
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
    Sorted = lists:sort(fun(A, B) -> skill(A) =< skill(B) end, Tickets),
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

-spec spawn_matches([[map()]]) -> ok.
spawn_matches([]) ->
    ok;
spawn_matches([Group | Rest]) ->
    PlayerIds = [maps:get(player_id, T) || T <- Group],
    Mode = maps:get(mode, hd(Group)),
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
                {ok, MatchPid} ->
                    MatchId = asobi_match_server:get_info(MatchPid),
                    lists:foreach(
                        fun(PlayerId) ->
                            asobi_match_server:join(MatchPid, PlayerId),
                            asobi_presence:send(
                                PlayerId,
                                {match_event, matched, #{
                                    match_id => maps:get(match_id, MatchId, undefined),
                                    players => PlayerIds
                                }}
                            )
                        end,
                        PlayerIds
                    );
                _ ->
                    ok
            end;
        {error, _} ->
            logger:warning(#{msg => ~"no game module for mode", mode => Mode}),
            ok
    end,
    spawn_matches(Rest).

-spec resolve_game_module(binary()) -> {ok, module()} | {error, not_found}.
resolve_game_module(Mode) ->
    Modes = application:get_env(asobi, game_modes, #{}),
    case maps:find(Mode, Modes) of
        {ok, Mod} -> {ok, Mod};
        error -> {error, not_found}
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
