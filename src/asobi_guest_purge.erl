-module(asobi_guest_purge).
-moduledoc """
Operator-initiated bulk erasure of unclaimed guests.

The automatic half of guest retention is `m:asobi_guest_reaper`: a background
sweep that runs only when the server sets `guest_reap_after`. This is the half
a person triggers, for the deployment that never configured retention and now
has a table full of abandoned devices, or the one that wants them gone now
rather than at the next tick.

Same predicate, same erasure, different trigger - and therefore a different
audit posture. A sweep writes no audit rows because it is the machine doing
housekeeping on a policy someone already set; a purge writes one, because here
a person asked. That is the split `m:asobi_player_erase` states, applied to the
bulk case.

## What counts as purgeable

An **unclaimed guest**: a player with no password, at least one `guest`
identity, and no identity of any other provider. Claiming a guest
(`/auth/guest/upgrade`) sets a password and deletes the guest identity, so a
claimed account fails the predicate twice over. Linking an OAuth provider fails
it once. Neither is reachable by this module.

The cutoff is read against the guest identity's `updated_at`, not the player's
and not `inserted_at`: guest sign-in touches that row, so it means *last seen*.
A cutoff of `0` seconds therefore means every unclaimed guest including the one
that signed in a moment ago, which is what "clear all guest users" asks for and
why the caller has to say it in so many words.

## Why the predicate is SQL and not `asobi_guest_reaper:unclaimed_guest/1`

The reaper answers that question one player at a time, which is right when it
is walking a bounded batch. Counting 14 000 of them that way is 28 000 queries
before a single row is deleted. `clause/1` is the same question as one
`WHERE`, so the preview a caller runs before a destructive call costs one
round trip.

The per-player function is still the authority at the moment of deletion:
`erase_one/1` re-checks it inside the transaction, so a guest that signs up for
a real account between the select and its own delete survives. The SQL is how
the set is chosen; the Erlang is how each member is confirmed.

## Bounded per call

`run/4` deletes at most `Limit` players and reports what is left, rather than
holding one request open across an unbounded table. A caller that wants the
whole set repeats the call until `remaining` reaches `0`.
""".

-include_lib("kernel/include/logger.hrl").
-include_lib("kura/include/kura.hrl").

-export([count/1, run/4, clause/1, cutoff/1]).
-export([default_limit/0, max_limit/0]).

-define(PROVIDER, ~"guest").
-define(ACTION, ~"players.purge_guests").
-define(TARGET_TYPE, ~"guest_cohort").
-define(DEFAULT_LIMIT, 500).
-define(MAX_LIMIT, 5000).

-type cutoff() :: calendar:datetime().
-type condition() :: {atom(), is_nil} | {fragment, binary(), [term()]}.
-type predicate() :: {'and', [condition()]}.

-export_type([cutoff/0, predicate/0]).

-doc "Default number of players one `run/4` erases when the caller names none.".
-spec default_limit() -> pos_integer().
default_limit() -> ?DEFAULT_LIMIT.

-doc "Ceiling on `Limit`, so one request cannot be asked to hold an unbounded delete.".
-spec max_limit() -> pos_integer().
max_limit() -> ?MAX_LIMIT.

-doc """
The cutoff `Seconds` of inactivity maps to, in UTC.

`0` is now, which selects every unclaimed guest.
""".
-spec cutoff(non_neg_integer()) -> cutoff().
cutoff(Seconds) when is_integer(Seconds), Seconds >= 0 ->
    Now = calendar:datetime_to_gregorian_seconds(erlang:universaltime()),
    calendar:gregorian_seconds_to_datetime(Now - Seconds).

-doc """
How many unclaimed guests are older than `Cutoff`.

The number a preview reports, and the number a caller compares against before
asking for the delete.
""".
-spec count(cutoff()) -> {ok, non_neg_integer()} | {error, term()}.
count(Cutoff) ->
    case asobi_repo:aggregate(matching(Cutoff), count) of
        {ok, N} when is_integer(N), N >= 0 -> {ok, N};
        {error, Reason} -> {error, Reason};
        Other -> {error, Other}
    end.

-doc """
Erase up to `Limit` unclaimed guests older than `Cutoff`, and audit the batch.

Returns the counts, never the ids: an operator page reports how many went, and
the ids that did are in the audit row for anyone who has to answer for it
later. A player whose in-transaction re-check now says "claimed" is counted
`skipped`, not `failed` - nothing went wrong, the answer changed.

One audit row per call, carrying every erased id as a subject, so a purge is
one entry an operator can point at rather than N entries they have to correlate.
""".
-spec run(cutoff(), pos_integer(), non_neg_integer(), asobi_ops_auth:actor()) ->
    {ok, #{deleted := non_neg_integer(), skipped := non_neg_integer()}} | {error, term()}.
run(Cutoff, Limit, Matched, Actor) when is_integer(Limit), Limit > 0 ->
    case candidates(Cutoff, min(Limit, ?MAX_LIMIT)) of
        {ok, Ids} ->
            {Erased, Skipped} = erase_each(Ids),
            audit(Erased, Skipped, Matched, Actor),
            {ok, #{deleted => length(Erased), skipped => length(Skipped)}};
        {error, Reason} ->
            {error, Reason}
    end.

-spec matching(cutoff() | undefined) -> #kura_query{}.
matching(Cutoff) ->
    kura_query:where(kura_query:from(asobi_player), clause(Cutoff)).

-doc """
The `WHERE` condition selecting every unclaimed guest last seen before `Cutoff`.

Exported because the ops player list narrows on the same definition, and two
places answering "is this a guest" differently is how a purge deletes a row an
operator was told was not in the set. `undefined` drops the cutoff and keeps
the rest, which is what a list filter wants.

Three conditions, and each one is load-bearing:

* no password - a claimed account is not a guest, and `/auth/guest/upgrade`
  sets one;
* a `guest` identity older than the cutoff - the row guest sign-in touches, so
  this reads as "not seen since", not "signed up before";
* no identity of any other provider - a guest who linked an OAuth account still
  has the guest identity, and deleting them would take a real account with it.

The subqueries are literal SQL because the alternative is a join, and a join
here is ambiguous: `kura` emits unqualified column names in `WHERE`, and both
tables carry `id` and `updated_at`. Correlated `EXISTS` keeps every column
unambiguous and keeps the row count at one row per player. The two table names
are the only literals; `asobi_guest_purge_tests` fails if either schema module
stops agreeing with them.
""".
-spec clause(cutoff() | undefined) -> predicate().
clause(undefined) ->
    {'and', [{hashed_password, is_nil}, guest_identity(), no_other_provider()]};
clause(Cutoff) ->
    {'and', [{hashed_password, is_nil}, guest_identity(Cutoff), no_other_provider()]}.

-spec guest_identity() -> condition().
guest_identity() ->
    {fragment,
        ~"EXISTS (SELECT 1 FROM \"player_identities\" WHERE \"player_identities\".\"player_id\" = \"players\".\"id\" AND \"player_identities\".\"provider\" = ?)",
        [?PROVIDER]}.

%% `<=`, not `<`, and the boundary is the whole point rather than a detail.
%% `erlang:universaltime/0` is whole seconds, so with a strict `<` a cutoff of
%% zero excludes every guest whose identity was written during the current
%% second - which is to say "clear all guest users" quietly spares the ones who
%% just arrived. Inclusive, the cutoff means "not seen since", and a row written
%% after it was measured is out of the set because it was not in it when the
%% set was measured, which is the honest answer.
-spec guest_identity(cutoff()) -> condition().
guest_identity(Cutoff) ->
    {fragment,
        ~"EXISTS (SELECT 1 FROM \"player_identities\" WHERE \"player_identities\".\"player_id\" = \"players\".\"id\" AND \"player_identities\".\"provider\" = ? AND \"player_identities\".\"updated_at\" <= ?)",
        [?PROVIDER, Cutoff]}.

-spec no_other_provider() -> condition().
no_other_provider() ->
    {fragment,
        ~"NOT EXISTS (SELECT 1 FROM \"player_identities\" WHERE \"player_identities\".\"player_id\" = \"players\".\"id\" AND \"player_identities\".\"provider\" <> ?)",
        [?PROVIDER]}.

-spec candidates(cutoff(), pos_integer()) -> {ok, [binary()]} | {error, term()}.
candidates(Cutoff, Limit) ->
    Q = kura_query:limit(kura_query:select(matching(Cutoff), [id]), Limit),
    case asobi_repo:all(Q) of
        {ok, Rows} -> {ok, [Id || #{id := Id} <- Rows, is_binary(Id)]};
        {error, Reason} -> {error, Reason}
    end.

-spec erase_each([binary()]) -> {[binary()], [binary()]}.
erase_each(Ids) ->
    Outcomes = [{Id, erase_one(Id)} || Id <- Ids],
    {[Id || {Id, erased} <- Outcomes], [Id || {Id, skipped} <- Outcomes]}.

%% One transaction per player, not one around the batch: a batch-wide
%% transaction would roll 500 erasures back because the 501st hit an
%% extension's orphaned rows, and it would hold write locks across the whole
%% cohort while it did. The re-check lives inside each transaction for the
%% reason `m:asobi_guest_reaper` gives - a concurrent upgrade must win.
-spec erase_one(binary()) -> erased | skipped.
erase_one(PlayerId) ->
    Fun = fun() ->
        case asobi_guest_reaper:unclaimed_guest(PlayerId) of
            false -> {error, claimed_during_purge};
            true -> asobi_player_erase:steps(PlayerId)
        end
    end,
    try asobi_repo:transaction(Fun) of
        ok ->
            asobi_player_erase:after_commit(PlayerId),
            erased;
        {error, Reason} ->
            ?LOG_DEBUG(#{event => guest_purge_skipped, player_id => PlayerId, reason => Reason}),
            skipped;
        Other ->
            ?LOG_WARNING(#{event => guest_purge_unexpected, player_id => PlayerId, result => Other}),
            skipped
    catch
        Class:Reason:Stacktrace ->
            log_failure(PlayerId, Class, Reason, Stacktrace),
            skipped
    end.

-spec log_failure(binary(), atom(), term(), erlang:stacktrace()) -> ok.
log_failure(PlayerId, Class, Reason, Stacktrace) ->
    case asobi_player_erase:orphan_blocker(Reason) of
        {orphaned_extension_rows, Table} ->
            ?LOG_WARNING(#{
                event => guest_purge_orphaned_extension_rows,
                player_id => PlayerId,
                table => Table
            });
        not_orphaned ->
            ?LOG_ERROR(#{
                event => guest_purge_rolled_back,
                player_id => PlayerId,
                class => Class,
                reason => Reason,
                stacktrace => Stacktrace
            })
    end,
    ok.

%% `record/4`, not `record_strict/4`. The single-player erase is strict because
%% it can still roll its own transaction back when the audit insert fails; here
%% the deletes have committed one by one and there is nothing left to undo, so
%% a strict failure would have no answer to give. The insert failing is loud in
%% the log either way - see `m:asobi_ops_audit` on why that trade is stated
%% rather than assumed.
-spec audit([binary()], [binary()], non_neg_integer(), asobi_ops_auth:actor()) -> ok.
audit(Erased, Skipped, Matched, Actor) ->
    asobi_ops_audit:record(
        Actor,
        ?ACTION,
        {?TARGET_TYPE, undefined},
        {ok, Erased, [{Id, claimed_during_purge} || Id <- Skipped]}
    ),
    ?LOG_INFO(#{
        event => guest_cohort_purged,
        deleted => length(Erased),
        skipped => length(Skipped),
        matched => Matched
    }),
    ok.
