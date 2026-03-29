-module(asobi_leaderboard_server).
-behaviour(gen_server).

-export([start_link/1, submit/3, top/2, rank/2, around/3]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-spec start_link(binary()) -> {ok, pid()}.
start_link(BoardId) ->
    gen_server:start_link({global, {?MODULE, BoardId}}, ?MODULE, BoardId, []).

-spec submit(binary(), binary(), integer()) -> ok.
submit(BoardId, PlayerId, Score) ->
    gen_server:cast({global, {?MODULE, BoardId}}, {submit, PlayerId, Score}).

-spec top(binary(), pos_integer()) -> [{binary(), integer(), pos_integer()}].
top(BoardId, N) ->
    gen_server:call({global, {?MODULE, BoardId}}, {top, N}).

-spec rank(binary(), binary()) -> {ok, pos_integer()} | {error, not_found}.
rank(BoardId, PlayerId) ->
    gen_server:call({global, {?MODULE, BoardId}}, {rank, PlayerId}).

-spec around(binary(), binary(), pos_integer()) -> [{binary(), integer(), pos_integer()}].
around(BoardId, PlayerId, N) ->
    gen_server:call({global, {?MODULE, BoardId}}, {around, PlayerId, N}).

-spec init(binary()) -> {ok, map()}.
init(BoardId) ->
    Table = ets:new(leaderboard, [ordered_set, private]),
    PlayerIndex = ets:new(player_index, [set, private]),
    erlang:send_after(30000, self(), persist),
    {ok, #{
        board_id => BoardId,
        table => Table,
        player_index => PlayerIndex,
        dirty => false
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
handle_cast({submit, PlayerId, Score}, #{table := Table, player_index := Idx} = State) ->
    case ets:lookup(Idx, PlayerId) of
        [{PlayerId, OldScore}] ->
            ets:delete(Table, {-OldScore, PlayerId});
        [] ->
            ok
    end,
    ets:insert(Table, {{-Score, PlayerId}, Score}),
    ets:insert(Idx, {PlayerId, Score}),
    {noreply, State#{dirty => true}};
handle_cast(_Msg, State) ->
    {noreply, State}.

-spec handle_info(term(), map()) -> {noreply, map()}.
handle_info(persist, #{dirty := true, board_id := BoardId, table := Table} = State) ->
    flush_to_db(BoardId, Table),
    erlang:send_after(30000, self(), persist),
    {noreply, State#{dirty => false}};
handle_info(persist, State) ->
    erlang:send_after(30000, self(), persist),
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

-spec terminate(term(), map()) -> ok.
terminate(_Reason, #{table := Table, player_index := Idx}) ->
    ets:delete(Table),
    ets:delete(Idx),
    ok.

%% --- Internal ---

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
    StartRank = count_before(Table, element(1, hd(Entries))) + 1,
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

flush_to_db(BoardId, Table) ->
    flush_entries(BoardId, Table, ets:first(Table)).

flush_entries(_BoardId, _Table, '$end_of_table') ->
    ok;
flush_entries(BoardId, Table, {_NegScore, PlayerId} = Key) ->
    [{_, Score}] = ets:lookup(Table, Key),
    Q = kura_query:where(
        kura_query:where(kura_query:from(asobi_leaderboard_entry), {leaderboard_id, BoardId}),
        {player_id, PlayerId}
    ),
    Result =
        case asobi_repo:all(Q) of
            {ok, [Existing]} ->
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
        end,
    case Result of
        {ok, _} ->
            ok;
        {error, FlushErr} ->
            logger:error(#{
                msg => ~"leaderboard flush failed",
                board_id => BoardId,
                player_id => PlayerId,
                error => FlushErr
            })
    end,
    flush_entries(BoardId, Table, ets:next(Table, Key)).
