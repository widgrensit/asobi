-module(asobi_matchmaker).
-moduledoc """
The matchmaking queue. Players submit tickets with a mode and property
constraints (`add/2`); a pluggable strategy groups compatible tickets,
spawns a match, and pushes `match.matched` to each player. A single
`gen_server` owns the queue and ticks it on an interval.
""".
-behaviour(gen_server).

-export([start_link/0, add/2, remove/2, get_ticket/1, get_ticket/2, get_queue_stats/0]).
-export([known_mode/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).
-ifdef(TEST).
-export([next_spawn_attempt/1, join_matched_players/3]).
-endif.

-define(DEFAULT_TICK, 1000).
-define(DEFAULT_MAX_QUEUE, 10000).
-define(MAX_SPAWN_ATTEMPTS, 3).

-spec start_link() -> gen_server:start_ret().
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec add(binary(), map()) -> {ok, binary(), map()} | {error, queue_full}.
add(PlayerId, Params) ->
    case gen_server:call(?MODULE, {add, PlayerId, Params}) of
        {ok, TicketId, Meta} when is_binary(TicketId), is_map(Meta) -> {ok, TicketId, Meta};
        {error, queue_full} -> {error, queue_full}
    end.

%% A mode must actually resolve to a game module - including the "default" a
%% single-mode game's loader registers - not merely be a key in `game_modes'.
%% A key with no resolvable module can never spawn a match either, so gating on
%% key presence alone would still let that class of mistake through. Rejecting
%% at the edge stops an attacker inflating the queue with arbitrary mode strings
%% that each slip past the per-(player, mode) ticket guard, and turns a
%% typo'd/omitted/half-configured mode into an immediate 400 instead of a
%% silent queue that only ever ends in `matchmaker_expired' after `max_wait'.
%% `lua_runtime_unavailable' (a Lua mode in a release with no scripting runtime)
%% is rejected here for the same reason: it can never spawn either.
-spec known_mode(term()) -> boolean().
known_mode(Mode) when is_binary(Mode), byte_size(Mode) =< 64 ->
    case asobi_game_modes:resolve_game_module(Mode) of
        {ok, _Module, _GameConfig} -> true;
        {error, _} -> false
    end;
known_mode(_) ->
    false.

%% Metadata sent back on a matchmaker.queued reply so the client can show
%% "waiting for N players" instead of silence. players_needed is the mode's
%% match_size (null if the mode declares none). players_waiting (a count of
%% others queued) is deliberately not exposed by default - it is a per-mode
%% opt-in, tracked in asobi#232's follow-up.
-spec queue_meta(binary()) -> map().
queue_meta(Mode) ->
    case maps:get(match_size, asobi_game_modes:mode_config(Mode), undefined) of
        N when is_integer(N) -> #{players_needed => N};
        _ -> #{players_needed => null}
    end.

-spec remove(binary(), binary()) -> ok | {error, not_found | not_owner}.
remove(PlayerId, TicketId) ->
    case gen_server:call(?MODULE, {remove, PlayerId, TicketId}) of
        ok -> ok;
        {error, not_found} -> {error, not_found};
        {error, not_owner} -> {error, not_owner}
    end.

%% Ticket lookup is owner-scoped. F-8: previously any authenticated
%% caller could read another player's mode/properties.
-spec get_ticket(binary(), binary()) ->
    {ok, map()} | {error, not_found | not_owner}.
get_ticket(PlayerId, TicketId) ->
    case gen_server:call(?MODULE, {get_ticket, PlayerId, TicketId}) of
        {ok, Ticket} when is_map(Ticket) -> {ok, Ticket};
        {error, not_found} -> {error, not_found};
        {error, not_owner} -> {error, not_owner}
    end.

%% Legacy single-arg lookup — kept for callers that don't have a
%% requester id (matchmaker tick path). Internal use only.
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
    MaxQueue =
        case maps:get(max_queue, Cfg, ?DEFAULT_MAX_QUEUE) of
            MQ when is_integer(MQ), MQ > 0 -> MQ;
            _ -> ?DEFAULT_MAX_QUEUE
        end,
    {ok, #{
        tickets => #{},
        tick_interval => TickInterval,
        max_wait => MaxWaitSec * 1000,
        max_queue => MaxQueue
    }}.

-spec handle_call(term(), gen_server:from(), map()) -> {reply, term(), map()}.
handle_call({add, PlayerId, Params}, _From, #{tickets := Tickets} = State) when
    is_binary(PlayerId), is_map(Params)
->
    Mode =
        case maps:get(mode, Params, ~"default") of
            M when is_binary(M) -> M;
            _ -> ~"default"
        end,
    MaxQueue = maps:get(max_queue, State, ?DEFAULT_MAX_QUEUE),
    %% One live ticket per (player, mode): a re-add while already queued returns
    %% the existing ticket rather than minting a second, so a double-tapped
    %% "find match" can't give one player two tickets that fill into a
    %% self-match (asobi#230). A full queue is rejected before minting.
    case find_player_ticket(PlayerId, Mode, Tickets) of
        {ok, ExistingId} ->
            {reply, {ok, ExistingId, queue_meta(Mode)}, State};
        error when map_size(Tickets) >= MaxQueue ->
            {reply, {error, queue_full}, State};
        error ->
            TicketId = generate_id(),
            Ticket = #{
                id => TicketId,
                player_id => PlayerId,
                mode => Mode,
                properties => maps:get(properties, Params, #{}),
                submitted_at => erlang:system_time(millisecond),
                status => pending,
                attempts => 0
            },
            asobi_telemetry:matchmaker_queued(PlayerId, Mode),
            {reply, {ok, TicketId, queue_meta(Mode)}, State#{
                tickets => Tickets#{TicketId => Ticket}
            }}
    end;
handle_call({get_ticket, PlayerId, TicketId}, _From, #{tickets := Tickets} = State) when
    is_binary(PlayerId), is_binary(TicketId)
->
    case Tickets of
        #{TicketId := #{player_id := PlayerId} = Ticket} ->
            {reply, {ok, Ticket}, State};
        #{TicketId := _Other} ->
            {reply, {error, not_owner}, State};
        _ ->
            {reply, {error, not_found}, State}
    end;
handle_call({get_ticket, TicketId}, _From, #{tickets := Tickets} = State) ->
    case Tickets of
        #{TicketId := Ticket} -> {reply, {ok, Ticket}, State};
        _ -> {reply, {error, not_found}, State}
    end;
handle_call({remove, PlayerId, TicketId}, _From, #{tickets := Tickets} = State) when
    is_binary(PlayerId), is_binary(TicketId)
->
    case Tickets of
        #{TicketId := #{player_id := PlayerId}} ->
            asobi_telemetry:matchmaker_removed(PlayerId, cancelled),
            {reply, ok, State#{tickets => maps:remove(TicketId, Tickets)}};
        #{TicketId := _Other} ->
            {reply, {error, not_owner}, State};
        _ ->
            {reply, {error, not_found}, State}
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
            ModeConfig = asobi_game_modes:mode_config(Mode),
            Strategy = resolve_strategy(ModeConfig),
            {M, U} = Strategy:match(ModeTickets, ModeConfig),
            %% Defence in depth for any strategy, including user-supplied ones:
            %% never spawn a match that lists the same player twice. A group
            %% that repeats a player is dropped back to unmatched rather than
            %% forming a degenerate (self-)match. The add-time guard means this
            %% never fires for the built-in strategies.
            {Valid, Requeue} = reject_duplicate_players(M),
            {Valid ++ AllMatched, [U, Requeue | AllUnmatched]}
        end,
        {[], []},
        ByMode
    ).

%% Keep groups whose players are all distinct; drop any group that repeats a
%% player back to the queue rather than spawning a degenerate (self-)match.
-spec reject_duplicate_players([[map()]]) -> {[[map()]], [map()]}.
reject_duplicate_players(Groups) ->
    reject_duplicate_players(Groups, [], []).

reject_duplicate_players([], Valid, Requeue) ->
    {Valid, Requeue};
reject_duplicate_players([Group | Rest], Valid, Requeue) ->
    Ids = [maps:get(player_id, T) || T <- Group],
    case length(lists:usort(Ids)) =:= length(Ids) of
        true ->
            reject_duplicate_players(Rest, [Group | Valid], Requeue);
        false ->
            logger:error(#{
                msg => ~"matchmaker group repeated a player; dropped to re-queue",
                players => Ids
            }),
            %% Re-queue the whole group. process_tickets keys Remaining by ticket
            %% id, so a repeated ticket collapses there and none is stranded.
            reject_duplicate_players(Rest, Valid, Group ++ Requeue)
    end.

%% This player's live ticket for a mode, if any (backs the add idempotency guard).
-spec find_player_ticket(binary(), binary(), map()) -> {ok, binary()} | error.
find_player_ticket(PlayerId, Mode, Tickets) ->
    Pred = fun({_Id, #{player_id := P, mode := M}}) ->
        P =:= PlayerId andalso M =:= Mode
    end,
    case lists:search(Pred, maps:to_list(Tickets)) of
        {value, {Id, _Ticket}} -> {ok, Id};
        false -> error
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

-spec spawn_matches([[map()]]) -> [[map()]].
spawn_matches(Groups) ->
    spawn_matches(Groups, []).

spawn_matches([], Failed) ->
    Failed;
spawn_matches([Group | Rest], Failed) ->
    PlayerIds = [maps:get(player_id, T) || T <- Group],
    [First | _] = Group,
    Mode = maps:get(mode, First),
    ModeConfig = asobi_game_modes:mode_config(Mode),
    case maps:get(type, ModeConfig, match) of
        world ->
            spawn_world(Mode, ModeConfig, PlayerIds, Group, Rest, Failed);
        match ->
            spawn_match(Mode, ModeConfig, PlayerIds, Group, Rest, Failed)
    end.

spawn_match(Mode, ModeConfig, PlayerIds, Group, Rest, Failed) ->
    MatchSize = maps:get(match_size, ModeConfig, length(PlayerIds)),
    MaxPlayers = maps:get(max_players, ModeConfig, MatchSize),
    case asobi_game_modes:resolve_game_module(Mode) of
        {ok, GameMod, ExtraConfig} ->
            Config = #{
                mode => Mode,
                game_module => GameMod,
                game_config => ExtraConfig,
                min_players => MatchSize,
                max_players => MaxPlayers,
                listed => maps:get(listed, ModeConfig, false)
            },
            case asobi_match_sup:start_match(Config) of
                {ok, MatchPid} when is_pid(MatchPid) ->
                    Now = erlang:system_time(millisecond),
                    AvgWait =
                        lists:sum([Now - maps:get(submitted_at, T) || T <- Group]) div
                            pos_len(Group),
                    asobi_telemetry:matchmaker_formed(Mode, length(PlayerIds), AvgWait),
                    spawn(fun() -> join_matched_players(MatchPid, Mode, PlayerIds) end),
                    spawn_matches(Rest, Failed);
                {error, Reason} ->
                    logger:error(#{
                        msg => ~"match spawn failed",
                        mode => Mode,
                        players => PlayerIds,
                        error => Reason
                    }),
                    handle_spawn_failure(Group, Mode, PlayerIds, Rest, Failed)
            end;
        {error, Reason} ->
            notify_no_game_module(Mode, Reason, PlayerIds),
            spawn_matches(Rest, Failed)
    end.

%% The join fan-out runs detached and exception-isolated (asobi#291). A match
%% server that exits mid-loop - e.g. `{shutdown, empty}' when a joining player's
%% session is already gone - would otherwise propagate its exit through the
%% gen_statem call into the matchmaker gen_server, restarting it and dropping
%% every ticket queued in every mode.
-spec join_matched_players(pid(), binary(), [binary()]) -> ok.
join_matched_players(MatchPid, Mode, PlayerIds) ->
    try
        MatchInfo = asobi_match_server:get_info(MatchPid),
        MatchId = maps:get(match_id, MatchInfo, undefined),
        lists:foreach(
            fun(PlayerId) when is_binary(PlayerId) ->
                _ = asobi_match_server:join(MatchPid, PlayerId),
                asobi_presence:send(PlayerId, {match_joined, MatchPid}),
                asobi_presence:send(
                    PlayerId,
                    {match_event, matched, #{match_id => MatchId, players => PlayerIds}}
                )
            end,
            PlayerIds
        )
    catch
        Class:Reason:Stack ->
            logger:error(#{
                msg => ~"match join fan-out crashed",
                mode => Mode,
                players => PlayerIds,
                class => Class,
                error => Reason,
                stacktrace => Stack
            }),
            asobi_telemetry:matchmaker_failed(Mode, length(PlayerIds)),
            notify_matchmaker_failed(PlayerIds, ~"match_start_failed")
    end.

%% Unlike spawn_match, world spawn is detached (spawn/1) to avoid blocking the
%% matchmaker, so there is no clean handle to re-queue the group on failure.
%% Worlds therefore fail fast: on the first spawn error/crash the players are
%% notified match_start_failed once, with no bounded retry. Fail-fast is the safe
%% direction (players told immediately, never left queued).
spawn_world(Mode, ModeConfig, PlayerIds, Group, Rest, Failed) ->
    MaxPlayers = maps:get(max_players, ModeConfig, 500),
    case asobi_game_modes:resolve_game_module(Mode) of
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
                                    pos_len(SpawnGroup),
                            asobi_telemetry:matchmaker_formed(
                                Mode, length(SpawnPlayerIds), AvgWait
                            ),
                            WorldPid =
                                case
                                    asobi_world_instance:get_child(
                                        InstancePid, asobi_world_server
                                    )
                                of
                                    WP when is_pid(WP) -> WP
                                end,
                            logger:notice(#{
                                msg => ~"world spawn complete",
                                world_pid => WorldPid,
                                instance_pid => InstancePid
                            }),
                            WorldInfo = asobi_world_server:get_info(WorldPid),
                            WorldId = maps:get(world_id, WorldInfo, undefined),
                            lists:foreach(
                                fun(PlayerId) when is_binary(PlayerId) ->
                                    JoinResult = asobi_world_server:join(WorldPid, PlayerId),
                                    logger:notice(#{
                                        msg => ~"player joined world",
                                        player_id => PlayerId,
                                        result => JoinResult
                                    }),
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
                            }),
                            asobi_telemetry:matchmaker_failed(Mode, length(SpawnPlayerIds)),
                            notify_matchmaker_failed(SpawnPlayerIds, ~"match_start_failed")
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
                        }),
                        asobi_telemetry:matchmaker_failed(Mode, length(SpawnPlayerIds)),
                        notify_matchmaker_failed(SpawnPlayerIds, ~"match_start_failed")
                end
            end),
            spawn_matches(Rest, Failed);
        {error, Reason} ->
            notify_no_game_module(Mode, Reason, PlayerIds),
            spawn_matches(Rest, Failed)
    end.

%% The player-facing reason stays coarse and stable; the resolver's own reason
%% (`not_found' vs `lua_runtime_unavailable', i.e. a Lua mode with no scripting
%% runtime in the release) only goes to the log, where the operator needs it.
notify_no_game_module(Mode, Reason, PlayerIds) ->
    logger:warning(#{msg => ~"no game module for mode", mode => Mode, reason => Reason}),
    notify_matchmaker_failed(PlayerIds, ~"no_game_module").

%% A match failed to spawn (e.g. the game's Lua init crashed). Re-queue the group
%% for a bounded number of attempts; once exhausted, tell the players it failed
%% rather than leaving them queued forever (asobi#232 audit). The reason is
%% coarse and stable - never the raw crash - so no game internals leak.
handle_spawn_failure(Group, Mode, PlayerIds, Rest, Failed) ->
    case next_spawn_attempt(Group) of
        give_up ->
            asobi_telemetry:matchmaker_failed(Mode, length(PlayerIds)),
            notify_matchmaker_failed(PlayerIds, ~"match_start_failed"),
            spawn_matches(Rest, Failed);
        {retry, Attempt} ->
            Group1 = [T#{attempts => Attempt} || T <- Group],
            spawn_matches(Rest, [Group1 | Failed])
    end.

%% Decide whether a failed group gets another spawn attempt (bumping its count)
%% or is given up on. Exported for test - the off-by-one at the give-up boundary
%% is the load-bearing bit.
-spec next_spawn_attempt([map()]) -> {retry, pos_integer()} | give_up.
next_spawn_attempt(Group) ->
    Attempt = 1 + max_attempts(Group, 0),
    case Attempt >= ?MAX_SPAWN_ATTEMPTS of
        true -> give_up;
        false -> {retry, Attempt}
    end.

-spec max_attempts([map()], non_neg_integer()) -> non_neg_integer().
max_attempts([], Acc) ->
    Acc;
max_attempts([T | Rest], Acc) ->
    A = ticket_attempts(T),
    Next =
        case A > Acc of
            true -> A;
            false -> Acc
        end,
    max_attempts(Rest, Next).

-spec ticket_attempts(map()) -> non_neg_integer().
ticket_attempts(T) ->
    case maps:get(attempts, T, 0) of
        N when is_integer(N), N >= 0 -> N;
        _ -> 0
    end.

-spec notify_matchmaker_failed([binary()], binary()) -> ok.
notify_matchmaker_failed(PlayerIds, Reason) ->
    lists:foreach(
        fun(PlayerId) when is_binary(PlayerId) ->
            asobi_presence:send(
                PlayerId,
                {match_event, matchmaker_failed, #{reason => Reason}}
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

-spec pos_len([term(), ...]) -> pos_integer().
pos_len([_ | _] = L) -> length(L).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

%% The reject seam is unreachable through the public API once the add-time guard
%% exists, so exercise it directly (it defends against user-supplied strategies).
reject_duplicate_players_test_() ->
    T = fun(P) -> #{player_id => P, mode => ~"m"} end,
    [
        %% all-distinct group is kept, nothing re-queued
        ?_assertEqual(
            {[[T(~"a"), T(~"b")]], []},
            reject_duplicate_players([[T(~"a"), T(~"b")]])
        ),
        %% a repeated player drops the group and re-queues the WHOLE group (the
        %% duplicate collapses on ticket id in process_tickets - nothing stranded)
        ?_assertEqual(
            {[], [T(~"a"), T(~"a")]},
            reject_duplicate_players([[T(~"a"), T(~"a")]])
        ),
        %% mixed: valid group kept, offending group re-queued
        ?_assertEqual(
            {[[T(~"a"), T(~"b")]], [T(~"c"), T(~"c")]},
            reject_duplicate_players([[T(~"a"), T(~"b")], [T(~"c"), T(~"c")]])
        )
    ].

known_mode_test_() ->
    {setup,
        fun() ->
            Prev = application:get_env(asobi, game_modes),
            application:set_env(asobi, game_modes, #{
                ~"arena" => #{module => some_mod}, ~"halfconfigured" => #{}
            }),
            Prev
        end,
        fun
            ({ok, V}) -> application:set_env(asobi, game_modes, V);
            (undefined) -> application:unset_env(asobi, game_modes)
        end, [
            %% A multi-mode manifest that never maps "default" (asobi#243 incident:
            %% a malformed client call silently fell back to "default", which was
            %% unconditionally accepted here, then failed later with
            %% no_game_module instead of an immediate 400).
            ?_assertNot(known_mode(~"default")),
            ?_assert(known_mode(~"arena")),
            %% A key with no resolvable `module' can never spawn a match either -
            %% key presence alone must not be enough (found in security review).
            ?_assertNot(known_mode(~"halfconfigured")),
            ?_assertNot(known_mode(~"nope")),
            ?_assertNot(known_mode(12345)),
            ?_assertNot(known_mode(<<0, 255>>)),
            %% Reject oversized mode strings before the map lookup (security
            %% review): a longer value matches no registered mode anyway, so
            %% there's no reason to pay for one, mirroring the 64-byte cap
            %% already enforced on `mode` at the world edge.
            ?_assertNot(known_mode(binary:copy(~"a", 65)))
        ]}.

%% A mapped "default" (what asobi_lua_config:load_single_mode/2 registers for a
%% single-mode game) is accepted like any other mode - known_mode/1 no longer
%% special-cases the string itself. The cross-repo half of this contract (that
%% load_single_mode/2 actually produces a "default" key) is asobi_lua's to test.
known_mode_single_mode_default_test_() ->
    {setup,
        fun() ->
            Prev = application:get_env(asobi, game_modes),
            application:set_env(asobi, game_modes, #{~"default" => #{module => some_mod}}),
            Prev
        end,
        fun
            ({ok, V}) -> application:set_env(asobi, game_modes, V);
            (undefined) -> application:unset_env(asobi, game_modes)
        end, [
            ?_assert(known_mode(~"default"))
        ]}.

%% A mode declaring a Lua script in a release with no scripting runtime resolves
%% to {error, lua_runtime_unavailable}: it can never spawn, so the edge rejects
%% it exactly like a half-configured mode. Once a provider is registered the
%% same mode is accepted.
known_mode_lua_runtime_test_() ->
    {setup,
        fun() ->
            Prev = application:get_env(asobi, game_modes),
            application:set_env(asobi, game_modes, #{
                ~"scripted" => #{module => {lua, "game/match.lua"}}
            }),
            ok = asobi_game_modes:unregister_game_mode(lua_match),
            Prev
        end,
        fun(Prev) ->
            ok = asobi_game_modes:unregister_game_mode(lua_match),
            case Prev of
                {ok, V} -> application:set_env(asobi, game_modes, V);
                undefined -> application:unset_env(asobi, game_modes)
            end
        end,
        [
            ?_assertNot(known_mode(~"scripted")),
            ?_test(begin
                ok = asobi_game_modes:register_game_mode(lua_match, fake_lua_match),
                ?assert(known_mode(~"scripted"))
            end)
        ]}.

-endif.
