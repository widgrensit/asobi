-module(asobi_player_erase).
-moduledoc """
Delete one player and everything core holds about them, in one transaction.

This is the single place core deletes a player. `m:asobi_guest_reaper` is one
caller of it, not the site itself, and the operator-facing route
(`POST /api/v1/ops/players/:id/erase`) is another.

## Why the child list is written out here

All 15 core foreign keys into `players.id` are `ON DELETE NO ACTION`, so the
player row cannot go until every child has. A blanket `ON DELETE CASCADE`
migration would be shorter and is deliberately refused: a database cascade
fires below this function's control flow, so `m:asobi_extension_erase` would
never run, and `iap_transactions` - real-money receipts - would be destroyed
silently. Enumerating the children in code is what makes the policy readable,
testable and auditable. It is also exactly what `guides/extensions.md` tells
extension authors to do, so core doing otherwise would be telling them one
thing and doing another.

## Delete, or sever

Two core tables are severed rather than deleted, and only two:

* `iap_transactions` - a purchase record outlives the account. A refund or
  chargeback dispute needs the provider transaction id, and statutory
  retention beats erasure for it. `asobi_transaction` is **not** this table:
  it is soft-currency bookkeeping keyed on `wallets`, and it goes with the
  wallet.
* `groups.creator_id` - deleting the group to free the key would destroy
  every other member's data.

Everything else is deleted outright. That *is* the anonymisation: every
player-referencing table stores a bare uuid and nothing else about the person,
so once `players` and `player_identities` are gone the surviving ids resolve to
nobody. A tombstone player row would be a record about a person who asked to be
erased, and it would still need a unique `username`.

Three columns hold ids with no foreign key at all, and each is left alone on
that argument rather than by oversight:

* `match_records.players` - a jsonb list of ids.
* `votes.votes_cast` - a jsonb object keyed by voter id, `#{VoterId =>
  OptionId}`. Same shape of argument, and it is exported (see
  `m:asobi_player_export`), so it is named here too.
* `zone_snapshots.entities` - opaque game-defined state. A game may key
  entities by player id, so this one is not core's to reason about; a game that
  puts personal data in it owns erasing it, which is what
  `c:asobi_extension:erase_player/1` is for.

## Atomic, never best-effort

One transaction, every result asserted, so a bare `{error, _}` becomes a
badmatch that raises and rolls the whole thing back. A half-finished erasure
that reports success is a worse answer to a deletion request than one that
fails loudly and can be retried - the argument
`c:asobi_extension:erase_player/1` already makes for extensions, applied to
core's own tables.

## The audit row commits with the erasure

ADR 0007's rule is that the audit runs after the mutation and never fails it.
Erasure is the stated exception: the data is gone by definition, so the audit
row is the only surviving evidence the request was honoured. It is written
inside the transaction through `asobi_ops_audit:record_strict/4`, and a failed
insert rolls the erasure back. `ops_audit_entries` carries no foreign key to
`players`, so the row outlives its own target by construction.

An automated retention sweep writes no rows - see `m:asobi_guest_reaper`.

## What the transaction cannot cover

Evicting the player from `m:asobi_auth_cache` and from every live
`m:asobi_leaderboard_server`, and killing the live session, run **after** the
commit, because an ETS eviction and a process exit cannot roll back. All are
idempotent, so a retry is safe. See `after_commit/1`.
""".

-include_lib("kernel/include/logger.hrl").
-include_lib("kura/include/kura.hrl").

-export([steps/1, after_commit/1, run/1, run/2]).

-define(ACTION, ~"players.erase").
-define(CLASS, erasure).
-define(TARGET_TYPE, ~"player").

-doc """
The delete sequence, with no transaction of its own.

For a caller that already holds one - `m:asobi_guest_reaper` does. Every
result is asserted, so a failure raises inside the caller's transaction and
rolls it back. Do not soften that into a `case`.
""".
-spec steps(binary()) -> ok | no_return().
steps(PlayerId) ->
    %% Extensions first, so an erase path can still read the player's core rows.
    ok = asobi_extension_erase:run(PlayerId),

    {ok, _} = asobi_repo:update_all(by(asobi_iap_transaction, player_id, PlayerId), #{
        player_id => null
    }),
    {ok, _} = asobi_repo:update_all(by(asobi_group, creator_id, PlayerId), #{creator_id => null}),

    %% Ledger before wallet: `transactions` foreign-keys `wallets`, not
    %% `players`, so it is invisible to a player-id sweep and holds the wallet
    %% down.
    {ok, _} = asobi_repo:delete_all(wallet_transactions(PlayerId)),
    {ok, _} = asobi_repo:delete_all(by(asobi_wallet, player_id, PlayerId)),

    {ok, _} = asobi_repo:delete_all(by(asobi_player_item, player_id, PlayerId)),
    {ok, _} = asobi_repo:delete_all(by(asobi_storage, player_id, PlayerId)),
    {ok, _} = asobi_repo:delete_all(by(asobi_cloud_save, player_id, PlayerId)),
    {ok, _} = asobi_repo:delete_all(by(asobi_notification, player_id, PlayerId)),
    {ok, _} = asobi_repo:delete_all(by(asobi_leaderboard_entry, player_id, PlayerId)),
    {ok, _} = asobi_repo:delete_all(by(asobi_chat_message, sender_id, PlayerId)),
    {ok, _} = asobi_repo:delete_all(by(asobi_group_member, player_id, PlayerId)),
    {ok, _} = asobi_repo:delete_all(friendships(PlayerId)),
    {ok, _} = asobi_repo:delete_all(by(asobi_player_stats, player_id, PlayerId)),
    %% `player_tokens` keys players by `user_id`, not `player_id`.
    {ok, _} = asobi_repo:delete_all(by(asobi_player_token, user_id, PlayerId)),
    {ok, _} = asobi_repo:delete_all(by(asobi_player_identity, player_id, PlayerId)),

    delete_player(PlayerId).

-doc """
Erase `PlayerId` from an Erlang shell, and audit it as the node's own action.

The floor a self-hoster has to be able to stand on: a release, a remote shell,
and no console, no operator secret and no cloud. There is no capability check
because there is nothing here to check - a caller holding a shell on the node
could call `asobi_repo:delete_all/1` directly. Capabilities guard the network
surface; see `run/2`.
""".
-spec run(binary()) -> {ok, map()} | {error, term()}.
run(PlayerId) when is_binary(PlayerId) ->
    erase_player(PlayerId, shell_actor()).

-doc """
Erase `PlayerId` on behalf of an ops actor.

Checks the `erasure` capability class in-function, the way ADR 0007's
core-wrapped mutations do, because the class is checked once in
`m:asobi_ops_caps` whichever entry point the caller reached. A refusal is
audited too: a denied attempt to erase somebody is worth a row.
""".
-spec run(binary(), asobi_ops_auth:actor()) -> {ok, map()} | {error, forbidden | term()}.
run(PlayerId, #{caps := Caps} = Actor) when is_binary(PlayerId) ->
    case asobi_ops_caps:authorised(?CLASS, Caps) of
        true ->
            erase_player(PlayerId, Actor);
        false ->
            asobi_ops_audit:record(Actor, ?ACTION, {?TARGET_TYPE, PlayerId}, {error, forbidden}),
            {error, forbidden}
    end.

%% --- Internal ---

-spec erase_player(binary(), asobi_ops_auth:actor()) -> {ok, map()} | {error, term()}.
erase_player(PlayerId, Actor) ->
    try asobi_repo:transaction(fun() -> erase_txn(PlayerId, Actor) end) of
        {ok, Summary} ->
            after_commit(PlayerId),
            {ok, Summary};
        {error, _Reason} = Error ->
            Error;
        Other ->
            ?LOG_ERROR(#{
                msg => ~"player erase returned outside the contract",
                player_id => PlayerId,
                returned => Other
            }),
            {error, {unexpected, Other}}
    catch
        Class:Reason:Stacktrace ->
            ?LOG_ERROR(#{
                msg => ~"player erase rolled back",
                player_id => PlayerId,
                class => Class,
                reason => Reason,
                stacktrace => Stacktrace
            }),
            {error, {Class, Reason}}
    end.

%% `not_found` is returned rather than raised: nothing has been written at that
%% point, so there is nothing to roll back, and a commit of no statements is
%% the honest outcome.
%%
%% A lookup that failed is not a player that does not exist. Reporting the
%% second for the first tells an operator answering a deletion request that
%% there is nobody to delete, when the truth is that the node could not find
%% out - so it gets its own reason and the caller's 500 path.
-spec erase_txn(binary(), asobi_ops_auth:actor()) ->
    {ok, map()} | {error, not_found | {lookup_failed, term()}}.
erase_txn(PlayerId, Actor) ->
    case asobi_repo:get(asobi_player, PlayerId) of
        {ok, _Player} ->
            ok = steps(PlayerId),
            ok = asobi_ops_audit:record_strict(
                Actor, ?ACTION, {?TARGET_TYPE, PlayerId}, {ok, [PlayerId], []}
            ),
            {ok, #{player_id => PlayerId, erased => true}};
        {error, not_found} ->
            {error, not_found};
        {error, Reason} ->
            {error, {lookup_failed, Reason}}
    end.

-doc """
The in-memory surfaces the transaction cannot cover, run after it commits.

An ETS eviction and a process exit cannot roll back, so none of these may run
before the commit. `run/1,2` call this for you; a caller that holds its own
transaction - `m:asobi_guest_reaper` - calls it once that transaction has
committed.

* `m:asobi_auth_cache` - without it a deleted player's access token keeps
  resolving for up to `auth_cache_ttl_ms` against a row that no longer exists,
  which is the revocation SLA that module's moduledoc already states.
* `m:asobi_leaderboard_server` - each board keeps its entries in ETS and reads
  from there, hydrating from Postgres only at init. Deleting the rows does not
  take an erased player off a board that is already running, and a score still
  pending for them re-inserts against a foreign key that is now gone. See
  `asobi_leaderboard_server:evict_player/1`.
* The live session.

All three are idempotent, so a retried erasure is safe.
""".
-spec after_commit(binary()) -> ok.
after_commit(PlayerId) ->
    ok = asobi_auth_cache:revoke_player(PlayerId),
    ok = asobi_leaderboard_server:evict_player(PlayerId),
    ok = asobi_presence:disconnect(PlayerId, ~"erased").

%% A player row already gone is `ok`: the children have still been cleaned, and
%% a retried erasure must not fail on the half it already finished.
%%
%% `not_found` only. Any other `{error, _}` is the lookup failing, not the row
%% being absent, and treating the two alike is how this function would commit
%% every child delete with the `players` row still there - the half-erased
%% player that reports success this module exists to make impossible. It raises
%% instead, which is what rolls the transaction back.
-spec delete_player(binary()) -> ok | no_return().
delete_player(PlayerId) ->
    case asobi_repo:get(asobi_player, PlayerId) of
        {ok, Player} ->
            {ok, _} = asobi_repo:delete(asobi_player, Player),
            ok;
        {error, not_found} ->
            ok;
        {error, Reason} ->
            error({asobi_player_erase, {lookup_failed, PlayerId, Reason}})
    end.

-spec by(module(), atom(), binary()) -> #kura_query{}.
by(Schema, Field, PlayerId) ->
    kura_query:where(kura_query:from(Schema), {Field, PlayerId}).

%% One table, two columns pointing at the same player.
-spec friendships(binary()) -> #kura_query{}.
friendships(PlayerId) ->
    kura_query:where(
        kura_query:from(asobi_friendship),
        {'or', [{player_id, PlayerId}, {friend_id, PlayerId}]}
    ).

%% A subquery rather than a read-then-`in`: an empty id list would compile to
%% `IN ()`, which Postgres rejects.
-spec wallet_transactions(binary()) -> #kura_query{}.
wallet_transactions(PlayerId) ->
    Wallets = kura_query:select(by(asobi_wallet, player_id, PlayerId), [id]),
    kura_query:where(kura_query:from(asobi_transaction), {wallet_id, in, {subquery, Wallets}}).

%% The node itself, named as such. `source` is what tells an auditor months
%% later that this row came from a shell on the box rather than from the ops
%% plane, and `attested => false` because nothing here proves who typed it.
-spec shell_actor() -> asobi_ops_auth:actor().
shell_actor() ->
    #{
        id => ~"shell",
        display => ~"shell",
        source => shell,
        caps => asobi_ops_caps:class_names(),
        attested => false
    }.
