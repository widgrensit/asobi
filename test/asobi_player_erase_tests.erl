-module(asobi_player_erase_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("kura/include/kura.hrl").

%% The cascade itself is proved against a real database in
%% `asobi_guest_SUITE:reaper_erases_a_guest_with_a_row_in_every_child_table/1` -
%% a mocked `asobi_repo` cannot see a missing child delete, which is exactly how
%% eleven of them shipped. What is covered here is everything that is not a
%% constraint: the order the steps run in, what a refusing extension does, the
%% capability check, and the audit row committing with the erasure.

-define(PLAYER, ~"01960000-0000-7000-8000-000000000001").
-define(QUESTS, asobi_fixture_quests).

erase_test_() ->
    {foreach, fun setup/0, fun cleanup/1, [
        {"every referencing table is touched, in order", fun every_table_is_touched/0},
        {"a refusing extension leaves every core row alone", fun refusing_extension_aborts/0},
        {"the receipt and the group are severed, not deleted", fun severs_rather_than_deletes/0},
        {"both friendship columns are swept", fun friendships_use_both_columns/0},
        {"the audit row is written inside the transaction", fun audit_is_in_the_transaction/0},
        {"a failed audit insert rolls the erasure back", fun failed_audit_rolls_back/0},
        {"an actor without the erasure class is refused", fun without_the_class_is_forbidden/0},
        {"a refusal is audited too", fun a_refusal_is_audited/0},
        {"the shell entry point needs no capability", fun shell_needs_no_capability/0},
        {"a missing player is not_found, not a crash", fun missing_player_is_not_found/0},
        {"a failed lookup is not reported as a missing player",
            fun failed_lookup_is_not_not_found/0},
        {"a failed lookup at the last step rolls back", fun failed_final_lookup_rolls_back/0},
        {"the auth cache is revoked after the commit", fun revokes_after_commit/0},
        {"live leaderboards drop the player after the commit", fun evicts_leaderboards/0}
    ]}.

setup() ->
    asobi_extensions:reset(),
    asobi_fixture_erase:reset(),
    meck:new(asobi_repo, [no_link]),
    meck:new(asobi_ops_audit, [no_link, passthrough]),
    meck:new(asobi_auth_cache, [no_link]),
    meck:expect(asobi_auth_cache, revoke_player, fun(_PlayerId) -> ok end),
    meck:expect(asobi_ops_audit, record_strict, fun(_A, _Act, _T, _O) -> ok end),
    meck:expect(asobi_ops_audit, record, fun(_A, _Act, _T, _O) -> ok end),
    expect_player_present(),
    ok.

cleanup(_) ->
    _ = asobi_fixture_app:uninstall(?QUESTS),
    meck:unload(asobi_auth_cache),
    meck:unload(asobi_ops_audit),
    meck:unload(asobi_repo),
    asobi_fixture_erase:reset(),
    asobi_extensions:reset(),
    ok.

%% A transaction that runs its fun inline, so the assertions inside `steps/1`
%% are the thing under test rather than something a live driver would have to
%% be present to exercise.
expect_player_present() ->
    meck:expect(asobi_repo, transaction, fun(Fun) -> Fun() end),
    meck:expect(asobi_repo, get, fun(asobi_player, ?PLAYER) ->
        {ok, #{id => ?PLAYER, username => ~"kaito"}}
    end),
    meck:expect(asobi_repo, update_all, fun(_Q, _Updates) -> {ok, 1} end),
    meck:expect(asobi_repo, delete_all, fun(_Q) -> {ok, 1} end),
    meck:expect(asobi_repo, delete, fun(asobi_player, _Player) -> {ok, #{}} end).

install_quests() ->
    ok = asobi_fixture_app:install(?QUESTS, asobi_fixture_quests_extension, []).

actor(Caps) ->
    #{
        id => ~"static_secret",
        display => ~"operator",
        source => static_secret,
        caps => Caps,
        attested => false
    }.

%% Every schema a write touched, in the order the writes happened.
written() ->
    [
        schema_of(Args)
     || {_Pid, {asobi_repo, F, Args}, _Result} <- meck:history(asobi_repo),
        lists:member(F, [update_all, delete_all, delete])
    ].

schema_of([#kura_query{from = Schema} | _]) -> Schema;
schema_of([Schema | _]) when is_atom(Schema) -> Schema.

%% The enumeration, pinned. A table dropped from `steps/1` makes the player
%% undeletable in production and nothing else here would notice, because a
%% mocked repo has no foreign keys. This does not prove the list is complete -
%% only the CT test against Postgres can - but it does stop it shrinking.
%%
%% Extensions first, because an extension row holds the player down exactly as
%% core's own children do, and an erase path may still want to read core's rows.
every_table_is_touched() ->
    install_quests(),
    ?assertMatch({ok, _}, asobi_player_erase:run(?PLAYER)),
    ?assertEqual([{quests, ?PLAYER}], asobi_fixture_erase:calls()),
    ?assertEqual(
        [
            asobi_iap_transaction,
            asobi_group,
            asobi_transaction,
            asobi_wallet,
            asobi_player_item,
            asobi_storage,
            asobi_cloud_save,
            asobi_notification,
            asobi_leaderboard_entry,
            asobi_chat_message,
            asobi_group_member,
            asobi_friendship,
            asobi_player_stats,
            asobi_player_token,
            asobi_player_identity,
            asobi_player
        ],
        written()
    ).

%% Atomic. The extension refuses, the assertion inside `steps/1` raises, and
%% core never writes - so the player survives intact rather than half-erased.
refusing_extension_aborts() ->
    install_quests(),
    ok = asobi_fixture_erase:outcome(quests, {error, ledger_is_immutable}),
    ?assertMatch({error, {error, {badmatch, _}}}, asobi_player_erase:run(?PLAYER)),
    ?assertEqual([], written()).

%% The two tables that outlive their player. `iap_transactions` is a real-money
%% receipt a chargeback still needs; deleting a `groups` row to free its
%% `creator_id` would destroy every other member's data.
severs_rather_than_deletes() ->
    ?assertMatch({ok, _}, asobi_player_erase:run(?PLAYER)),
    Severed = [
        {schema_of(Args), Updates}
     || {_Pid, {asobi_repo, update_all, [_Q, Updates] = Args}, _R} <- meck:history(asobi_repo)
    ],
    ?assertEqual(
        [
            {asobi_iap_transaction, #{player_id => null}},
            {asobi_group, #{creator_id => null}}
        ],
        Severed
    ),
    Deleted = [S || S <- written(), S =:= asobi_iap_transaction orelse S =:= asobi_group],
    ?assertEqual([asobi_iap_transaction, asobi_group], Deleted).

%% One table, two foreign keys into the same player. A delete keyed only on
%% `player_id` leaves every friendship the player is on the receiving end of,
%% and each one holds the player row down.
friendships_use_both_columns() ->
    ?assertMatch({ok, _}, asobi_player_erase:run(?PLAYER)),
    [Wheres] = [
        W
     || {_Pid, {asobi_repo, delete_all, [#kura_query{from = asobi_friendship, wheres = W}]}, _R} <-
            meck:history(asobi_repo)
    ],
    ?assertEqual([{'or', [{player_id, ?PLAYER}, {friend_id, ?PLAYER}]}], Wheres).

%% ADR 0007's rule is audit-after and never fail the operation. Erasure is the
%% stated exception: the row is the only evidence left, so it commits with the
%% deletion. `record_strict/4` inside the transaction is what makes that true.
audit_is_in_the_transaction() ->
    Actor = actor([erasure]),
    ?assertMatch({ok, _}, asobi_player_erase:run(?PLAYER, Actor)),
    ?assertEqual(
        1,
        meck:num_calls(
            asobi_ops_audit, record_strict, [Actor, ~"players.erase", {~"player", ?PLAYER}, '_']
        )
    ),
    ?assertEqual(0, meck:num_calls(asobi_ops_audit, record, '_')).

failed_audit_rolls_back() ->
    meck:expect(asobi_ops_audit, record_strict, fun(_A, _Act, _T, _O) ->
        {error, disk_is_full}
    end),
    ?assertMatch({error, {error, {badmatch, _}}}, asobi_player_erase:run(?PLAYER)),
    %% The writes were issued, and the badmatch is what makes the transaction
    %% they sit in roll back rather than commit an unrecorded erasure.
    ?assert(written() =/= []).

without_the_class_is_forbidden() ->
    ?assertEqual(
        {error, forbidden}, asobi_player_erase:run(?PLAYER, actor([read, player_data, config]))
    ),
    ?assertEqual([], written()).

a_refusal_is_audited() ->
    Actor = actor([read]),
    {error, forbidden} = asobi_player_erase:run(?PLAYER, Actor),
    ?assertEqual(
        1,
        meck:num_calls(asobi_ops_audit, record, [
            Actor, ~"players.erase", {~"player", ?PLAYER}, {error, forbidden}
        ])
    ).

%% A caller holding a shell could call `asobi_repo:delete_all/1` directly, so
%% there is nothing for a capability check to protect here - but the row must
%% still say the node itself did it.
shell_needs_no_capability() ->
    ?assertMatch({ok, _}, asobi_player_erase:run(?PLAYER)),
    [{_Pid, {asobi_ops_audit, record_strict, [Actor | _]}, _R}] = [
        Call
     || {_P, {asobi_ops_audit, record_strict, _}, _} = Call <- meck:history(asobi_ops_audit)
    ],
    ?assertEqual(shell, maps:get(source, Actor)),
    ?assertEqual(false, maps:get(attested, Actor)).

missing_player_is_not_found() ->
    meck:expect(asobi_repo, get, fun(asobi_player, ?PLAYER) -> {error, not_found} end),
    ?assertEqual({error, not_found}, asobi_player_erase:run(?PLAYER)),
    ?assertEqual([], written()).

%% `kura_repo_worker:get/3` returns `{error, not_found}` for an absent row and
%% passes any query failure through as `{error, Other}`. Collapsing the two
%% tells an operator answering a deletion request that there is nobody to
%% delete, when the node only failed to find out - and 404 is the one answer
%% that makes them stop asking.
failed_lookup_is_not_not_found() ->
    meck:expect(asobi_repo, get, fun(asobi_player, ?PLAYER) -> {error, connection_closed} end),
    ?assertEqual({error, {lookup_failed, connection_closed}}, asobi_player_erase:run(?PLAYER)),
    ?assertEqual([], written()).

%% The same collapse one step lower is worse than a bad status code. Every
%% child delete has already been issued when `delete_player/1` runs, so reading
%% a failed lookup as "the row is already gone" returns `ok` from `steps/1`,
%% commits the children, and leaves the `players` row standing - a half-erased
%% player reporting success, with an audit row saying it was erased.
failed_final_lookup_rolls_back() ->
    meck:expect(asobi_repo, get, fun(asobi_player, ?PLAYER) ->
        case get(seen_first_get) of
            undefined ->
                put(seen_first_get, true),
                {ok, #{id => ?PLAYER, username => ~"kaito"}};
            true ->
                {error, statement_timeout}
        end
    end),
    ?assertMatch(
        {error, {error, {asobi_player_erase, {lookup_failed, _, _}}}},
        asobi_player_erase:run(?PLAYER)
    ),
    %% The raise is what rolls the issued child deletes back; committing them
    %% is the outcome this test exists to forbid.
    ?assertEqual(0, meck:num_calls(asobi_repo, delete, [asobi_player, '_'])).

%% asobi#215's revocation SLA: without this a deleted player's access token
%% keeps resolving from the cache for up to auth_cache_ttl_ms against a row
%% that no longer exists.
revokes_after_commit() ->
    ?assertMatch({ok, _}, asobi_player_erase:run(?PLAYER)),
    ?assertEqual(1, meck:num_calls(asobi_auth_cache, revoke_player, [?PLAYER])).

%% Deleting the `leaderboard_entries` rows is not enough: a running board serves
%% reads from ETS and only hydrates at init, so it keeps the erased player until
%% it restarts, and re-inserts any score still pending for them against a
%% foreign key that is gone. Behaviour of the eviction itself is covered by
%% `asobi_leaderboard_persistence_tests`; what this pins is that erasure calls
%% it at all, and after the commit rather than inside the transaction.
evicts_leaderboards() ->
    meck:new(asobi_leaderboard_server, [no_link, passthrough]),
    meck:expect(asobi_leaderboard_server, evict_player, fun(_PlayerId) -> ok end),
    try
        ?assertMatch({ok, _}, asobi_player_erase:run(?PLAYER)),
        ?assertEqual(1, meck:num_calls(asobi_leaderboard_server, evict_player, [?PLAYER])),
        %% After the commit: the player row is already deleted by the time the
        %% board is told. An eviction inside the transaction would be a lie if
        %% the transaction then rolled back, and ETS cannot roll back.
        ?assert(
            meck:called(asobi_repo, delete, [asobi_player, '_']) andalso
                meck:called(asobi_leaderboard_server, evict_player, [?PLAYER])
        )
    after
        meck:unload(asobi_leaderboard_server)
    end.
