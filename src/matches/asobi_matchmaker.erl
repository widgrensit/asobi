-module(asobi_matchmaker).
-moduledoc """
The matchmaking queue. Players submit tickets with a mode and property
constraints (`add/2`); a pluggable strategy groups compatible tickets,
spawns a match, and pushes `match.matched` to each player. A single
`gen_server` owns the queue and ticks it on an interval.
""".
-behaviour(gen_server).

-export([start_link/0, add/2, remove/2, get_ticket/1, get_ticket/2, get_queue_stats/0]).
-export([known_mode/1, snapshot/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).
-ifdef(TEST).
-export([next_spawn_attempt/1, join_matched_players/3, tally/1, render/3, notify_expired/1]).
-export([join_if_present/3, discard_unoccupied/4]).
-endif.

-export_type([snapshot/0, mode_queue/0]).

-define(DEFAULT_TICK, 1000).
-define(DEFAULT_MAX_QUEUE, 10000).
-define(MAX_SPAWN_ATTEMPTS, 3).
-define(SNAPSHOT_TABLE, asobi_matchmaker_snapshot).

-type snapshot() :: #{
    sampled_at := integer() | null,
    age_ms := non_neg_integer() | null,
    waiting := non_neg_integer(),
    modes := [mode_queue()]
}.

-type mode_queue() :: #{
    mode := binary(),
    waiting := pos_integer(),
    oldest_wait_ms := non_neg_integer(),
    average_wait_ms := non_neg_integer()
}.

-type mode_tally() :: #{
    waiting := pos_integer(), oldest := integer(), submitted_sum := integer()
}.

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
%%
%% `already_queued' says whether this reply carries a ticket the caller already
%% held rather than a new one. `add' is idempotent per (player, mode) precisely
%% so a reconnect resubmit is safe (asobi#230); without this flag a client
%% resuming a backgrounded socket cannot tell "my resubmit was absorbed and my
%% original wait still stands" from "freshly queued", so it restarts its wait
%% UI. Named for what the client observes, not for the server mechanism - the
%% telemetry event keeps the mechanism name. Additive field: clients that ignore
%% it behave exactly as before.
-spec queue_meta(binary(), boolean()) -> map().
queue_meta(Mode, AlreadyQueued) ->
    Meta = #{already_queued => AlreadyQueued},
    case maps:get(match_size, asobi_game_modes:mode_config(Mode), undefined) of
        N when is_integer(N) -> Meta#{players_needed => N};
        _ -> Meta#{players_needed => null}
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

-doc """
The queue as an operator sees it: how many tickets are waiting, split by
mode, and how long they have been waiting.

Read from an ETS table this process publishes to on each tick, **not** by
calling this process. The matchmaker is a single gen_server that runs every
strategy and spawns every match inside its own tick, so a `gen_server:call`
from an HTTP handler queues behind that work: the read would be slowest
exactly when the queue is deepest and an operator most needs to look at it.
The other direction is worse - HTTP concurrency is unbounded, so a console
polling once a second, times however many operators, lands in the mailbox of
the hottest process in the system. A read plane must not be able to slow the
game path down, at any request rate.

Publishing costs one `ets:insert/2` per tick over a fold the tick has already
paid for. A reader pays one `ets:lookup/2` and sends no message at all.

Waits are derived at read time from the sampled `submitted_at` values, so
they keep ageing correctly between ticks; only the *counts* are as old as
`age_ms`, at most one `tick_interval` (1s by default). Before the first tick,
or with no matchmaker running, the result is an empty queue rather than an
error - `null` timestamps say which.
""".
-spec snapshot() -> snapshot().
snapshot() ->
    Now = erlang:system_time(millisecond),
    try ets:lookup(?SNAPSHOT_TABLE, queue) of
        [{queue, SampledAt, Modes}] when is_integer(SampledAt), is_map(Modes) ->
            render(SampledAt, narrow_tallies(Modes), Now);
        _ ->
            empty_snapshot()
    catch
        error:badarg -> empty_snapshot()
    end.

-spec empty_snapshot() -> snapshot().
empty_snapshot() ->
    #{sampled_at => null, age_ms => null, waiting => 0, modes => []}.

-spec render(integer(), #{binary() => mode_tally()}, integer()) -> snapshot().
render(SampledAt, Modes, Now) ->
    Rows = [mode_queue(Mode, Tally, Now) || {Mode, Tally} <- maps:to_list(Modes)],
    #{
        sampled_at => SampledAt,
        age_ms => waited(SampledAt, Now),
        waiting => lists:sum([Waiting || #{waiting := Waiting} <- Rows]),
        modes => Rows
    }.

-spec mode_queue(binary(), mode_tally(), integer()) -> mode_queue().
mode_queue(Mode, #{waiting := Waiting, oldest := Oldest, submitted_sum := Sum}, Now) ->
    #{
        mode => Mode,
        waiting => Waiting,
        oldest_wait_ms => waited(Oldest, Now),
        average_wait_ms => waited(Sum div Waiting, Now)
    }.

%% Clamped because system_time can step backwards; a negative wait would be
%% read as a clock bug in the console rather than on the node.
-spec waited(integer(), integer()) -> non_neg_integer().
waited(At, Now) when Now > At -> Now - At;
waited(_At, _Now) -> 0.

%% `lists:foldl/3` erases the accumulator type, so the ticket map comes back
%% `term()` and every later use of it is an untyped read. Explicit recursion
%% keeps it a map: see docs/eqwalizer-idioms.md.
-spec requeue_failed([map()], map()) -> map().
requeue_failed([], Tickets) ->
    Tickets;
requeue_failed([T | Rest], Tickets) ->
    requeue_failed(Rest, Tickets#{maps:get(id, T) => T}).

%% The queue snapshot comes back out of ETS as `term()`, and `render/3` wants
%% the tally shape. Narrow at the boundary rather than letting `dynamic()`
%% travel: an entry that is not a tally is dropped, because a malformed
%% snapshot row should cost one mode's numbers, not the whole console page.
-spec narrow_tallies(map()) -> #{binary() => mode_tally()}.
narrow_tallies(Modes) ->
    maps:fold(
        fun
            (Mode, #{waiting := W, oldest := O, submitted_sum := S}, Acc) when
                is_binary(Mode), is_integer(W), W > 0, is_integer(O), is_integer(S)
            ->
                Acc#{Mode => #{waiting => W, oldest => O, submitted_sum => S}};
            (_Mode, _Tally, Acc) ->
                Acc
        end,
        #{},
        Modes
    ).

-spec publish(map()) -> ok.
publish(Tickets) ->
    true = ets:insert(?SNAPSHOT_TABLE, {queue, erlang:system_time(millisecond), tally(Tickets)}),
    ok.

-spec tally(map()) -> #{binary() => mode_tally()}.
tally(Tickets) ->
    maps:fold(fun(_Id, Ticket, Acc) -> tally_ticket(Ticket, Acc) end, #{}, Tickets).

-spec tally_ticket(term(), #{binary() => mode_tally()}) -> #{binary() => mode_tally()}.
tally_ticket(#{mode := Mode, submitted_at := At}, Acc) when is_binary(Mode), is_integer(At) ->
    case Acc of
        #{Mode := #{waiting := Waiting, oldest := Oldest, submitted_sum := Sum}} ->
            Acc#{
                Mode => #{
                    waiting => Waiting + 1,
                    oldest => min(Oldest, At),
                    submitted_sum => Sum + At
                }
            };
        _ ->
            Acc#{Mode => #{waiting => 1, oldest => At, submitted_sum => At}}
    end;
tally_ticket(_Ticket, Acc) ->
    Acc.

-spec init([]) -> {ok, map()}.
init([]) ->
    ?SNAPSHOT_TABLE = ets:new(?SNAPSHOT_TABLE, [named_table, protected, {read_concurrency, true}]),
    ok = publish(#{}),
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
            asobi_telemetry:matchmaker_deduped(PlayerId, Mode),
            {reply, {ok, ExistingId, queue_meta(Mode, true)}, State};
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
            {reply, {ok, TicketId, queue_meta(Mode, false)}, State#{
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
    Remaining1 = requeue_failed(lists:flatten(FailedGroups), Remaining),
    erlang:send_after(Interval, self(), tick),
    ok = publish(Remaining1),
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
    %% asobi#481: min_players was hardcoded to MatchSize here, so the field
    %% asobi_match_server already reads and honours was reachable only by an
    %% Erlang caller of asobi_match_sup:start_match/1 - a mode declaring it got
    %% silence. Defaulting to MatchSize keeps every existing mode identical;
    %% declaring it higher spawns a match that genuinely waits for backfill and
    %% gives up at ?WAITING_TIMEOUT.
    MinPlayers = maps:get(min_players, ModeConfig, MatchSize),
    case asobi_game_modes:resolve_game_module(Mode) of
        {ok, GameMod, ExtraConfig} ->
            Config = #{
                mode => Mode,
                game_module => GameMod,
                game_config => ExtraConfig,
                min_players => MinPlayers,
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
                %% `match_joined` is sent by asobi_match_server itself, on the
                %% join it accepted. Sending it here as well announced a join
                %% this fan-out never checked the result of, so a player whose
                %% join was refused still ended up holding a match_pid.
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

-doc """
Seat a matched player in the world, but only while they still have a session.

`asobi_world_server:join/2` takes no session pid and resolves one through
`pg`. If the player disconnected between taking a ticket and the group being
formed, it seats them anyway with `session_pid => undefined` and no monitor -
and that player can then never leave:

- they get no interest subscriptions, so they see nothing;
- `find_player_by_pid/2` matches on `session_pid =:= Pid`, and `undefined` is
  never a pid, so no `DOWN` ever resolves to them;
- `handle_leave/2` is reachable only from an explicit leave or that `DOWN`, so
  `map_size(Players)` never reaches 0 and the `empty_grace` timer is never even
  scheduled.

The world then ticks forever around a player who is not there. This is the
world-side twin of widgrensit/asobi#280, and the same root cause: nothing
checked that the ticket's owner was still connected before forming.

Checked here rather than refused in `asobi_world_server:join/2`, because
around twenty tests and the Erlang embedding path join a session-less player
deliberately - `join/2` is the API for a host that is not driving a WS session.
(Not, as an earlier draft of this comment claimed, because asobi#277 blessed
the seat: #277 only stopped `monitor(process, undefined)` from crashing. It
avoided a crash; it did not sanction the state.)

A player who disconnects between this check and the join still lands in it.
The window is one message rather than the whole queue wait, and
`join_no_live_session` counts it - but the consequence is undiminished, because
one seated phantom keeps its world alive forever just as surely as a full group
of them. Closing that needs a per-player terminus in `asobi_world_server`.
""".
-spec join_if_present(pid(), binary(), binary()) -> ok | offline | {error, term()}.
join_if_present(WorldPid, PlayerId, Mode) ->
    case asobi_presence:get_status(PlayerId) of
        offline ->
            %% `[asobi, matchmaker, dropped]`, not `[asobi, error]`: this fires
            %% on the EXPECTED path. A player disconnecting while queued is
            %% routine on mobile, and putting it on the error surface would
            %% make the node's error rate track connection churn. The world
            %% server keeps `join_no_live_session` on `[asobi, error]` for the
            %% residual race, which genuinely is anomalous now that the screen
            %% exists - and the two rates answer different questions.
            asobi_telemetry:matchmaker_dropped(Mode, no_live_session),
            offline;
        online ->
            asobi_world_server:join(WorldPid, PlayerId)
    end.

%% Explicit recursion: `lists:foldl/3` erases the accumulator type, and the
%% count is what decides whether the world lives. See docs/eqwalizer-idioms.md.
-spec seat_group([term()], pid(), binary(), term(), [binary()], non_neg_integer()) ->
    non_neg_integer().
seat_group([], _WorldPid, _Mode, _WorldId, _Group, Seated) ->
    Seated;
seat_group([PlayerId | Rest], WorldPid, Mode, WorldId, Group, Seated) when is_binary(PlayerId) ->
    JoinResult = join_if_present(WorldPid, PlayerId, Mode),
    logger:notice(#{
        msg => ~"player joined world",
        player_id => PlayerId,
        result => JoinResult
    }),
    asobi_presence:send(
        PlayerId,
        {match_event, matched, #{match_id => WorldId, mode => Mode, player_ids => Group}}
    ),
    seat_group(Rest, WorldPid, Mode, WorldId, Group, seated(JoinResult, Seated));
seat_group([_ | Rest], WorldPid, Mode, WorldId, Group, Seated) ->
    seat_group(Rest, WorldPid, Mode, WorldId, Group, Seated).

-spec seated(term(), non_neg_integer()) -> non_neg_integer().
seated(ok, Seated) -> Seated + 1;
seated(_Other, Seated) -> Seated.

-doc """
Stop a world nobody was seated in.

The world is built BEFORE anyone joins, and `asobi_world_server` decides it is
empty in exactly one place - `handle_leave/2`, reachable only from an explicit
leave or a session `DOWN`. So a world whose roster was never populated never
arms `empty_grace` and never reaches `finished`: it ticks its whole zone grid
forever. Screening the departed players out of the join (`join_if_present/3`)
turns one unremovable seat into zero seats, which is the same terminal state.

Hence the count. If the whole group went offline while queued, the world has
no reason to exist and is torn down here, where the caller still holds the
instance pid.

**This does not cover the residual race**: a player who dies between the screen
and the join is still seated with no session and no monitor, and one seated
player is enough to keep the world alive forever. Closing that needs a terminus
in `asobi_world_server` for a roster that empties without a leave, which is a
change to world lifecycle for every caller and is not made here.
""".
-spec discard_unoccupied(non_neg_integer(), pid(), binary(), term()) -> ok.
discard_unoccupied(0, InstancePid, Mode, WorldId) ->
    logger:notice(#{
        msg => ~"world had no live players to seat; discarding it",
        mode => Mode,
        world_id => WorldId
    }),
    asobi_telemetry:matchmaker_failed(Mode, 0),
    _ = supervisor:terminate_child(asobi_world_instance_sup, InstancePid),
    ok;
discard_unoccupied(_Seated, _InstancePid, _Mode, _WorldId) ->
    ok.

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
                            Seated = seat_group(
                                SpawnPlayerIds, WorldPid, Mode, WorldId, SpawnPlayerIds, 0
                            ),
                            discard_unoccupied(Seated, InstancePid, Mode, WorldId);
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
    %% Only `cancelled' was ever reported here, so removed{reason=expired} read
    %% as zero and an operator's removal rate looked complete while omitting
    %% every timeout. Expiry against flat `formed' is the unambiguous form of
    %% "players waited the full max_wait and got nothing".
    asobi_telemetry:matchmaker_removed(PlayerId, expired),
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
