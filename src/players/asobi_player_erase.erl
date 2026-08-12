-module(asobi_player_erase).
-moduledoc """
Delete one player and everything core holds about them, in one transaction.

This is the single place core deletes a player. `steps/1` is the delete
sequence; three callers reach it, each wrapping its own transaction:

* `run/1,2` here - the shell and the operator route
  (`POST /api/v1/ops/players/:id/erase`);
* `m:asobi_guest_reaper` - the retention sweep;
* `asobi_player_controller:erase_self/1` - the data subject's own
  `POST /api/v1/players/me/erase`.

All three route a rolled-back erasure through `orphan_blocker/1` so a removed
extension's rows are named rather than surfaced as a bare constraint error.

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

## Rows a removed extension leaves behind

Core clears its own children and each *installed* extension's `erase_player/1`
clears the extension's. A package that has been **removed** runs neither: its
tables and rows survive the uninstall, its foreign key into `players.id` is
still `no_action`, and the parent delete this function ends on raises against
them. Rather than surface that as a bare `{badmatch, {pgsql_error, ...}}`, the
delete sequence is wrapped so a `foreign_key_violation` (SQLSTATE 23503)
becomes `{error, {orphaned_extension_rows, Table}}` - `Table` is the referencing
table the absent package owns, read from the Postgres error. The player is not
erased, the transaction rolls back cleanly, and the operator learns which
package to reinstall or purge instead of reading a constraint name off a
stacktrace. `guides/extensions.md` documents the rule where it bites.

The translation is **narrow**: only a 23503 naming a table *outside*
`core_relations/0` - the set `steps/1` itself sweeps, plus `players` and the
ops audit table - reads as extension residue. A 23503 naming a core-swept
table, or one carrying no table name, is a core bug or a write-race, not a
removed package; those keep the raw reason and surface as
`ops.erase_failed` (500), which is the escalate signal, never the benign
"reinstall the package" 409.

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

Those post-commit surfaces split two ways. Revoking the auth cache and killing
the session are core's own session/identity teardown for the player it just
deleted - kernel work erase owns and will always own. Taking the player off a
running leaderboard is a *subsystem* cleaning up its own in-memory state, and
core should not name a subsystem's internals at its own call site. So the
leaderboard eviction runs through a registry, `post_erase_hooks/0`, one
`{Module, Function}` per subsystem that needs post-commit cleanup, invoked
best-effort in list order. When leaderboards extracts (Wave 2)
`post_erase_hooks/0` is reimplemented to walk the installed subsystems - the
same registry ratchet 3 introduces - rather than return this literal, so the
leaderboard entry is no longer named here; nothing re-registers itself into a
list. The registry stays core-internal until then, deliberately off the public
`m:asobi_extension` behaviour, which is a separate contract decision.
""".

-include_lib("kernel/include/logger.hrl").
-include_lib("kura/include/kura.hrl").

-export([steps/1, after_commit/1, run/1, run/2, orphan_blocker/1, core_relations/0]).
-export([post_erase_hooks/0]).

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
        {ok, Summary} when is_map(Summary) ->
            %% Not bare `after_commit(PlayerId)`: an exception raised in a
            %% `try ... of` body escapes the `catch` below. `after_commit/1`
            %% isolates each post-commit hook, so a subsystem's failure is
            %% already logged and swallowed there; wrapping the whole call is
            %% the belt that keeps a raise from the orchestration itself off the
            %% result of an erasure that had already committed. The rows are
            %% gone by this point, so a failed hook is a thing to log and retry
            %% by hand, never a reason to report failure.
            after_commit_best_effort(PlayerId),
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
            rolled_back(PlayerId, Class, Reason, Stacktrace)
    end.

%% A foreign_key_violation that survives the whole delete sequence is a table
%% core does not sweep - a removed extension's rows. Name it; everything else
%% keeps the raw class/reason.
-spec rolled_back(binary(), atom(), term(), list()) -> {error, term()}.
rolled_back(PlayerId, Class, Reason, Stacktrace) ->
    case orphan_blocker(Reason) of
        {orphaned_extension_rows, Table} = Orphaned ->
            ?LOG_ERROR(#{
                msg => ~"player erase blocked by orphaned extension rows",
                player_id => PlayerId,
                table => Table
            }),
            {error, Orphaned};
        not_orphaned ->
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
transaction - `m:asobi_guest_reaper` and `asobi_player_controller:erase_self/1`
- calls it once that transaction has committed.

Two kinds of work run here, and the split is deliberate:

* **Kernel teardown**, run directly. `m:asobi_auth_cache` - without it a
  deleted player's access token keeps resolving for up to `auth_cache_ttl_ms`
  against a row that no longer exists, which is the revocation SLA that
  module's moduledoc already states. The live session, killed through
  `m:asobi_presence`. Both are erase's own session/identity teardown for the
  player it just deleted; neither is a subsystem's concern and neither will
  ever extract, so core names them here rather than on the registry.
* **Subsystem cleanup**, run through `post_erase_hooks/0`. Today that is
  `m:asobi_leaderboard_server`: each board keeps its entries in ETS and reads
  from there, hydrating from Postgres only at init, so deleting the rows does
  not take an erased player off a board that is already running, and a score
  still pending for them re-inserts against a foreign key that is now gone. It
  is a subsystem cleaning up its own state, so it is a registered hook, not a
  call core spells out here.

Every step is idempotent, so a retried erasure is safe, and every step is
best-effort in isolation: one that raises is logged, naming the step, and
swallowed, so a wedged subsystem cannot stop another's cleanup or the kernel
teardown, and a committed erasure always stands.
""".
-spec after_commit(binary()) -> ok.
after_commit(PlayerId) ->
    %% Kernel teardown first, then the subsystem hooks, in list order - the
    %% whole sequence is deterministic. Each step is isolated so one failure
    %% never reaches the next.
    best_effort_step(PlayerId, {asobi_auth_cache, revoke_player}, fun() ->
        ok = asobi_auth_cache:revoke_player(PlayerId)
    end),
    best_effort_step(PlayerId, {asobi_presence, disconnect}, fun() ->
        ok = asobi_presence:disconnect(PlayerId, ~"erased")
    end),
    _ = [run_hook(PlayerId, Hook) || Hook <- post_erase_hooks()],
    ok.

-spec run_hook(binary(), {module(), atom()}) -> ok.
run_hook(PlayerId, {Module, Function} = Hook) ->
    best_effort_step(PlayerId, Hook, fun() -> ok = Module:Function(PlayerId) end).

-doc """
The subsystem cleanups to run after a player-erase commits, in order.

The seam. Each entry is one subsystem's post-commit cleanup of the player just
erased, invoked as `Module:Function(PlayerId)` by `after_commit/1`. It exists so
core does not name a subsystem's internals mid-`after_commit/1`: the one edge
that used to reach straight into `asobi_leaderboard_server:evict_player/1` is
now this single list entry. When leaderboards extracts (Wave 2) this function is
reimplemented to walk the installed subsystems - the same registry ratchet 3
introduces - rather than return a literal, so the leaderboard entry is no longer
named here. There is no extension-facing hook-registration API today and this is
not one; the registry is kept core-internal for now, off the public
`m:asobi_extension` behaviour, which is a separate contract decision.

Ordered and deterministic: hooks run top to bottom, after the kernel teardown.
""".
-spec post_erase_hooks() -> [{module(), atom()}].
post_erase_hooks() ->
    [
        {asobi_leaderboard_server, evict_player}
    ].

%% One post-commit step, best-effort. A raise is logged, naming the step, and
%% swallowed with `ok`, so the caller runs the next step regardless: the rows
%% are already gone, and one subsystem's failure must not block another's
%% cleanup or the kernel teardown. The `ok =` inside each step's fun still holds
%% - a step that answers anything else raises a badmatch, which is caught here.
-spec best_effort_step(binary(), {module(), atom()}, fun(() -> ok)) -> ok.
best_effort_step(PlayerId, Step, Fun) ->
    try
        Fun(),
        ok
    catch
        Class:Reason:Stacktrace ->
            ?LOG_ERROR(#{
                msg => ~"player erase committed but a post-commit step failed",
                player_id => PlayerId,
                step => Step,
                class => Class,
                reason => Reason,
                stacktrace => Stacktrace
            }),
            ok
    end.

-spec after_commit_best_effort(binary()) -> ok.
after_commit_best_effort(PlayerId) ->
    try
        after_commit(PlayerId)
    catch
        Class:Reason:Stacktrace ->
            ?LOG_ERROR(#{
                msg => ~"player erase committed but post-commit orchestration failed",
                player_id => PlayerId,
                class => Class,
                reason => Reason,
                stacktrace => Stacktrace
            }),
            ok
    end.

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

-doc """
Classify an exception raised inside the erase transaction.

`{orphaned_extension_rows, Table}` only when the failure was a Postgres
`foreign_key_violation` (SQLSTATE 23503) naming a table **outside**
`core_relations/0`. Core clears every child it owns before deleting `players`,
so a foreign key that still refuses the parent delete and names a table core
does not sweep belongs to a removed extension. A 23503 naming a core-swept
table (a bug or a write-race), or one carrying no table name, is `not_orphaned`
and keeps its raw reason so it escalates rather than reads as a benign removed
package. Every non-23503 failure is `not_orphaned` too. Exported for the other
callers of the delete sequence - `m:asobi_guest_reaper` and
`asobi_player_controller:erase_self/1` - which wrap their own transaction.
""".
-spec orphan_blocker(term()) -> {orphaned_extension_rows, binary()} | not_orphaned.
orphan_blocker({badmatch, Inner}) ->
    orphan_blocker(Inner);
orphan_blocker({error, Inner}) ->
    orphan_blocker(Inner);
orphan_blocker({pgsql_error, Fields}) when is_map(Fields) ->
    orphan_from_fields(Fields);
orphan_blocker(_Other) ->
    not_orphaned.

-spec orphan_from_fields(map()) -> {orphaned_extension_rows, binary()} | not_orphaned.
orphan_from_fields(#{code := ~"23503", table := Table}) when is_binary(Table), Table =/= ~"" ->
    case is_core_relation(Table) of
        true -> not_orphaned;
        false -> {orphaned_extension_rows, Table}
    end;
orphan_from_fields(_Fields) ->
    not_orphaned.

-spec is_core_relation(binary()) -> boolean().
is_core_relation(Table) ->
    lists:member(Table, core_relations()).

-doc """
The Postgres relations `steps/1` clears, by their real table names.

The escalation boundary for `orphan_blocker/1`: a 23503 naming one of these is
a core defect or a write-race, not a removed extension. Derived from the schema
modules `steps/1` sweeps (`asobi_player:table/0` and friends give the real
relation name, which differs from the module name), plus the ops audit table
`asobi_ops_audit:record_strict/4` writes inside the same transaction. `players`
is already in the swept set. `asobi_player_erase_tests` fails if `steps/1` gains
a schema whose table is not covered here.
""".
-spec core_relations() -> [binary()].
core_relations() ->
    [Schema:table() || Schema <- swept_schemas()] ++ [asobi_ops_audit_entry:table()].

%% The schemas `steps/1` sweeps a player out of. Single source of truth for
%% `core_relations/0`; keep in step with `steps/1`.
-spec swept_schemas() -> [module()].
swept_schemas() ->
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
    ].
