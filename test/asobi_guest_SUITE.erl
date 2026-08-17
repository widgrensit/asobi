-module(asobi_guest_SUITE).

-include_lib("nova_test/include/nova_test.hrl").
-include_lib("kura/include/kura.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([
    create_then_resume_same_player/1,
    wrong_secret_rejected_no_new_player/1,
    weak_secret_rejected/1,
    upgrade_then_already_claimed/1,
    upgrade_rejected_for_non_guest/1,
    upgrade_clears_stale_auth_cache_entries/1,
    reaper_removes_unclaimed_guest_and_children/1,
    reaper_erases_a_guest_with_a_row_in_every_child_table/1,
    reaper_spares_an_old_guest_that_still_plays/1,
    create_retries_on_username_collision/1,
    create_no_retry_on_non_unique_username_error/1,
    a_full_deployment_says_capacity_reached/1,
    an_uncountable_table_says_unavailable_not_capacity/1,
    a_saturated_global_limiter_says_rate_limited/1,
    a_failing_count_is_asked_once_per_ttl/1
]).

all() ->
    [
        create_then_resume_same_player,
        wrong_secret_rejected_no_new_player,
        weak_secret_rejected,
        upgrade_then_already_claimed,
        upgrade_rejected_for_non_guest,
        upgrade_clears_stale_auth_cache_entries,
        reaper_removes_unclaimed_guest_and_children,
        reaper_erases_a_guest_with_a_row_in_every_child_table,
        reaper_spares_an_old_guest_that_still_plays,
        create_retries_on_username_collision,
        create_no_retry_on_non_unique_username_error,
        a_full_deployment_says_capacity_reached,
        an_uncountable_table_says_unavailable_not_capacity,
        a_saturated_global_limiter_says_rate_limited,
        a_failing_count_is_asked_once_per_ttl
    ].

%% Set BEFORE the app starts, which is the deployment this suite represents: an
%% operator with `{guest_auth, true}` in sys.config and no Lua bundle at all.
%%
%% That ordering is itself the regression test. Until ADR 0011 the flag was a
%% single key: booting asobi runs `asobi_lua_config:maybe_load_game_config/0`,
%% a node with no game bundle takes the `error` branch of `declared_config/1`,
%% and the `{guest_auth, false}` it derives was written straight over whatever
%% the operator had set. These three set_env calls had to run after the start to
%% survive at all. The flag now has an operator layer over a script layer, the
%% loader writes only the script layer, and if that ever regresses every case
%% here fails with 403 `guest.disabled`.
init_per_suite(Config0) ->
    application:set_env(asobi, guest_auth, true),
    application:set_env(asobi, guest_verifier_pepper, crypto:strong_rand_bytes(32)),
    application:set_env(asobi, guest_reap_after, 1),
    asobi_test_helpers:start(Config0).

end_per_suite(Config) ->
    Config.

%% --- Helpers ---

secret() ->
    base64:encode(crypto:strong_rand_bytes(32)).

device_id() ->
    base64:encode(crypto:strong_rand_bytes(16)).

create(DeviceId, Secret, Config) ->
    nova_test:post(
        "/api/v1/auth/guest",
        #{json => #{~"device_id" => DeviceId, ~"device_secret" => Secret}},
        Config
    ).

%% --- Tests ---

create_then_resume_same_player(Config) ->
    Dev = device_id(),
    Secret = secret(),
    {ok, R1} = create(Dev, Secret, Config),
    ?assertStatus(200, R1),
    #{~"player_id" := Pid1} = nova_test:json(R1),
    {ok, R2} = create(Dev, Secret, Config),
    ?assertStatus(200, R2),
    #{~"player_id" := Pid2} = nova_test:json(R2),
    ?assertEqual(Pid1, Pid2),
    Config.

wrong_secret_rejected_no_new_player(Config) ->
    Dev = device_id(),
    {ok, R1} = create(Dev, secret(), Config),
    #{~"player_id" := Pid} = nova_test:json(R1),
    {ok, R2} = create(Dev, secret(), Config),
    ?assertStatus(401, R2),
    %% The original secret still resumes the same, single player.
    {ok, R3} = create(Dev, secret(), Config),
    ?assertStatus(401, R3),
    ?assert(is_binary(Pid)),
    Config.

weak_secret_rejected(Config) ->
    {ok, R} = create(device_id(), base64:encode(crypto:strong_rand_bytes(16)), Config),
    ?assertStatus(400, R),
    Config.

upgrade_then_already_claimed(Config) ->
    {ok, R1} = create(device_id(), secret(), Config),
    #{~"access_token" := Token} = nova_test:json(R1),
    Auth = [{~"authorization", <<"Bearer ", Token/binary>>}],
    Username = asobi_test_helpers:unique_username(~"claimed"),
    {ok, R2} = nova_test:post(
        "/api/v1/auth/guest/upgrade",
        #{json => #{~"username" => Username, ~"password" => ~"secret1234"}, headers => Auth},
        Config
    ),
    ?assertStatus(200, R2),
    %% The pre-upgrade token was revoked (both DB row and auth-cache entry,
    %% asobi#215) as part of the upgrade, so it no longer authenticates at all.
    {ok, R3} = nova_test:post(
        "/api/v1/auth/guest/upgrade",
        #{json => #{~"username" => ~"other", ~"password" => ~"secret1234"}, headers => Auth},
        Config
    ),
    ?assertStatus(401, R3),
    %% A second upgrade attempt with the freshly issued token is refused
    %% because the account is now claimed.
    #{~"access_token" := NewToken} = nova_test:json(R2),
    NewAuth = [{~"authorization", <<"Bearer ", NewToken/binary>>}],
    {ok, R4} = nova_test:post(
        "/api/v1/auth/guest/upgrade",
        #{json => #{~"username" => ~"other", ~"password" => ~"secret1234"}, headers => NewAuth},
        Config
    ),
    ?assertStatus(409, R4),
    Config.

%% A passwordless account that is NOT a guest (e.g. OAuth-only) must not be able
%% to use the guest-upgrade path to set a password and rename itself - the gate
%% is "owns a guest identity AND has no password", not "has no password".
upgrade_rejected_for_non_guest(Config) ->
    Username = asobi_test_helpers:unique_username(~"oauthy"),
    PlayerCS = kura_changeset:validate_required(
        kura_changeset:cast(asobi_player, #{}, #{username => Username}, [username]),
        [username]
    ),
    {ok, Player} = asobi_repo:insert(PlayerCS),
    PlayerId = maps:get(id, Player),
    IdCS = asobi_player_identity:changeset(#{}, #{
        player_id => PlayerId, provider => ~"google", provider_uid => device_id()
    }),
    {ok, _} = asobi_repo:insert(IdCS),
    {json, 200, _, #{access_token := Token}} = asobi_auth_tokens:issue(Player, 200, #{}),
    Auth = [{~"authorization", <<"Bearer ", Token/binary>>}],
    {ok, R} = nova_test:post(
        "/api/v1/auth/guest/upgrade",
        #{json => #{~"username" => ~"hijacked", ~"password" => ~"secret1234"}, headers => Auth},
        Config
    ),
    ?assertStatus(409, R),
    Config.

%% asobi#215: do_upgrade/4 calls nova_auth_refresh:revoke_all/2, which deletes
%% every token DB row for the player - but a token cached as a valid positive
%% BEFORE the upgrade must not keep resolving from the ETS cache afterward.
%% Cover the actual attack this exists for: a second session on the same
%% device secret (the "stolen device secret" scenario the do_upgrade/4
%% comment describes) cached as a stale positive must also stop resolving -
%% not just the token the upgrade request itself carries. A test that only
%% seeds the caller's own token would pass equally with a single-token
%% invalidate/1 instead of the player-wide revoke_player/1 this exercises.
upgrade_clears_stale_auth_cache_entries(Config) ->
    Dev = device_id(),
    Secret = secret(),
    {ok, R1} = create(Dev, Secret, Config),
    #{~"access_token" := Token, ~"player_id" := PlayerId} = nova_test:json(R1),
    Auth = [{~"authorization", <<"Bearer ", Token/binary>>}],
    {ok, R1b} = create(Dev, Secret, Config),
    #{~"access_token" := StolenToken} = nova_test:json(R1b),
    ok = asobi_auth_cache:put_positive(Token, #{id => PlayerId, banned_at => nil}),
    ok = asobi_auth_cache:put_positive(StolenToken, #{id => PlayerId, banned_at => nil}),
    ?assertEqual({ok, #{id => PlayerId, banned_at => nil}}, asobi_auth_cache:resolve_token(Token)),
    ?assertEqual(
        {ok, #{id => PlayerId, banned_at => nil}}, asobi_auth_cache:resolve_token(StolenToken)
    ),
    Username = asobi_test_helpers:unique_username(~"cacheclr"),
    {ok, R2} = nova_test:post(
        "/api/v1/auth/guest/upgrade",
        #{json => #{~"username" => Username, ~"password" => ~"secret1234"}, headers => Auth},
        Config
    ),
    ?assertStatus(200, R2),
    ?assertEqual({error, not_found}, asobi_auth_cache:resolve_token(Token)),
    ?assertEqual({error, not_found}, asobi_auth_cache:resolve_token(StolenToken)),
    Config.

reaper_removes_unclaimed_guest_and_children(Config) ->
    %% asobi#327: supervised unconditionally, so it is up from boot whenever the
    %% app is - no start-on-demand, and no dependency on when guest_auth is set.
    ?assert(is_pid(whereis(asobi_guest_reaper))),
    {ok, R1} = create(device_id(), secret(), Config),
    #{~"player_id" := Pid} = nova_test:json(R1),
    %% Age the identity rather than sleeping past the cutoff, for the reason
    %% `reaper_erases_a_guest_with_a_row_in_every_child_table/1` states: the
    %% reaper compares whole seconds of `erlang:universaltime/0`, so a sleep
    %% makes this a wall-clock race. A host correcting its clock under the test
    %% advances less than the sleep did, the row ends up newer than the cutoff,
    %% and the sweep skips it - observed failing roughly one run in six, with
    %% `inserted_at` two seconds ahead of the timestamp taken at create.
    age_identity(Pid),
    {ok, _} = asobi_guest_reaper:sweep_now(),
    ?assertEqual({error, not_found}, asobi_repo:get(asobi_player, Pid)),
    Config.

%% asobi#369 part two. All 15 core foreign keys into `players.id` are ON DELETE
%% NO ACTION, and the reaper used to delete four tables: player_stats,
%% player_tokens, player_identities, players. A guest who earned one coin, wrote
%% one cloud save or sent one chat message therefore hit a constraint violation
%% on the players delete, the transaction rolled back, and the sweep retried it
%% forever - permanently unreapable, and invisible because the eunit tests meck
%% asobi_repo:delete_all/1 to {ok, 1}. Constraint enforcement is a property of
%% the schema, so this needs a real database and a row in EVERY referencing
%% table. Run it against the old reaper and it fails on the first assertion.
%%
%% It also pins the two tables that are severed rather than deleted: a purchase
%% record survives its player, and so does a group other people are in.
reaper_erases_a_guest_with_a_row_in_every_child_table(Config) ->
    {ok, R} = create(device_id(), secret(), Config),
    #{~"player_id" := PlayerId} = nova_test:json(R),

    Other = insert_player(),
    ItemDef = insert_item_def(),
    OwnGroup = insert_group(PlayerId),
    OtherGroup = insert_group(Other),
    Wallet = insert_wallet(PlayerId),
    Transaction = insert_transaction(Wallet),
    Item = insert_player_item(PlayerId, ItemDef),
    Storage = insert_storage(PlayerId),
    Save = insert_cloud_save(PlayerId),
    Notification = insert_notification(PlayerId),
    Entry = insert_leaderboard_entry(PlayerId),
    Message = insert_chat_message(PlayerId),
    Membership = insert_group_member(OtherGroup, PlayerId),
    %% Both friendship columns: one table, two foreign keys, and a delete
    %% keyed only on `player_id` leaves the other half holding the player down.
    Outgoing = insert_friendship(PlayerId, Other),
    Incoming = insert_friendship(Other, PlayerId),
    Receipt = insert_iap_transaction(PlayerId),
    Match = insert_match_record(PlayerId),
    Vote = insert_vote(PlayerId, Other),
    %% The guest create path writes these two itself, so they are asserted
    %% present rather than inserted - a table with nothing in it would make the
    %% delete that clears it untestable.
    ?assertEqual({ok, 1}, count(asobi_player_stats, player_id, PlayerId)),
    ?assertEqual({ok, 1}, count(asobi_player_identity, player_id, PlayerId)),

    %% Export the same footprint before erasing it. Three of its queries are SQL
    %% a mocked repo cannot check: the wallet-ledger subquery, the jsonb
    %% containment that finds a match record with no foreign key at all, and the
    %% `jsonb_exists` key probe that finds a vote. All three would return an
    %% empty list rather than fail if Postgres rejected them.
    {ok, Export} = asobi_player_export:run(PlayerId),
    ?assertEqual([Match], [Id || #{id := Id} <- maps:get(match_records, Export)]),
    ?assertEqual([Vote], [Id || #{id := Id} <- maps:get(votes, Export)]),
    %% One row, several people. The requester gets their own choice and no trace
    %% of the other voter - a data-subject request must not become a disclosure.
    [ExportedVote] = maps:get(votes, Export),
    ?assertEqual(~"yes", maps:get(choice, ExportedVote)),
    ?assertNot(maps:is_key(votes_cast, ExportedVote)),
    ?assertEqual(
        nomatch, binary:match(iolist_to_binary(io_lib:format("~p", [ExportedVote])), Other)
    ),
    ?assertEqual([Transaction], [Id || #{id := Id} <- maps:get(transactions, Export)]),
    ?assertEqual([Wallet], [Id || #{id := Id} <- maps:get(wallets, Export)]),
    ?assertEqual(
        lists:sort([Outgoing, Incoming]),
        lists:sort([Id || #{id := Id} <- maps:get(friendships, Export)])
    ),
    ?assertEqual([Receipt], [Id || #{id := Id} <- maps:get(iap_transactions, Export)]),
    ?assertNot(maps:is_key(hashed_password, maps:get(player, Export))),
    ?assertEqual([], [T || T <- maps:get(tokens, Export), maps:is_key(token, T)]),

    age_identity(PlayerId),
    {ok, Reaped} = asobi_guest_reaper:sweep_now(),
    ?assert(Reaped >= 1),

    ?assertEqual({error, not_found}, asobi_repo:get(asobi_player, PlayerId)),
    [
        ?assertEqual({error, not_found}, asobi_repo:get(Schema, Id))
     || {Schema, Id} <- [
            {asobi_transaction, Transaction},
            {asobi_wallet, Wallet},
            {asobi_player_item, Item},
            {asobi_storage, Storage},
            {asobi_cloud_save, Save},
            {asobi_notification, Notification},
            {asobi_leaderboard_entry, Entry},
            {asobi_chat_message, Message},
            {asobi_group_member, Membership},
            {asobi_friendship, Outgoing},
            {asobi_friendship, Incoming}
        ]
    ],
    ?assertEqual({ok, 0}, count(asobi_player_stats, player_id, PlayerId)),
    ?assertEqual({ok, 0}, count(asobi_player_identity, player_id, PlayerId)),
    ?assertEqual({ok, 0}, count(asobi_player_token, user_id, PlayerId)),

    %% Severed, not destroyed. The receipt is a real-money record a chargeback
    %% still needs; the group is other people's data.
    ?assertMatch({ok, #{player_id := undefined}}, asobi_repo:get(asobi_iap_transaction, Receipt)),
    ?assertMatch({ok, #{creator_id := undefined}}, asobi_repo:get(asobi_group, OwnGroup)),
    ?assertMatch({ok, #{creator_id := Other}}, asobi_repo:get(asobi_group, OtherGroup)),
    Config.

%% --- Row fixtures for the erasure test ---
%%
%% Built through changesets on an unmocked asobi_repo, so every constraint the
%% migrations declare is live.

insert(Schema, Params) ->
    CS = kura_changeset:cast(Schema, #{}, Params, maps:keys(Params)),
    {ok, Row} = asobi_repo:insert(CS),
    Row.

insert_player() ->
    #{id := Id} = insert(asobi_player, #{
        username => asobi_test_helpers:unique_username(~"erasee")
    }),
    Id.

insert_item_def() ->
    #{id := Id} = insert(asobi_item_def, #{
        slug => asobi_test_helpers:unique_id(~"slug"),
        name => ~"Torch",
        category => ~"tool"
    }),
    Id.

insert_group(CreatorId) ->
    #{id := Id} = insert(asobi_group, #{
        name => asobi_test_helpers:unique_id(~"guild"), creator_id => CreatorId
    }),
    Id.

insert_wallet(PlayerId) ->
    #{id := Id} = insert(asobi_wallet, #{
        player_id => PlayerId, currency => ~"gold", balance => 1
    }),
    Id.

insert_transaction(WalletId) ->
    #{id := Id} = insert(asobi_transaction, #{
        wallet_id => WalletId, amount => 1, balance_after => 1, reason => ~"test"
    }),
    Id.

insert_player_item(PlayerId, ItemDefId) ->
    #{id := Id} = insert(asobi_player_item, #{
        player_id => PlayerId, item_def_id => ItemDefId, acquired_at => calendar:universal_time()
    }),
    Id.

insert_storage(PlayerId) ->
    #{id := Id} = insert(asobi_storage, #{
        collection => ~"inventory",
        key => asobi_test_helpers:unique_id(~"key"),
        player_id =>
            PlayerId
    }),
    Id.

insert_cloud_save(PlayerId) ->
    #{id := Id} = insert(asobi_cloud_save, #{player_id => PlayerId, slot => ~"1"}),
    Id.

insert_notification(PlayerId) ->
    #{id := Id} = insert(asobi_notification, #{
        player_id => PlayerId,
        type => ~"system",
        subject => ~"hello",
        sent_at => calendar:universal_time()
    }),
    Id.

insert_leaderboard_entry(PlayerId) ->
    #{id := Id} = insert(asobi_leaderboard_entry, #{
        leaderboard_id => asobi_test_helpers:unique_id(~"board"), player_id => PlayerId, score => 1
    }),
    Id.

insert_chat_message(PlayerId) ->
    #{id := Id} = insert(asobi_chat_message, #{
        channel_type => ~"global",
        channel_id => ~"global",
        sender_id => PlayerId,
        content => ~"hi",
        sent_at => calendar:universal_time()
    }),
    Id.

insert_group_member(GroupId, PlayerId) ->
    #{id := Id} = insert(asobi_group_member, #{
        group_id => GroupId, player_id => PlayerId, joined_at => calendar:universal_time()
    }),
    Id.

insert_friendship(PlayerId, FriendId) ->
    #{id := Id} = insert(asobi_friendship, #{player_id => PlayerId, friend_id => FriendId}),
    Id.

%% No foreign key: `players` is a jsonb array of ids, exactly as
%% `asobi_match_server` writes it.
insert_match_record(PlayerId) ->
    #{id := Id} = insert(asobi_match_record, #{
        status => ~"finished", players => [PlayerId, asobi_id:generate()]
    }),
    Id.

%% `votes_cast` is keyed by voter id, so this row carries a second voter whose
%% choice must not come back in the first player's export.
insert_vote(PlayerId, OtherVoter) ->
    #{id := Id} = insert(asobi_vote, #{
        match_id => asobi_id:generate(),
        template => ~"kick",
        method => ~"majority",
        options => [~"yes", ~"no"],
        votes_cast => #{PlayerId => ~"yes", OtherVoter => ~"no"},
        window_ms => 30000
    }),
    Id.

insert_iap_transaction(PlayerId) ->
    #{id := Id} = insert(asobi_iap_transaction, #{
        player_id => PlayerId,
        provider => ~"apple",
        transaction_id => asobi_test_helpers:unique_id(~"txn")
    }),
    Id.

count(Schema, Field, Value) ->
    asobi_repo:aggregate(kura_query:where(kura_query:from(Schema), {Field, Value}), count).

%% Push the identity's timestamps far behind any cutoff, so a reap is a property
%% of the row rather than of how much wall clock passed during the test. The
%% reaper's predicate is `updated_at < universaltime() - reap_after` at
%% whole-second granularity, which a sleep can only race with.
%%
%% Both columns, though only `updated_at` is the predicate: a row aged on one
%% but not the other is a state the application never produces, and pinning the
%% predicate to whichever column is stale would make the test agree with the
%% reaper for the wrong reason.
age_identity(PlayerId) ->
    Ancient = {{2020, 1, 1}, {0, 0, 0}},
    {ok, 1} = asobi_repo:update_all(
        kura_query:where(kura_query:from(asobi_player_identity), {player_id, PlayerId}),
        #{inserted_at => Ancient, updated_at => Ancient}
    ),
    ok.

%% The reap predicate is inactivity, not account age. A device that keeps
%% resuming is a player who is still here, however long ago they first launched
%% the game - and under device auth they stay "unclaimed" forever, because
%% there is no password to set and no provider to link. Keyed on `inserted_at`
%% this test deletes the player: the identity is aged past the cutoff and
%% nothing on the resume path moved it back.
%%
%% This is the case that made the erasure change dangerous rather than merely
%% wrong. While the cascade was broken any such guest hit an FK violation and
%% was logged skipped, so the predicate never got to finish the job; completing
%% the cascade is what turned it into permanent, unaudited deletion of the
%% active player base, at ?REAP_BATCH per sweep.
reaper_spares_an_old_guest_that_still_plays(Config) ->
    Dev = device_id(),
    Secret = secret(),
    {ok, R1} = create(Dev, Secret, Config),
    ?assertStatus(200, R1),
    #{~"player_id" := PlayerId} = nova_test:json(R1),

    %% An account created long ago...
    age_identity(PlayerId),

    %% ...whose owner just opened the game. Same device, same secret: a resume,
    %% not a create - assert that, or a regression that silently created a
    %% second player would still pass the survival check below.
    {ok, R2} = create(Dev, Secret, Config),
    ?assertStatus(200, R2),
    ?assertEqual(#{~"player_id" => PlayerId}, maps:with([~"player_id"], nova_test:json(R2))),

    {ok, _} = asobi_guest_reaper:sweep_now(),
    ?assertMatch({ok, _}, asobi_repo:get(asobi_player, PlayerId)),
    ?assertEqual({ok, 1}, count(asobi_player_identity, player_id, PlayerId)),

    %% And the sweep still works: the same account goes when it does fall idle,
    %% so this test cannot pass by the reaper being broken outright.
    age_identity(PlayerId),
    {ok, _} = asobi_guest_reaper:sweep_now(),
    ?assertEqual({error, not_found}, asobi_repo:get(asobi_player, PlayerId)),
    Config.

%% A generated username colliding with an existing one (previously: any two
%% guests created in the same millisecond, since the old suffix was a UUIDv7
%% prefix with zero randomness) must retry with a fresh one instead of
%% surfacing a 500 on the first collision.
create_retries_on_username_collision(Config) ->
    CollisionSuffix = asobi_id:rand_suffix(8),
    CollisionUsername = <<"guest_", CollisionSuffix/binary>>,
    ExistingCS = kura_changeset:validate_required(
        kura_changeset:cast(asobi_player, #{}, #{username => CollisionUsername}, [username]),
        [username]
    ),
    {ok, _} = asobi_repo:insert(ExistingCS),

    %% Mock the shared helper, not crypto:strong_rand_bytes/1 directly - the
    %% latter is process-wide and shared with unrelated 8-byte callers, which
    %% would make this test flaky against future code that also asks crypto
    %% for 8 random bytes.
    Counter = counters:new(1, []),
    meck:new(asobi_id, [passthrough]),
    meck:expect(asobi_id, rand_suffix, fun
        (8) ->
            case counters:get(Counter, 1) of
                0 ->
                    counters:add(Counter, 1, 1),
                    CollisionSuffix;
                _ ->
                    meck:passthrough([8])
            end;
        (N) ->
            meck:passthrough([N])
    end),
    try
        {ok, R} = create(device_id(), secret(), Config),
        ?assertStatus(200, R),
        #{~"player_id" := Pid, ~"username" := Username} = nova_test:json(R),
        ?assert(is_binary(Pid)),
        ?assertNotEqual(CollisionUsername, Username)
    after
        meck:unload(asobi_id)
    end,
    Config.

%% A `username` error that is NOT a uniqueness conflict (e.g. a future
%% format/length validation) must 500 immediately rather than burn all 3
%% retry attempts on a failure retrying can never fix.
create_no_retry_on_non_unique_username_error(Config) ->
    meck:new(asobi_repo, [passthrough]),
    meck:expect(asobi_repo, insert, fun
        (#kura_changeset{schema = asobi_player} = CS) ->
            {error, kura_changeset:add_error(CS, username, ~"is reserved")};
        (CS) ->
            meck:passthrough([CS])
    end),
    try
        {ok, R} = create(device_id(), secret(), Config),
        ?assertStatus(500, R),
        ?assertEqual(1, meck:num_calls(asobi_repo, insert, '_'))
    after
        meck:unload(asobi_repo)
    end,
    Config.

%% asobi#419: the three refusals used to answer with one code, so a report of
%% "capacity reached" from the field could be any of them. Each is wired end to
%% end here, at the HTTP boundary a client actually sees, because the split is
%% only worth anything if the code reaches the client.

a_full_deployment_says_capacity_reached(Config) ->
    application:set_env(asobi, guest_unlinked_cap, 0),
    try
        {ok, R} = create(device_id(), secret(), Config),
        ?assertStatus(503, R),
        ?assertMatch(
            #{~"error" := #{~"code" := ~"guest.capacity_reached"}}, nova_test:json(R)
        )
    after
        application:unset_env(asobi, guest_unlinked_cap)
    end,
    Config.

%% The one this change exists for. A repo error while counting is not a full
%% deployment, and answering as though it were is what made the original report
%% undiagnosable. Still a refusal - the cap fails closed - under its own code.
an_uncountable_table_says_unavailable_not_capacity(Config) ->
    meck:new(asobi_guest_reaper, [passthrough]),
    meck:expect(asobi_guest_reaper, cached_unlinked_count, fun() -> unknown end),
    try
        {ok, R} = create(device_id(), secret(), Config),
        ?assertStatus(503, R),
        ?assertMatch(#{~"error" := #{~"code" := ~"guest.unavailable"}}, nova_test:json(R))
    after
        meck:unload(asobi_guest_reaper)
    end,
    Config.

%% The global limiter is a throughput bound, not a ceiling: a 429 with a
%% retry_after tells a client to come back, where the old 503 told it the
%% deployment was full and there was nothing to come back for.
a_saturated_global_limiter_says_rate_limited(Config) ->
    Restore = #{algorithm => sliding_window, limit => 100, window => 1000},
    ok = seki:delete_limiter(asobi_guest_global_limiter),
    %% limit 1, not 0: seki divides by the limit to compute retry_after, so a
    %% zero-limit bucket crashes instead of denying (Taure/seki#17). One create
    %% to spend the budget, a second to be refused by it.
    ok = seki:new_limiter(asobi_guest_global_limiter, Restore#{limit => 1}),
    try
        {ok, First} = create(device_id(), secret(), Config),
        ?assertStatus(200, First),
        {ok, R} = create(device_id(), secret(), Config),
        ?assertStatus(429, R),
        ?assertMatch(
            #{
                ~"error" := #{
                    ~"code" := ~"guest.rate_limited", ~"details" := #{~"retry_after" := _}
                }
            },
            nova_test:json(R)
        )
    after
        ok = seki:delete_limiter(asobi_guest_global_limiter),
        ok = seki:new_limiter(asobi_guest_global_limiter, Restore)
    end,
    Config.

%% A failing count fails the create closed, so without caching the failure every
%% single guest create re-runs a COUNT against the database that is already
%% having trouble - a create storm turns one struggling query into a flood of
%% them. The failure is cached for the same TTL as a good count, so the load is
%% one attempt per window whichever way the query goes.
a_failing_count_is_asked_once_per_ttl(Config) ->
    application:set_env(asobi, guest_unlinked_count_ttl_ms, 60000),
    meck:new(asobi_repo, [passthrough]),
    meck:expect(asobi_repo, aggregate, fun(_Q, count) -> {error, timeout} end),
    try
        ets:delete_all_objects(asobi_guest_count_cache),
        ?assertEqual(unknown, asobi_guest_reaper:cached_unlinked_count()),
        ?assertEqual(unknown, asobi_guest_reaper:cached_unlinked_count()),
        ?assertEqual(unknown, asobi_guest_reaper:cached_unlinked_count()),
        ?assertEqual(1, meck:num_calls(asobi_repo, aggregate, '_')),

        %% And the create path still refuses, under the honest code.
        {ok, R} = create(device_id(), secret(), Config),
        ?assertStatus(503, R),
        ?assertMatch(#{~"error" := #{~"code" := ~"guest.unavailable"}}, nova_test:json(R))
    after
        meck:unload(asobi_repo),
        ets:delete_all_objects(asobi_guest_count_cache),
        application:unset_env(asobi, guest_unlinked_count_ttl_ms)
    end,
    Config.
