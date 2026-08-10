-module(asobi_ops_write_tests).

%% The ops write plane's branching, with the database and the revocation
%% machinery mocked. The parts that need a real Postgres - the audit row
%% actually landing, the wallet actually moving, the same key twice - are in
%% `asobi_ops_write_SUITE`.
%%
%% Every mutation here is wrapped in `asobi_ops_audit:mutation/4`, which writes
%% a row through `asobi_repo:insert/1`. `asobi_repo` is mocked in each fixture,
%% so the audit insert is answered rather than attempted; where the audit's
%% *content* is the point, the mock records it.

-include_lib("eunit/include/eunit.hrl").
-include_lib("kura/include/kura.hrl").

-define(PLAYER_ID, ~"0197f3d0-1c2b-7000-8000-000000000001").
-define(ITEM_ID, ~"0197f3d0-1c2b-7000-8000-0000000000aa").
-define(PG_SCOPE, nova_scope).

%%--------------------------------------------------------------------
%% Capability classes
%%--------------------------------------------------------------------

%% ADR 0007's split, exercised for the first time. A credential that may
%% publish a store must not be able to ban, and vice versa - so each mutation
%% is called with the *other* class and has to refuse.

caps_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        fun ban_needs_player_data/0,
        fun unban_needs_player_data/0,
        fun grant_needs_player_data/0,
        fun create_item_needs_config/0,
        fun create_listing_needs_config/0,
        fun create_tournament_needs_config/0,
        fun player_data_actor_may_ban/0,
        fun config_actor_may_create/0
    ]}.

ban_needs_player_data() ->
    ?assertEqual({error, forbidden}, asobi_ops_moderation:ban(actor([read, config]), ?PLAYER_ID)).

unban_needs_player_data() ->
    ?assertEqual({error, forbidden}, asobi_ops_moderation:unban(actor([read, config]), ?PLAYER_ID)).

grant_needs_player_data() ->
    ?assertEqual(
        {error, forbidden},
        asobi_ops_grants:grant(actor([read, config]), ?PLAYER_ID, ~"gold", 10, ~"k1")
    ).

create_item_needs_config() ->
    ?assertEqual(
        {error, forbidden},
        asobi_ops_definitions:create_item(actor([read, player_data]), item_params())
    ).

create_listing_needs_config() ->
    ?assertEqual(
        {error, forbidden},
        asobi_ops_definitions:create_listing(actor([read, player_data]), listing_params())
    ).

create_tournament_needs_config() ->
    ?assertEqual(
        {error, forbidden},
        asobi_ops_definitions:create_tournament(actor([read, player_data]), tournament_params())
    ).

%% The negative controls above would pass against a function that refused
%% everyone, so pin that the class actually admits the credential that holds
%% it.
player_data_actor_may_ban() ->
    expect_player(#{}),
    expect_update(),
    ?assertEqual(
        {ok, [?PLAYER_ID], []}, asobi_ops_moderation:ban(actor([player_data]), ?PLAYER_ID)
    ).

config_actor_may_create() ->
    expect_insert(),
    ?assertMatch(
        {ok, [_Id], []}, asobi_ops_definitions:create_item(actor([config]), item_params())
    ).

%% A refusal is still a mutation attempt, and ADR 0007 asks for the attempt to
%% be on the record - otherwise a probe for what a credential can reach leaves
%% no trace.
refused_mutation_is_still_audited_test_() ->
    {setup, fun setup/0, fun cleanup/1, fun() ->
        _ = asobi_ops_moderation:ban(actor([read]), ?PLAYER_ID),
        Row = audit_row(),
        ?assertEqual(~"players.ban", maps:get(action, Row)),
        ?assertEqual(~"error", maps:get(outcome, Row)),
        ?assertEqual(?PLAYER_ID, maps:get(target_id, Row))
    end}.

%%--------------------------------------------------------------------
%% Ban
%%--------------------------------------------------------------------

ban_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        fun ban_writes_the_timestamp/0,
        fun ban_revokes_tokens_and_sockets/0,
        fun ban_of_a_banned_player_does_not_move_the_timestamp/0,
        fun ban_of_a_banned_player_still_revokes/0,
        fun ban_of_an_unknown_player_is_not_found/0,
        fun ban_reports_a_failed_write_as_a_failed_subject/0,
        fun unban_clears_the_timestamp/0,
        fun unban_of_an_active_player_changes_nothing/0
    ]}.

ban_writes_the_timestamp() ->
    expect_player(#{}),
    expect_update(),
    ?assertEqual({ok, [?PLAYER_ID], []}, asobi_ops_moderation:ban(actor(), ?PLAYER_ID)),
    ?assertMatch({{_, _, _}, {_, _, _}}, updated_banned_at()).

%% Two of the three steps that turn a column into an enforced ban. The socket
%% is asserted against the real `m:asobi_presence` and real `pg` - the fact
%% that matters is that the connection was told, not that a function was
%% called.
%%
%% The third step, evicting `m:asobi_auth_cache`, is covered in
%% `asobi_ops_write_SUITE` instead, where a real session token stops working.
%% It is not covered here because observing it needs the cache gen_server, and
%% a fixture that starts or stops a process the whole node shares takes
%% unrelated fixtures down with it - which is exactly what this one did.
ban_revokes_tokens_and_sockets() ->
    expect_player(#{}),
    expect_update(),
    pg:join(?PG_SCOPE, {player, ?PLAYER_ID}, self()),
    {ok, [_], []} = asobi_ops_moderation:ban(actor(), ?PLAYER_ID),
    ?assert(meck:called(nova_auth_refresh, revoke_all, [asobi_auth, ?PLAYER_ID])),
    ?assertEqual(~"banned", revocation()).

%% The first ban's timestamp is evidence. A second press must not move it, so
%% the already-banned path must not reach `asobi_repo:update/1` at all.
ban_of_a_banned_player_does_not_move_the_timestamp() ->
    expect_player(#{banned_at => {{2026, 1, 1}, {0, 0, 0}}}),
    expect_update(),
    ?assertEqual({ok, [], []}, asobi_ops_moderation:ban(actor(), ?PLAYER_ID)),
    ?assertEqual(0, meck:num_calls(asobi_repo, update, '_')).

%% Pressing ban twice must still close a connection that slipped in between,
%% which is the whole reason the already-banned path re-runs the sweep rather
%% than returning early.
ban_of_a_banned_player_still_revokes() ->
    expect_player(#{banned_at => {{2026, 1, 1}, {0, 0, 0}}}),
    expect_update(),
    pg:join(?PG_SCOPE, {player, ?PLAYER_ID}, self()),
    {ok, [], []} = asobi_ops_moderation:ban(actor(), ?PLAYER_ID),
    ?assert(meck:called(nova_auth_refresh, revoke_all, [asobi_auth, ?PLAYER_ID])),
    ?assertEqual(~"banned", revocation()).

ban_of_an_unknown_player_is_not_found() ->
    meck:expect(asobi_repo, get, fun(asobi_player, _Id) -> {error, not_found} end),
    ?assertEqual({error, not_found}, asobi_ops_moderation:ban(actor(), ?PLAYER_ID)).

%% A failed write is not `{error, _}`: the subject was known and acted on, so
%% it belongs in `Failed`, where `asobi_ops_audit:classify/1` reads it as an
%% error with the player's id attached.
ban_reports_a_failed_write_as_a_failed_subject() ->
    expect_player(#{}),
    meck:expect(asobi_repo, update, fun(_CS) -> {error, closed} end),
    ?assertEqual({ok, [], [{?PLAYER_ID, closed}]}, asobi_ops_moderation:ban(actor(), ?PLAYER_ID)),
    ?assertEqual(~"error", maps:get(outcome, audit_row())).

unban_clears_the_timestamp() ->
    expect_player(#{banned_at => {{2026, 1, 1}, {0, 0, 0}}}),
    expect_update(),
    ?assertEqual({ok, [?PLAYER_ID], []}, asobi_ops_moderation:unban(actor(), ?PLAYER_ID)),
    ?assertEqual(undefined, updated_banned_at()).

unban_of_an_active_player_changes_nothing() ->
    expect_player(#{}),
    expect_update(),
    ?assertEqual({ok, [], []}, asobi_ops_moderation:unban(actor(), ?PLAYER_ID)),
    ?assertEqual(0, meck:num_calls(asobi_repo, update, '_')).

%%--------------------------------------------------------------------
%% Grants
%%--------------------------------------------------------------------

grant_test_() ->
    {setup, fun setup_grants/0, fun cleanup_grants/1, [
        fun grant_without_a_key_is_refused_before_any_write/0,
        fun grant_rejects_a_non_positive_amount/0,
        fun grant_rejects_an_amount_over_the_cap/0,
        fun grant_rejects_a_non_integer_amount/0,
        fun grant_rejects_an_empty_currency/0,
        fun grant_to_an_unknown_player_writes_nothing/0,
        fun grant_applied_reports_the_player/0,
        fun grant_replay_reports_no_subject/0,
        fun grant_passes_the_key_and_the_actor_through/0
    ]}.

%% The whole reason the key is required rather than optional: a money mutation
%% whose safe path depends on the caller remembering is not a safe path.
grant_without_a_key_is_refused_before_any_write() ->
    ?assertEqual(
        {error, invalid_idempotency_key},
        asobi_ops_grants:grant(actor(), ?PLAYER_ID, ~"gold", 100, undefined)
    ),
    ?assertEqual(0, meck:num_calls(asobi_economy, grant_once, '_')).

grant_rejects_a_non_positive_amount() ->
    ?assertEqual(
        {error, invalid_amount}, asobi_ops_grants:grant(actor(), ?PLAYER_ID, ~"gold", 0, ~"k")
    ),
    ?assertEqual(
        {error, invalid_amount}, asobi_ops_grants:grant(actor(), ?PLAYER_ID, ~"gold", -5, ~"k")
    ),
    ?assertEqual(0, meck:num_calls(asobi_economy, grant_once, '_')).

%% A mis-pasted balance is the difference between a grant and a destroyed
%% economy.
grant_rejects_an_amount_over_the_cap() ->
    ?assertEqual(
        {error, invalid_amount},
        asobi_ops_grants:grant(actor(), ?PLAYER_ID, ~"gold", 1000000001, ~"k")
    ).

grant_rejects_a_non_integer_amount() ->
    ?assertEqual(
        {error, invalid_amount}, asobi_ops_grants:grant(actor(), ?PLAYER_ID, ~"gold", ~"100", ~"k")
    ).

grant_rejects_an_empty_currency() ->
    ?assertEqual(
        {error, invalid_currency}, asobi_ops_grants:grant(actor(), ?PLAYER_ID, ~"", 10, ~"k")
    ).

%% The wallet is created on demand, so a mistyped uuid would otherwise buy an
%% orphan wallet holding real currency that no player can ever spend.
grant_to_an_unknown_player_writes_nothing() ->
    meck:expect(asobi_repo, get, fun(asobi_player, _Id) -> {error, not_found} end),
    ?assertEqual(
        {error, not_found}, asobi_ops_grants:grant(actor(), ?PLAYER_ID, ~"gold", 10, ~"k")
    ),
    ?assertEqual(0, meck:num_calls(asobi_economy, grant_once, '_')).

grant_applied_reports_the_player() ->
    expect_player(#{}),
    meck:expect(asobi_economy, grant_once, fun(_P, _C, _A, _O, _K) ->
        {ok, applied, #{balance => 10}}
    end),
    ?assertEqual(
        {ok, [?PLAYER_ID], []}, asobi_ops_grants:grant(actor(), ?PLAYER_ID, ~"gold", 10, ~"k")
    ),
    ?assertEqual(1, maps:get(succeeded_count, audit_row())).

%% A replay succeeded and moved nothing, which is exactly `{ok, [], []}`:
%% `outcome = ok` with `succeeded_count = 0`. That is what lets an audit
%% reconciled against the ledger explain two audit rows over one transaction.
grant_replay_reports_no_subject() ->
    expect_player(#{}),
    meck:expect(asobi_economy, grant_once, fun(_P, _C, _A, _O, _K) ->
        {ok, duplicate, #{balance => 10}}
    end),
    ?assertEqual({ok, [], []}, asobi_ops_grants:grant(actor(), ?PLAYER_ID, ~"gold", 10, ~"k")),
    Row = audit_row(),
    ?assertEqual(~"ok", maps:get(outcome, Row)),
    ?assertEqual(0, maps:get(succeeded_count, Row)).

%% The ledger row should say who authorised the money, not just that somebody
%% did.
grant_passes_the_key_and_the_actor_through() ->
    expect_player(#{}),
    meck:expect(asobi_economy, grant_once, fun(_P, _C, _A, _O, _K) ->
        {ok, applied, #{balance => 10}}
    end),
    meck:reset(asobi_economy),
    {ok, [_], []} = asobi_ops_grants:grant(actor(), ?PLAYER_ID, ~"gold", 10, ~"key-7"),
    [{_, {_, _, [_P, _C, _A, Opts, Key]}, _}] = [
        Call
     || {_, {asobi_economy, grant_once, _}, _} = Call <- meck:history(asobi_economy)
    ],
    ?assertEqual(~"key-7", Key),
    ?assertEqual(~"ops_grant", maps:get(reference_type, Opts)),
    ?assertEqual(
        #{actor_id => ~"static_secret", actor_display => ~"kaito"}, maps:get(metadata, Opts)
    ).

%%--------------------------------------------------------------------
%% Definitions
%%--------------------------------------------------------------------

definitions_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        fun create_item_returns_the_id_it_audited/0,
        fun create_listing_rejects_a_malformed_item_id/0,
        fun create_rejects_an_oversized_jsonb_field/0,
        fun create_reports_changeset_errors_per_field/0,
        fun create_drops_a_field_outside_the_allowlist/0
    ]}.

%% The id is minted before the write so the audit row can carry it as
%% `target_id`; the response must then report that same id, not another one.
create_item_returns_the_id_it_audited() ->
    expect_insert(),
    {ok, [Id], []} = asobi_ops_definitions:create_item(actor(), item_params()),
    ?assertEqual(Id, maps:get(target_id, audit_row())),
    ?assertEqual(~"item_def", maps:get(target_type, audit_row())).

%% kura accepts any 36-byte binary as a uuid and Postgres raises on one that
%% is not, so an unchecked typo is a 500.
create_listing_rejects_a_malformed_item_id() ->
    expect_insert(),
    Params = maps:put(~"item_def_id", ~"not-a-uuid-but-still-thirty-six-byte", listing_params()),
    ?assertMatch(
        {error, {invalid, #{~"item_def_id" := _}}},
        asobi_ops_definitions:create_listing(actor(), Params)
    ),
    ?assertEqual(0, writes()).

create_rejects_an_oversized_jsonb_field() ->
    expect_insert(),
    Big = #{~"blob" => binary:copy(~"x", asobi_jsonb:default_metadata_bytes() + 1)},
    Params = maps:put(~"rewards", Big, tournament_params()),
    ?assertMatch(
        {error, {invalid, #{~"rewards" := _}}},
        asobi_ops_definitions:create_tournament(actor(), Params)
    ),
    ?assertEqual(0, writes()).

%% The schema's own validations, reported per field rather than as a 500.
create_reports_changeset_errors_per_field() ->
    expect_insert(),
    Params = maps:put(~"rarity", ~"mythic", item_params()),
    ?assertMatch(
        {error, {invalid, #{rarity := _}}}, asobi_ops_definitions:create_item(actor(), Params)
    ).

%% `status` is castable on a tournament and deliberately absent from the item
%% allowlist. An unlisted key must never reach the changeset.
create_drops_a_field_outside_the_allowlist() ->
    expect_insert(),
    Params = maps:put(~"stackable", false, maps:put(~"id", ~"chosen-by-the-caller", item_params())),
    {ok, [Id], []} = asobi_ops_definitions:create_item(actor(), Params),
    ?assertNotEqual(~"chosen-by-the-caller", Id),
    #kura_changeset{changes = Changes} = inserted_changeset(),
    ?assertEqual(Id, maps:get(id, Changes)),
    ?assertEqual(false, maps:get(stackable, Changes)).

%%--------------------------------------------------------------------
%% Controller: outcome to response
%%--------------------------------------------------------------------

response_maps_a_changed_mutation_to_200_test_() ->
    {setup, fun setup/0, fun cleanup/1, fun() ->
        expect_player(#{}),
        expect_update(),
        ?assertMatch(
            {json, 200, #{}, #{data := #{banned := true, changed := true}}},
            asobi_ops_write_controller:ban(req(#{}))
        )
    end}.

response_maps_an_unchanged_mutation_to_200_test_() ->
    {setup, fun setup/0, fun cleanup/1, fun() ->
        expect_player(#{banned_at => {{2026, 1, 1}, {0, 0, 0}}}),
        expect_update(),
        ?assertMatch(
            {json, 200, #{}, #{data := #{changed := false}}},
            asobi_ops_write_controller:ban(req(#{}))
        )
    end}.

response_maps_a_create_to_201_test_() ->
    {setup, fun setup/0, fun cleanup/1, fun() ->
        expect_insert(),
        ?assertMatch(
            {json, 201, #{}, #{data := #{id := _}}},
            asobi_ops_write_controller:create_item(req(#{json => item_params()}))
        )
    end}.

response_maps_a_missing_key_to_its_own_code_test_() ->
    {setup, fun setup/0, fun cleanup/1, fun() ->
        expect_player(#{}),
        ?assertEqual(
            {asobi_error, ~"ops.idempotency_key_required"},
            asobi_ops_write_controller:grant(
                req(#{json => #{~"currency" => ~"gold", ~"amount" => 5}})
            )
        )
    end}.

response_maps_a_field_error_to_422_test_() ->
    {setup, fun setup/0, fun cleanup/1, fun() ->
        expect_insert(),
        Params = maps:put(~"rarity", ~"mythic", item_params()),
        ?assertMatch(
            {asobi_error, ~"validation_failed", #{fields := #{rarity := _}}},
            asobi_ops_write_controller:create_item(req(#{json => Params}))
        )
    end}.

%% A malformed id must not reach Postgres, which raises on it.
response_rejects_a_malformed_binding_test() ->
    ?assertEqual(
        {asobi_error, ~"ops.invalid_id"},
        asobi_ops_write_controller:ban(req(#{bindings => #{~"id" => ~"'; drop table players --"}}))
    ).

response_rejects_a_body_that_is_not_an_object_test() ->
    ?assertEqual(
        {asobi_error, ~"ops.invalid_body"},
        asobi_ops_write_controller:create_item(req(#{json => [1, 2, 3]}))
    ).

%% The security callback already denies an unresolved actor, so this is the
%% belt to that braces: a mis-mounted route must not turn into an unattributed
%% mutation.
response_without_an_actor_is_forbidden_test() ->
    ?assertEqual(
        {asobi_error, ~"forbidden"},
        asobi_ops_write_controller:create_item(maps:remove(auth_data, req(#{})))
    ).

%%--------------------------------------------------------------------
%% Fixtures
%%--------------------------------------------------------------------

%% `asobi_repo`, `asobi_economy` and `nova_auth_refresh` are mocked;
%% `m:asobi_presence` is not. `meck:new/2` purges and reloads its target, and
%% purging a module a live gen_server is executing kills that process.
%%
%% This fixture also starts no process the rest of the node shares, and stops
%% none. It briefly did both for `m:asobi_auth_cache` and the result was four
%% *unrelated* fixtures cancelled at the far end of the eunit run - zero
%% failures, so the only sign was a count. `pg:start/1` is the exception and
%% is safe because it is unlinked, started only when absent, and never
%% stopped, which is what every other fixture that needs `pg` already does.
setup() ->
    ensure_pg(),
    meck:new(asobi_repo, [passthrough]),
    meck:new(nova_auth_refresh, [passthrough]),
    meck:expect(asobi_repo, insert, fun(CS) -> inserted(CS) end),
    meck:expect(nova_auth_refresh, revoke_all, fun(_Mod, _Id) -> ok end),
    ok.

cleanup(_) ->
    [catch meck:unload(M) || M <- [asobi_repo, nova_auth_refresh]],
    catch pg:leave(?PG_SCOPE, {player, ?PLAYER_ID}, self()),
    ok.

setup_grants() ->
    setup(),
    meck:new(asobi_economy, [passthrough]),
    ok.

cleanup_grants(_) ->
    catch meck:unload(asobi_economy),
    cleanup(ok).

ensure_pg() ->
    case whereis(?PG_SCOPE) of
        undefined -> {ok, _} = pg:start(?PG_SCOPE);
        _ -> ok
    end.

revocation() ->
    receive
        {session_revoked, Reason} -> Reason
    after 1000 -> timeout
    end.

%% The audit insert and the mutation's own insert both land here. They are
%% told apart by schema, so `audit_row/0` and `inserted_changeset/0` can each
%% pick out their own.
%%
%% An invalid changeset is refused the way `kura_repo_worker:do_insert/2`
%% refuses one: a mock that inserted anything handed to it would make every
%% schema validation in this file pass vacuously.
inserted(#kura_changeset{valid = false} = CS) ->
    {error, CS#kura_changeset{action = insert}};
inserted(#kura_changeset{data = Data, changes = Changes}) ->
    {ok, maps:merge(Data, Changes)}.

%% Inserts the mutation itself made. The audit row is an insert too, so a bare
%% call count would report "nothing was written" as 1.
writes() ->
    length([
        CS
     || {_, {asobi_repo, insert, [#kura_changeset{schema = Schema} = CS]}, _} <-
            meck:history(asobi_repo),
        Schema =/= asobi_ops_audit_entry
    ]).

audit_row() ->
    [Row | _] = [
        maps:merge(Data, Changes)
     || {_, {asobi_repo, insert, [#kura_changeset{schema = asobi_ops_audit_entry} = CS]}, _} <-
            meck:history(asobi_repo),
        #kura_changeset{data = Data, changes = Changes} <- [CS]
    ],
    Row.

inserted_changeset() ->
    [CS | _] = [
        CS
     || {_, {asobi_repo, insert, [#kura_changeset{schema = Schema} = CS]}, _} <-
            meck:history(asobi_repo),
        Schema =/= asobi_ops_audit_entry
    ],
    CS.

expect_player(Extra) ->
    meck:reset(asobi_repo),
    Player = maps:merge(#{id => ?PLAYER_ID, username => ~"kaito"}, Extra),
    meck:expect(asobi_repo, get, fun(asobi_player, _Id) -> {ok, Player} end),
    meck:expect(asobi_repo, insert, fun(CS) -> inserted(CS) end).

expect_update() ->
    meck:expect(asobi_repo, update, fun(CS) -> inserted(CS) end).

expect_insert() ->
    meck:reset(asobi_repo),
    meck:expect(asobi_repo, insert, fun(CS) -> inserted(CS) end).

updated_banned_at() ->
    [#kura_changeset{changes = Changes} | _] = [
        CS
     || {_, {asobi_repo, update, [CS]}, _} <- meck:history(asobi_repo)
    ],
    maps:get(banned_at, Changes, undefined).

actor() ->
    actor([read, player_data, config]).

actor(Caps) ->
    #{
        id => ~"static_secret",
        display => ~"kaito",
        source => static_secret,
        caps => Caps,
        attested => false
    }.

req(Extra) ->
    maps:merge(
        #{
            bindings => #{~"id" => ?PLAYER_ID},
            auth_data => #{ops_actor => actor()}
        },
        Extra
    ).

item_params() ->
    #{~"slug" => ~"potion", ~"name" => ~"Potion", ~"category" => ~"consumable"}.

listing_params() ->
    #{~"item_def_id" => ?ITEM_ID, ~"currency" => ~"gold", ~"price" => 10}.

tournament_params() ->
    #{
        ~"name" => ~"Spring Cup",
        ~"leaderboard_id" => ~"spring",
        ~"start_at" => ~"2026-09-01T00:00:00Z",
        ~"end_at" => ~"2026-09-02T00:00:00Z"
    }.
