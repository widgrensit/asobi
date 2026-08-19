-module(asobi_guest_purge_SUITE).
-moduledoc """
The purge against a real database.

`asobi_guest_purge_tests` asserts the SQL this module builds. Whether Postgres
accepts it, and whether the set it selects is the set the guides promise, is
only answerable here: the predicate is two correlated subqueries over a table
`asobi_repo` never joins anywhere else, and a mecked repo would agree with
whatever it was told.
""".

-include_lib("nova_test/include/nova_test.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([
    purges_an_abandoned_guest/1,
    spares_a_guest_seen_since_the_cutoff/1,
    spares_a_claimed_account/1,
    zero_seconds_takes_every_unclaimed_guest/1,
    count_agrees_with_what_run_deletes/1,
    limit_bounds_one_call_and_remaining_says_so/1,
    a_blocked_erase_is_failed_not_skipped/1,
    the_cohort_size_has_to_be_echoed_back/1
]).

all() ->
    [
        purges_an_abandoned_guest,
        spares_a_guest_seen_since_the_cutoff,
        spares_a_claimed_account,
        zero_seconds_takes_every_unclaimed_guest,
        count_agrees_with_what_run_deletes,
        limit_bounds_one_call_and_remaining_says_so,
        a_blocked_erase_is_failed_not_skipped,
        the_cohort_size_has_to_be_echoed_back
    ].

%% Guest auth is set before the app starts, the way an operator's sys.config
%% would have it (ADR 0014).
%%
%% `guest_reap_after` is deliberately NOT set. This is the on-demand half of
%% retention, and it has to work on a deployment that never configured the
%% automatic half - which is the deployment that accumulates the guests in the
%% first place. A stray background sweep would also delete the fixtures out
%% from under these tests and make them pass for the wrong reason.
init_per_suite(Config0) ->
    application:set_env(asobi, guest_auth, true),
    application:set_env(asobi, guest_verifier_pepper, crypto:strong_rand_bytes(32)),
    application:unset_env(asobi, guest_reap_after),
    asobi_test_helpers:start(Config0).

%% Nothing resets the operator layer any more, so the suite that set it clears
%% it - see `asobi_guest_SUITE:end_per_suite/1`.
end_per_suite(Config) ->
    application:unset_env(asobi, guest_auth),
    application:unset_env(asobi, guest_verifier_pepper),
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

guest(Config) ->
    {ok, Response} = create(device_id(), secret(), Config),
    ?assertStatus(200, Response),
    #{~"player_id" := PlayerId} = nova_test:json(Response),
    PlayerId.

%% Age the identity rather than sleeping past the cutoff - the same wall-clock
%% race `asobi_guest_SUITE:age_identity/1` exists to avoid.
age_identity(PlayerId) ->
    Ancient = {{2020, 1, 1}, {0, 0, 0}},
    {ok, 1} = asobi_repo:update_all(
        kura_query:where(kura_query:from(asobi_player_identity), {player_id, PlayerId}),
        #{inserted_at => Ancient, updated_at => Ancient}
    ),
    ok.

actor() ->
    asobi_ops_auth:subject_actor(~"suite").

purge(Seconds, Limit) ->
    asobi_guest_purge:run(asobi_guest_purge:cutoff(Seconds), Limit, 0, actor()).

exists(PlayerId) ->
    case asobi_repo:get(asobi_player, PlayerId) of
        {ok, _} -> true;
        {error, not_found} -> false
    end.

%% --- Tests ---

%% The whole point: a device that signed in once and never came back.
purges_an_abandoned_guest(Config) ->
    PlayerId = guest(Config),
    age_identity(PlayerId),
    {ok, #{deleted := Deleted}} = purge(3600, 100),
    ?assert(Deleted >= 1),
    ?assertNot(exists(PlayerId)),
    %% The identity goes with the player, which is why the next presentation of
    %% the same device pair mints a new account rather than resuming this one.
    ?assertEqual(
        {ok, 0},
        asobi_repo:aggregate(
            kura_query:where(kura_query:from(asobi_player_identity), {player_id, PlayerId}), count
        )
    ),
    Config.

%% The cutoff reads last-seen, so a guest who is still playing survives however
%% long ago they first launched. Keyed on `inserted_at` instead, this deletes
%% an active player.
spares_a_guest_seen_since_the_cutoff(Config) ->
    Dev = device_id(),
    Secret = secret(),
    {ok, R1} = create(Dev, Secret, Config),
    ?assertStatus(200, R1),
    #{~"player_id" := PlayerId} = nova_test:json(R1),
    age_identity(PlayerId),

    %% Same device, same secret: a resume, which touches the identity row.
    {ok, R2} = create(Dev, Secret, Config),
    ?assertStatus(200, R2),
    ?assertEqual(#{~"player_id" => PlayerId}, maps:with([~"player_id"], nova_test:json(R2))),

    {ok, _} = purge(3600, 100),
    ?assert(exists(PlayerId)),

    %% And the purge still works on the same row once it does fall idle, so
    %% this cannot pass by the purge being broken outright.
    age_identity(PlayerId),
    {ok, _} = purge(3600, 100),
    ?assertNot(exists(PlayerId)),
    Config.

%% A guest who claimed their account has a password and no guest identity. Both
%% halves of the predicate reject them, and deleting one would be silent loss
%% of a real account.
spares_a_claimed_account(Config) ->
    Dev = device_id(),
    Secret = secret(),
    {ok, R1} = create(Dev, Secret, Config),
    #{~"player_id" := PlayerId, ~"access_token" := Token} = nova_test:json(R1),
    age_identity(PlayerId),

    {ok, R2} = nova_test:post(
        "/api/v1/auth/guest/upgrade",
        #{
            json => #{~"username" => asobi_id:rand_suffix(12), ~"password" => ~"pass12345"},
            headers => [{~"authorization", <<"Bearer ", Token/binary>>}]
        },
        Config
    ),
    ?assertStatus(200, R2),

    {ok, _} = purge(0, 100),
    ?assert(exists(PlayerId)),
    Config.

%% "Clear all guest users": no cutoff at all, including the one that signed in
%% a moment ago and was never aged.
zero_seconds_takes_every_unclaimed_guest(Config) ->
    Fresh = guest(Config),
    Old = guest(Config),
    age_identity(Old),
    {ok, _} = purge(0, 1000),
    ?assertNot(exists(Fresh)),
    ?assertNot(exists(Old)),
    Config.

%% The preview has to describe the delete, or an operator confirms a number
%% that means nothing.
count_agrees_with_what_run_deletes(Config) ->
    {ok, _} = purge(0, 1000),
    Ids = [guest(Config) || _ <- lists:seq(1, 3)],
    [age_identity(Id) || Id <- Ids],

    Cutoff = asobi_guest_purge:cutoff(3600),
    ?assertEqual({ok, 3}, asobi_guest_purge:count(Cutoff)),
    {ok, #{deleted := 3, skipped := 0}} = asobi_guest_purge:run(Cutoff, 1000, 3, actor()),
    ?assertEqual({ok, 0}, asobi_guest_purge:count(Cutoff)),
    Config.

%% One call is bounded, and what is left is the caller's cue to call again
%% rather than a request held open across the whole table.
limit_bounds_one_call_and_remaining_says_so(Config) ->
    {ok, _} = purge(0, 1000),
    Ids = [guest(Config) || _ <- lists:seq(1, 4)],
    [age_identity(Id) || Id <- Ids],

    Cutoff = asobi_guest_purge:cutoff(3600),
    ?assertEqual({ok, 4}, asobi_guest_purge:count(Cutoff)),
    {ok, #{deleted := 2}} = asobi_guest_purge:run(Cutoff, 2, 4, actor()),
    ?assertEqual({ok, 2}, asobi_guest_purge:count(Cutoff)),
    {ok, #{deleted := 2}} = asobi_guest_purge:run(Cutoff, 2, 2, actor()),
    ?assertEqual({ok, 0}, asobi_guest_purge:count(Cutoff)),
    Config.

%% A guest the erase cannot delete is `failed`, and the distinction is the
%% whole reason the two counts are separate. Collapsed into `skipped`, a cohort
%% that CANNOT be erased reads exactly like a cohort that did not need erasing,
%% and the caller loops forever: the player never leaves the set, so `remaining`
%% never falls, so "repeat until remaining reaches 0" does not terminate.
a_blocked_erase_is_failed_not_skipped(Config) ->
    {ok, _} = purge(0, 1000),
    Blocked = guest(Config),
    Clear = guest(Config),
    age_identity(Blocked),
    age_identity(Clear),
    blocking_table(Blocked),

    Cutoff = asobi_guest_purge:cutoff(3600),
    ?assertEqual({ok, 2}, asobi_guest_purge:count(Cutoff)),
    ?assertMatch(
        {ok, #{deleted := 1, skipped := 0, failed := 1}},
        asobi_guest_purge:run(Cutoff, 100, 2, actor())
    ),
    ?assert(exists(Blocked)),
    ?assertNot(exists(Clear)),

    %% Still in the set, and a second call makes no progress on it. This is the
    %% loop that used to have no exit, so the contract is "call again while
    %% `deleted` is above zero", not "until nothing is left".
    ?assertEqual({ok, 1}, asobi_guest_purge:count(Cutoff)),
    ?assertMatch(
        {ok, #{deleted := 0, skipped := 0, failed := 1}},
        asobi_guest_purge:run(Cutoff, 100, 1, actor())
    ),

    unblock(),
    Config.

%% An extension-owned table core knows nothing about, holding a row that
%% references the player without `ON DELETE CASCADE` - the orphaned-rows case
%% `asobi_player_erase:orphan_blocker/1` classifies, reproduced rather than
%% simulated so the failure arrives through the same 23503 the real one does.
blocking_table(PlayerId) ->
    _ = kura_db:query(
        asobi_repo,
        ~"CREATE TABLE IF NOT EXISTS purge_suite_ext_rows (player_id UUID PRIMARY KEY REFERENCES players (id))",
        []
    ),
    _ = kura_db:query(
        asobi_repo, ~"INSERT INTO purge_suite_ext_rows (player_id) VALUES ($1)", [PlayerId]
    ),
    ok.

unblock() ->
    _ = kura_db:query(asobi_repo, ~"DROP TABLE IF EXISTS purge_suite_ext_rows", []),
    ok.

%% Erasing one player has to echo that player's username. Erasing a cohort has
%% to echo its size, or the call with the larger blast radius would be the one
%% an unattended POST could make.
the_cohort_size_has_to_be_echoed_back(Config) ->
    {ok, _} = purge(0, 1000),
    Id = guest(Config),
    age_identity(Id),
    Cutoff = #{~"inactive_for_seconds" => 3600},

    ?assertMatch(
        {asobi_error, ~"ops.confirmation_required", _},
        asobi_ops_controller:purge_guests(req(Cutoff))
    ),
    ?assert(exists(Id)),

    %% The dry run is exempt, because it is where the count comes from.
    ?assertMatch(
        {json, #{data := #{matched := 1, deleted := 0, dry_run := true}}},
        asobi_ops_controller:purge_guests(req(Cutoff#{~"dry_run" => true}))
    ),
    ?assert(exists(Id)),

    %% A wrong count is a mismatch, which is a different answer from sending none.
    ?assertMatch(
        {asobi_error, ~"ops.purge_count_mismatch", _},
        asobi_ops_controller:purge_guests(req(Cutoff#{~"confirm_count" => 99}))
    ),
    ?assert(exists(Id)),

    ?assertMatch(
        {json, #{data := #{deleted := 1, skipped := 0, failed := 0, remaining := 0}}},
        asobi_ops_controller:purge_guests(req(Cutoff#{~"confirm_count" => 1}))
    ),
    ?assertNot(exists(Id)),
    Config.

req(Json) ->
    #{auth_data => #{ops_actor => actor()}, json => Json}.
