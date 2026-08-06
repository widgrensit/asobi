-module(asobi_leaderboard_persistence_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("kura/include/kura.hrl").

%% asobi#328: ETS is the source of truth for leaderboard reads, so a
%% board that starts empty serves an empty board even though the rows
%% are still in Postgres. These drive the real gen_server with
%% asobi_repo mecked over an ETS stand-in for the table, so no DB is
%% needed.

-define(DB, leaderboard_persistence_fake_db).
-define(SCOPE, nova_scope).

setup() ->
    case whereis(?SCOPE) of
        undefined -> pg:start_link(?SCOPE);
        _ -> ok
    end,
    ets:new(?DB, [named_table, public, set]),
    ets:insert(?DB, {writes, 0}),
    meck:new(asobi_repo, [passthrough]),
    meck:expect(asobi_repo, all, fun fake_all/1),
    meck:expect(asobi_repo, insert, fun fake_insert/1),
    meck:expect(asobi_repo, update, fun fake_update/1),
    ok.

cleanup(_) ->
    meck:unload(asobi_repo),
    ets:delete(?DB),
    ok.

persistence_test_() ->
    {foreach, fun setup/0, fun cleanup/1, [
        {"a restarted board still serves the scores it persisted", fun restart_reloads_scores/0},
        {"stopping a board flushes scores the 30s timer never reached",
            fun shutdown_flushes_pending_scores/0},
        {"a flush writes only the players that changed", fun flush_writes_only_changed_players/0},
        {"a board whose hydrate fails still starts and deletes nothing",
            fun hydrate_failure_starts_empty/0},
        {"an erased player stops being served by a live board",
            fun evict_removes_a_player_from_a_live_board/0},
        {"an erased player's pending score cannot retry forever",
            fun evict_drops_the_pending_score/0}
    ]}.

restart_reloads_scores() ->
    BoardId = board_id(),
    Alice = asobi_id:generate(),
    Bob = asobi_id:generate(),
    Pid = start_board(BoardId),
    ok = asobi_leaderboard_server:submit(BoardId, Alice, 100),
    ok = asobi_leaderboard_server:submit(BoardId, Bob, 200),
    ?assertEqual(
        [{Bob, 200, 1}, {Alice, 100, 2}],
        asobi_leaderboard_server:top(BoardId, 10)
    ),
    stop_board(BoardId, Pid),

    Restarted = start_board(BoardId),
    ?assertEqual(
        [{Bob, 200, 1}, {Alice, 100, 2}],
        asobi_leaderboard_server:top(BoardId, 10)
    ),
    ?assertEqual({ok, 2}, asobi_leaderboard_server:rank(BoardId, Alice)),
    %% Ranks are left out here: around/3 numbers its window from a
    %% count_before/2 call that is passed a player id where an ETS key
    %% belongs, so every rank it reports is offset. Pre-existing and
    %% unrelated to hydration - asobi#334.
    Around = asobi_leaderboard_server:around(BoardId, Alice, 5),
    ?assertEqual([{Bob, 200}, {Alice, 100}], [{P, S} || {P, S, _} <- Around]),
    stop_board(BoardId, Restarted).

shutdown_flushes_pending_scores() ->
    BoardId = board_id(),
    Alice = asobi_id:generate(),
    Pid = start_board(BoardId),
    ok = asobi_leaderboard_server:submit(BoardId, Alice, 100),
    %% Nothing is persisted yet: the persist timer is 30s away.
    ?assertEqual(not_found, db_score(BoardId, Alice)),
    stop_board(BoardId, Pid),
    ?assertEqual(100, db_score(BoardId, Alice)).

flush_writes_only_changed_players() ->
    BoardId = board_id(),
    Alice = asobi_id:generate(),
    Bob = asobi_id:generate(),
    Carol = asobi_id:generate(),
    seed_row(BoardId, Alice, 100),
    seed_row(BoardId, Bob, 200),
    Pid = start_board(BoardId),
    ets:insert(?DB, {writes, 0}),
    ok = asobi_leaderboard_server:submit(BoardId, Carol, 150),
    stop_board(BoardId, Pid),
    ?assertEqual(1, writes()),
    ?assertEqual(150, db_score(BoardId, Carol)),
    ?assertEqual(100, db_score(BoardId, Alice)).

hydrate_failure_starts_empty() ->
    BoardId = board_id(),
    Alice = asobi_id:generate(),
    seed_row(BoardId, Alice, 100),
    meck:expect(asobi_repo, all, fun(_Q) -> {error, db_down} end),
    Pid = start_board(BoardId),
    ?assertEqual([], asobi_leaderboard_server:top(BoardId, 10)),
    stop_board(BoardId, Pid),
    %% Degraded reads, but the persisted row is untouched: the flush
    %% upserts per player and never deletes.
    meck:expect(asobi_repo, all, fun fake_all/1),
    ?assertEqual(100, db_score(BoardId, Alice)).

%% `asobi_player_erase` deletes the player's `leaderboard_entries` rows, but ETS
%% is what reads are served from and `hydrate/1` only runs at init - so without
%% an eviction an erased player keeps appearing in `top/2`, `rank/2` and
%% `around/3` for as long as the board process lives, which is indefinitely.
evict_removes_a_player_from_a_live_board() ->
    BoardId = board_id(),
    Erased = asobi_id:generate(),
    Kept = asobi_id:generate(),
    Pid = start_board(BoardId),
    ok = asobi_leaderboard_server:submit(BoardId, Erased, 200),
    ok = asobi_leaderboard_server:submit(BoardId, Kept, 100),
    ?assertEqual([{Erased, 200, 1}, {Kept, 100, 2}], asobi_leaderboard_server:top(BoardId, 10)),

    ok = asobi_leaderboard_server:evict_player(Erased),

    %% Gone from the ordered table, the player index, and every read path.
    ?assertEqual([{Kept, 100, 1}], asobi_leaderboard_server:top(BoardId, 10)),
    ?assertEqual({error, not_found}, asobi_leaderboard_server:rank(BoardId, Erased)),
    ?assertEqual([], asobi_leaderboard_server:around(BoardId, Erased, 5)),
    %% The player who was not erased keeps their entry and re-ranks.
    ?assertEqual({ok, 1}, asobi_leaderboard_server:rank(BoardId, Kept)),
    stop_board(BoardId, Pid).

%% The damaging half. A score still pending for a player who has just been
%% erased is an INSERT that violates `leaderboard_entries.player_id` ->
%% `players.id`; `flush_players/4` puts a failed write straight back into
%% `dirty`, so the board retries it every 30 seconds - and logs it - for the
%% rest of its life. Eviction has to clear `dirty`, not just the tables.
evict_drops_the_pending_score() ->
    BoardId = board_id(),
    Erased = asobi_id:generate(),
    Pid = start_board(BoardId),
    ok = asobi_leaderboard_server:submit(BoardId, Erased, 100),
    %% Still pending: the persist timer is 30s away, so nothing is written yet.
    ?assertEqual(not_found, db_score(BoardId, Erased)),

    ok = asobi_leaderboard_server:evict_player(Erased),
    _ = asobi_leaderboard_server:top(BoardId, 1),
    ets:insert(?DB, {writes, 0}),

    %% Shutdown flushes whatever is still dirty - the same call the 30s tick
    %% makes. `shutdown_flushes_pending_scores/0` proves this path does write a
    %% pending score, so a write here would be the retry that never stops.
    stop_board(BoardId, Pid),
    ?assertEqual(0, writes()),
    ?assertEqual(not_found, db_score(BoardId, Erased)).

%% --- Board lifecycle ---

board_id() ->
    iolist_to_binary([~"board_", integer_to_binary(erlang:unique_integer([positive]))]).

start_board(BoardId) ->
    {ok, Pid} = asobi_leaderboard_server:start_link(BoardId),
    Pid.

stop_board(BoardId, Pid) ->
    ok = gen_server:stop(Pid),
    wait_for_departure(BoardId, 100).

%% pg removes a dead member asynchronously, so a restart racing the stop
%% could otherwise call the previous pid.
wait_for_departure(BoardId, 0) ->
    ?assertEqual([], pg:get_members(?SCOPE, {asobi_leaderboard_server, BoardId}));
wait_for_departure(BoardId, Retries) ->
    case pg:get_members(?SCOPE, {asobi_leaderboard_server, BoardId}) of
        [] ->
            ok;
        _ ->
            timer:sleep(10),
            wait_for_departure(BoardId, Retries - 1)
    end.

%% --- Fake repo over ?DB ---

fake_all(#kura_query{from = asobi_leaderboard_entry, wheres = Wheres}) ->
    Rows = [Row || {{row, _B, _P}, Row} <- ets:tab2list(?DB)],
    {ok, [Row || Row <- Rows, matches(Row, Wheres)]}.

matches(Row, Wheres) ->
    lists:all(fun({Field, Value}) -> maps:get(Field, Row, undefined) =:= Value end, Wheres).

fake_insert(#kura_changeset{valid = true, changes = Changes}) ->
    store_row(Changes).

fake_update(#kura_changeset{valid = true, data = Data, changes = Changes}) ->
    store_row(maps:merge(Data, Changes)).

store_row(#{leaderboard_id := BoardId, player_id := PlayerId} = Row) ->
    ets:insert(?DB, {{row, BoardId, PlayerId}, Row}),
    ets:update_counter(?DB, writes, 1),
    {ok, Row}.

seed_row(BoardId, PlayerId, Score) ->
    Row = #{
        id => asobi_id:generate(),
        leaderboard_id => BoardId,
        player_id => PlayerId,
        score => Score,
        sub_score => 0
    },
    ets:insert(?DB, {{row, BoardId, PlayerId}, Row}).

db_score(BoardId, PlayerId) ->
    case ets:lookup(?DB, {row, BoardId, PlayerId}) of
        [{_, #{score := Score}}] -> Score;
        [] -> not_found
    end.

writes() ->
    [{writes, N}] = ets:lookup(?DB, writes),
    N.
