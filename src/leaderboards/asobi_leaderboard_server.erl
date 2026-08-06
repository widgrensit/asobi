-module(asobi_leaderboard_server).
-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").

-export([start_link/1, submit/3, top/2, rank/2, around/3, live_boards/0, evict_player/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(PG_SCOPE, nova_scope).
-define(DEFAULT_MAX_BOARDS, 1000).

-spec start_link(binary()) -> gen_server:start_ret().
start_link(BoardId) ->
    gen_server:start_link(?MODULE, BoardId, []).

%% Submit is the only path that spawns a leaderboard process. Reads
%% return empty results when the board doesn't exist yet — that prevents
%% an attacker from filling the supervisor with thousands of boards just
%% by reading random ids.
-spec submit(binary(), binary(), integer()) -> ok | {error, capacity_reached}.
submit(BoardId, PlayerId, Score) ->
    case ensure_started(BoardId) of
        ok ->
            case whereis_board_optional(BoardId) of
                {ok, Pid} -> gen_server:cast(Pid, {submit, PlayerId, Score});
                not_found -> ok
            end;
        {error, _} = Err ->
            Err
    end.

-spec top(binary(), pos_integer()) -> [{binary(), number(), pos_integer()}].
top(BoardId, N) ->
    case whereis_board_optional(BoardId) of
        {ok, Pid} ->
            case gen_server:call(Pid, {top, N}) of
                Entries when is_list(Entries) -> validate_entries(Entries);
                _ -> []
            end;
        not_found ->
            []
    end.

-spec rank(binary(), binary()) -> {ok, pos_integer()} | {error, not_found}.
rank(BoardId, PlayerId) ->
    case whereis_board_optional(BoardId) of
        {ok, Pid} ->
            case gen_server:call(Pid, {rank, PlayerId}) of
                {ok, Pos} when is_integer(Pos) -> {ok, Pos};
                {error, not_found} -> {error, not_found}
            end;
        not_found ->
            {error, not_found}
    end.

-spec around(binary(), binary(), pos_integer()) -> [{binary(), number(), pos_integer()}].
around(BoardId, PlayerId, N) ->
    case whereis_board_optional(BoardId) of
        {ok, Pid} ->
            case gen_server:call(Pid, {around, PlayerId, N}) of
                Entries when is_list(Entries) -> validate_entries(Entries);
                _ -> []
            end;
        not_found ->
            []
    end.

%% The board ids that currently have a process, which is not the same set as
%% the boards that have scores: a board is live before its first flush and
%% stops being live when the node restarts. Enumerating the pg groups is the
%% only mapping from board id to process that costs no message - the
%% supervisor is simple_one_for_one, so its children carry no id.
-spec live_boards() -> [binary()].
live_boards() ->
    try pg:which_groups(?PG_SCOPE) of
        Groups -> [BoardId || {?MODULE, BoardId} <- Groups, is_binary(BoardId)]
    catch
        error:badarg -> []
    end.

%% Drop a player from every live board, for `asobi_player_erase:after_commit/1`.
%%
%% ETS is the read source of truth here and `hydrate/1` runs only at init, so
%% deleting the player's `leaderboard_entries` rows does not take them off a
%% board that is already running: `top/2`, `rank/2` and `around/3` would keep
%% serving an erased player's id until that process restarted, which for a
%% long-lived gen_server is never.
%%
%% It also clears them from `dirty`, which is the more damaging half. A pending
%% score for a deleted player is an INSERT that violates the
%% `leaderboard_entries` -> `players` foreign key, and `flush_players/4` puts a
%% failed write straight back into `dirty` - so the board would retry it every
%% 30 seconds, and log the failure, for the rest of its life.
%%
%% Cast, not call: this runs after the erase transaction has already committed,
%% so a board that is slow, wedged or dying must not be able to fail an erasure
%% that has happened. A board that starts later hydrates from a table the rows
%% are already gone from.
-spec evict_player(binary()) -> ok.
evict_player(PlayerId) ->
    lists:foreach(
        fun(BoardId) ->
            case whereis_board_optional(BoardId) of
                {ok, Pid} -> gen_server:cast(Pid, {evict, PlayerId});
                not_found -> ok
            end
        end,
        live_boards()
    ).

-spec validate_entries([term()]) -> [{binary(), number(), pos_integer()}].
validate_entries(Entries) ->
    [{P, S, R} || {P, S, R} <- Entries, is_binary(P), is_number(S), is_integer(R)].

-spec ensure_started(binary()) -> ok | {error, capacity_reached}.
ensure_started(BoardId) ->
    case pg:get_members(?PG_SCOPE, {?MODULE, BoardId}) of
        [] ->
            case at_capacity() of
                true ->
                    {error, capacity_reached};
                false ->
                    _ = asobi_leaderboard_sup:start_board(BoardId),
                    ok
            end;
        [_ | _] ->
            ok
    end.

-spec at_capacity() -> boolean().
at_capacity() ->
    Max = application:get_env(asobi, leaderboard_max_boards, ?DEFAULT_MAX_BOARDS),
    Counts = supervisor:count_children(asobi_leaderboard_sup),
    Active = proplists:get_value(active, Counts, 0),
    Active >= Max.

-spec whereis_board_optional(binary()) -> {ok, pid()} | not_found.
whereis_board_optional(BoardId) ->
    case pg:get_members(?PG_SCOPE, {?MODULE, BoardId}) of
        [Pid | _] -> {ok, Pid};
        [] -> not_found
    end.

%% ETS is the source of truth for reads, so a board that starts empty
%% serves an empty leaderboard even though the rows are still in
%% Postgres. Load them back before the process becomes reachable.
-spec init(binary()) -> {ok, map()}.
init(BoardId) ->
    pg:join(?PG_SCOPE, {?MODULE, BoardId}, self()),
    Table = ets:new(leaderboard, [ordered_set, private]),
    PlayerIndex = ets:new(player_index, [set, private]),
    hydrate(BoardId, Table, PlayerIndex),
    erlang:send_after(30000, self(), persist),
    {ok, #{
        board_id => BoardId,
        table => Table,
        player_index => PlayerIndex,
        dirty => #{}
    }}.

-spec handle_call(term(), gen_server:from(), map()) -> {reply, term(), map()}.
handle_call({top, N}, _From, #{table := Table} = State) ->
    Entries = take_top(Table, N),
    {reply, Entries, State};
handle_call({rank, PlayerId}, _From, #{table := Table, player_index := Idx} = State) ->
    case ets:lookup(Idx, PlayerId) of
        [{PlayerId, Score}] ->
            Key = {-Score, PlayerId},
            Pos = count_before(Table, Key) + 1,
            {reply, {ok, Pos}, State};
        [] ->
            {reply, {error, not_found}, State}
    end;
handle_call({around, PlayerId, N}, _From, #{table := Table, player_index := Idx} = State) ->
    case ets:lookup(Idx, PlayerId) of
        [{PlayerId, Score}] ->
            Key = {-Score, PlayerId},
            Entries = entries_around(Table, Key, N),
            {reply, Entries, State};
        [] ->
            {reply, [], State}
    end;
handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

-spec handle_cast(term(), map()) -> {noreply, map()}.
handle_cast(
    {submit, PlayerId, Score}, #{table := Table, player_index := Idx, dirty := Dirty} = State
) when
    is_number(Score)
->
    case ets:lookup(Idx, PlayerId) of
        [{PlayerId, OldScore}] ->
            ets:delete(Table, {-OldScore, PlayerId});
        [] ->
            ok
    end,
    ets:insert(Table, {{-Score, PlayerId}, Score}),
    ets:insert(Idx, {PlayerId, Score}),
    {noreply, State#{dirty => Dirty#{PlayerId => true}}};
handle_cast({evict, PlayerId}, #{table := Table, player_index := Idx, dirty := Dirty} = State) when
    is_binary(PlayerId)
->
    case ets:lookup(Idx, PlayerId) of
        [{PlayerId, Score}] ->
            ets:delete(Table, {-Score, PlayerId}),
            ets:delete(Idx, PlayerId);
        [] ->
            ok
    end,
    %% Unconditionally, even when the board never held them: `dirty` and the
    %% index can disagree, and a stale dirty key is the one that retries a
    %% foreign-key violation forever.
    {noreply, State#{dirty => maps:remove(PlayerId, Dirty)}};
handle_cast(_Msg, State) ->
    {noreply, State}.

-spec handle_info(term(), map()) -> {noreply, map()}.
handle_info(persist, #{dirty := Dirty} = State) when map_size(Dirty) > 0 ->
    Pending = flush_to_db(State),
    erlang:send_after(30000, self(), persist),
    {noreply, State#{dirty => Pending}};
handle_info(persist, State) ->
    erlang:send_after(30000, self(), persist),
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

%% Best effort: terminate runs inside the supervisor's 5s shutdown
%% budget, so a slow or unreachable database costs a brutal kill and the
%% pending scores, not a hung shutdown.
-spec terminate(term(), map()) -> ok.
terminate(_Reason, #{dirty := Dirty} = State) when map_size(Dirty) > 0 ->
    _ = flush_to_db(State),
    delete_tables(State);
terminate(_Reason, State) ->
    delete_tables(State).

%% --- Internal ---

delete_tables(#{table := Table, player_index := Idx}) ->
    ets:delete(Table),
    ets:delete(Idx),
    ok.

hydrate(BoardId, Table, Idx) ->
    Q = kura_query:where(kura_query:from(asobi_leaderboard_entry), {leaderboard_id, BoardId}),
    try asobi_repo:all(Q) of
        {ok, Rows} ->
            lists:foreach(fun(Row) -> hydrate_row(BoardId, Table, Idx, Row) end, Rows);
        %% A board that cannot read its rows still starts, on empty
        %% tables: flush_to_db/1 upserts per player and never deletes, so
        %% the persisted board degrades to partial reads until the next
        %% start rather than being erased.
        {error, Reason} ->
            log_hydrate_failure(BoardId, Reason)
    catch
        Class:CaughtReason ->
            log_hydrate_failure(BoardId, {Class, CaughtReason})
    end.

hydrate_row(_BoardId, Table, Idx, #{player_id := PlayerId, score := Score}) when
    is_binary(PlayerId), is_number(Score)
->
    ets:insert(Table, {{-Score, PlayerId}, Score}),
    ets:insert(Idx, {PlayerId, Score}),
    ok;
hydrate_row(BoardId, _Table, _Idx, Row) ->
    ?LOG_WARNING(#{
        msg => ~"leaderboard hydrate skipped unusable row",
        board_id => BoardId,
        row => Row
    }),
    ok.

log_hydrate_failure(BoardId, Reason) ->
    ?LOG_ERROR(#{
        msg => ~"leaderboard hydrate failed",
        board_id => BoardId,
        error => Reason
    }).

take_top(Table, N) ->
    take_top(Table, ets:first(Table), N, 1, []).

take_top(_Table, '$end_of_table', _N, _Rank, Acc) ->
    lists:reverse(Acc);
take_top(_Table, _Key, 0, _Rank, Acc) ->
    lists:reverse(Acc);
take_top(Table, {_NegScore, PlayerId} = Key, N, Rank, Acc) ->
    [{_, Score}] = ets:lookup(Table, Key),
    take_top(Table, ets:next(Table, Key), N - 1, Rank + 1, [{PlayerId, Score, Rank} | Acc]).

count_before(Table, Key) ->
    count_before(Table, ets:first(Table), Key, 0).

count_before(_Table, '$end_of_table', _Target, Count) ->
    Count;
count_before(_Table, Key, Key, Count) ->
    Count;
count_before(Table, Current, Target, Count) ->
    count_before(Table, ets:next(Table, Current), Target, Count + 1).

entries_around(Table, Key, N) ->
    Before = walk_back(Table, Key, N),
    [{_, Score}] = ets:lookup(Table, Key),
    {_, PlayerId} = Key,
    Self = [{PlayerId, Score, 0}],
    After = walk_forward(Table, Key, N),
    Entries = Before ++ Self ++ After,
    %% Rank the window from the queried player's own rank, walking back by
    %% however many entries precede them in it. Deriving the start rank from
    %% the first entry instead needs that entry's ETS key ({-Score, PlayerId}),
    %% not its player id - passing the id made count_before/2 walk to the end
    %% of the table and offset every rank by the size of the board (#334).
    StartRank = count_before(Table, Key) + 1 - length(Before),
    assign_ranks(Entries, StartRank, []).

walk_back(Table, Key, N) ->
    walk_back(Table, Key, N, []).

walk_back(_Table, _Key, 0, Acc) ->
    Acc;
walk_back(Table, Key, N, Acc) ->
    case ets:prev(Table, Key) of
        '$end_of_table' ->
            Acc;
        PrevKey ->
            {_, PlayerId} = PrevKey,
            [{_, Score}] = ets:lookup(Table, PrevKey),
            walk_back(Table, PrevKey, N - 1, [{PlayerId, Score, 0} | Acc])
    end.

walk_forward(_Table, _Key, 0) ->
    [];
walk_forward(Table, Key, N) ->
    case ets:next(Table, Key) of
        '$end_of_table' ->
            [];
        NextKey ->
            {_, PlayerId} = NextKey,
            [{_, Score}] = ets:lookup(Table, NextKey),
            [{PlayerId, Score, 0} | walk_forward(Table, NextKey, N - 1)]
    end.

assign_ranks([], _Rank, Acc) ->
    lists:reverse(Acc);
assign_ranks([{PlayerId, Score, _} | Rest], Rank, Acc) ->
    assign_ranks(Rest, Rank + 1, [{PlayerId, Score, Rank} | Acc]).

%% Returns the players whose write failed so they stay dirty and are
%% retried on the next tick instead of being silently dropped.
flush_to_db(#{board_id := BoardId, player_index := Idx, dirty := Dirty}) ->
    flush_players(BoardId, Idx, maps:keys(Dirty), #{}).

flush_players(_BoardId, _Idx, [], Pending) ->
    Pending;
flush_players(BoardId, Idx, [PlayerId | Rest], Pending) ->
    Next =
        case ets:lookup(Idx, PlayerId) of
            [{PlayerId, Score}] ->
                case upsert_entry(BoardId, PlayerId, Score) of
                    ok -> Pending;
                    {error, _} -> Pending#{PlayerId => true}
                end;
            [] ->
                Pending
        end,
    flush_players(BoardId, Idx, Rest, Next).

upsert_entry(BoardId, PlayerId, Score) ->
    try write_entry(BoardId, PlayerId, Score) of
        {ok, _} ->
            ok;
        {error, Reason} ->
            log_flush_failure(BoardId, PlayerId, Reason),
            {error, Reason}
    catch
        Class:CaughtReason ->
            log_flush_failure(BoardId, PlayerId, {Class, CaughtReason}),
            {error, CaughtReason}
    end.

write_entry(BoardId, PlayerId, Score) ->
    Q = kura_query:where(
        kura_query:where(kura_query:from(asobi_leaderboard_entry), {leaderboard_id, BoardId}),
        {player_id, PlayerId}
    ),
    case asobi_repo:all(Q) of
        {ok, [Existing | _]} ->
            CS = kura_changeset:cast(
                asobi_leaderboard_entry,
                Existing,
                #{score => Score},
                [score]
            ),
            asobi_repo:update(CS);
        {ok, []} ->
            CS = kura_changeset:cast(
                asobi_leaderboard_entry,
                #{},
                #{
                    leaderboard_id => BoardId,
                    player_id => PlayerId,
                    score => Score,
                    sub_score => 0
                },
                [leaderboard_id, player_id, score, sub_score]
            ),
            asobi_repo:insert(CS);
        {error, Reason} ->
            {error, Reason}
    end.

log_flush_failure(BoardId, PlayerId, Reason) ->
    ?LOG_ERROR(#{
        msg => ~"leaderboard flush failed",
        board_id => BoardId,
        player_id => PlayerId,
        error => Reason
    }).
