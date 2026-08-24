-module(asobi_guest_reaper).
-behaviour(gen_server).

%% Opt-in sweeper for stale, unclaimed guest accounts. Retention is operator
%% policy, never a core default: a sweep does nothing unless guest auth is on
%% and `guest_reap_after` (a number of seconds) is configured, both read at
%% sweep time. "Permanent guests" = leave it unset. It only removes guests that
%% were never claimed - no password and no non-device identity - so an upgraded
%% account is never touched.
%%
%% Stale means INACTIVE, not old. The predicate is the guest identity's
%% `updated_at`, which `asobi_guest_controller` refreshes every time a device
%% resumes its player, so `guest_reap_after` reads as "not seen for N seconds".
%% Keying it on `inserted_at` instead would read as "created N seconds ago" and
%% delete a guest who has played daily since - an unclaimed account is the
%% normal steady state for device auth, not a sign of abandonment, so account
%% age says nothing about whether anyone is still using it. That distinction is
%% load-bearing now that the cascade actually completes: it used to delete four
%% of the fifteen FK children, so any guest with a wallet or a cloud save hit a
%% constraint violation and was logged skipped, and the wrong predicate stayed
%% inert. Erasure is permanent and writes no audit row, so the predicate has to
%% mean what the guides say it means.
%%
%% `updated_at` is already NOT NULL on every existing row, so the sweep is
%% correct from the first tick with no backfill. Any future writer of the
%% identity row also extends retention, which is the safe direction: this
%% predicate can only ever spare a guest it should have reaped, never reap one
%% it should have spared.
%%
%% The deletion itself belongs to `asobi_player_erase`; this module owns guest
%% retention policy and nothing else. That split is why the in-transaction
%% unclaimed re-check stays here: it is a statement about which guests may be
%% reaped, not about how a player is erased.
%%
%% A sweep writes no audit rows. It is an automated retention pass over up to
%% ?REAP_BATCH accounts at a time, so a row per player would flood
%% `ops_audit_entries` with the machine's own housekeeping; the sweep logs a
%% count instead. Operator-initiated erasure - `asobi_player_erase:run/1,2` -
%% audits, because there a person asked.

-export([start_link/0, sweep_now/0, cached_unlinked_count/0, unclaimed_guest/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-include_lib("kernel/include/logger.hrl").
-include_lib("kura/include/kura.hrl").

-define(PROVIDER, ~"guest").
-define(DEFAULT_INTERVAL_MS, 3600000).
-define(REAP_BATCH, 500).
-define(COUNT_CACHE, asobi_guest_count_cache).
-define(DEFAULT_COUNT_TTL_MS, 2000).

%% Always started; `guest_auth` is read when a sweep runs, not here (asobi#327).
%% Gating the start on the flag made this a permanent child that returned
%% `ignore`, which a supervisor skips and never retries - and every writer of
%% guest_auth lives in an application that starts after asobi, so the flag was
%% always false at that moment and the reaper never ran at all. Reading it
%% lazily also self-corrects when the flag is set later, e.g. a bundle reload.
-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    case gen_server:start_link({local, ?MODULE}, ?MODULE, [], []) of
        {ok, Pid} when is_pid(Pid) -> {ok, Pid};
        {error, _} = Error -> Error
    end.

%% For tests/ops: run a sweep synchronously.
-spec sweep_now() -> {ok, non_neg_integer()}.
sweep_now() ->
    case gen_server:call(?MODULE, sweep, 30000) of
        {ok, N} when is_integer(N), N >= 0 -> {ok, N}
    end.

-spec init([]) -> {ok, map()}.
init([]) ->
    _ = ensure_count_cache(),
    schedule(),
    {ok, #{}}.

%% Short-TTL cache of the unlinked-guest count, read by the create path's cap
%% check so an unauthenticated create storm can't turn the guard into a
%% full-table COUNT per request. Public table (request processes read/refresh
%% it); created here so it shares the reaper's lifetime.
-spec ensure_count_cache() -> ets:table().
ensure_count_cache() ->
    case ets:whereis(?COUNT_CACHE) of
        undefined ->
            ets:new(?COUNT_CACHE, [
                named_table, public, set, {read_concurrency, true}, {write_concurrency, true}
            ]);
        Tid ->
            Tid
    end.

%% Read the cached count, refreshing on miss/expiry. Falls back to a live count
%% (uncached) if the table isn't up yet, so it is safe to call before the reaper
%% has started. Returns `unknown` on a query failure so the caller fails closed.
-spec cached_unlinked_count() -> non_neg_integer() | unknown.
cached_unlinked_count() ->
    Now = erlang:monotonic_time(millisecond),
    case ets:whereis(?COUNT_CACHE) of
        undefined ->
            live_unlinked_count();
        _ ->
            case ets:lookup(?COUNT_CACHE, count) of
                %% `unknown` is a cached FAILURE, and caching it is the point:
                %% asobi_guest_SUITE asserts a failing count is asked once per
                %% TTL, not once per call. is_integer/1 alone rejected it and
                %% re-queried every time.
                [{count, N, Expiry}] when Expiry > Now, is_integer(N) orelse N =:= unknown -> N;
                _ -> refresh_count(Now)
            end
    end.

%% A failed count is cached for the same TTL as a good one, and that is
%% deliberate. `unknown` fails the create closed, so without caching it every
%% single guest create re-runs a COUNT that is already failing - against a
%% database that is, by construction, the thing having trouble. Caching the
%% failure bounds the load on it to one attempt per TTL, and bounds the log
%% volume to the same.
-spec refresh_count(integer()) -> non_neg_integer() | unknown.
refresh_count(Now) ->
    Ttl =
        case application:get_env(asobi, guest_unlinked_count_ttl_ms, ?DEFAULT_COUNT_TTL_MS) of
            T when is_integer(T) -> T;
            _ -> ?DEFAULT_COUNT_TTL_MS
        end,
    Count = live_unlinked_count(),
    true = ets:insert(?COUNT_CACHE, {count, Count, Now + Ttl}),
    Count.

%% Answers `unknown` on any failure so the caller fails closed - and says why.
%%
%% This used to swallow the reason with a bare `_ -> unknown`, which made the
%% failure undiagnosable from the node: `asobi_guest_controller` could report
%% that it had been unable to count, but nothing anywhere said what the
%% database had actually answered. That gap cost a real investigation
%% (asobi#419), so the result is logged.
-spec live_unlinked_count() -> non_neg_integer() | unknown.
live_unlinked_count() ->
    Q = kura_query:where(kura_query:from(asobi_player_identity), {provider, ?PROVIDER}),
    case asobi_repo:aggregate(Q, count) of
        {ok, N} when is_integer(N), N >= 0 ->
            N;
        Other ->
            ?LOG_WARNING(#{event => guest_count_failed, result => Other}),
            unknown
    end.

-spec handle_call(term(), gen_server:from(), map()) -> {reply, term(), map()}.
handle_call(sweep, _From, State) ->
    {reply, {ok, run_sweep()}, State};
handle_call(_Req, _From, State) ->
    {reply, ok, State}.

-spec handle_cast(term(), map()) -> {noreply, map()}.
handle_cast(_Msg, State) ->
    {noreply, State}.

-spec handle_info(term(), map()) -> {noreply, map()}.
handle_info(sweep, State) ->
    _ = run_sweep(),
    schedule(),
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

%% --- Internal ---

-spec schedule() -> reference().
schedule() ->
    Interval =
        case application:get_env(asobi, guest_reap_interval_ms, ?DEFAULT_INTERVAL_MS) of
            I when is_integer(I) -> I;
            _ -> ?DEFAULT_INTERVAL_MS
        end,
    erlang:send_after(Interval, self(), sweep).

-spec run_sweep() -> non_neg_integer().
run_sweep() ->
    GuestAuth = asobi_game_config:guest_auth(),
    case application:get_env(asobi, guest_reap_after, undefined) of
        Seconds when GuestAuth =:= true, is_integer(Seconds), Seconds > 0 ->
            Cutoff = subtract_seconds(erlang:universaltime(), Seconds),
            Reaped = reap_older_than(Cutoff),
            Reaped > 0 andalso
                ?LOG_INFO(#{event => guest_reaped, count => Reaped}),
            Reaped;
        _ ->
            0
    end.

-spec reap_older_than(calendar:datetime()) -> non_neg_integer().
reap_older_than(Cutoff) ->
    %% Bounded batch per sweep - the next tick drains the rest. Guests are the
    %% highest-volume account type, so an unbounded load would block the sweeper.
    %%
    %% `updated_at`, not `inserted_at`: last seen, not account age. See the
    %% moduledoc - this is the difference between reaping abandoned devices and
    %% reaping the active player base.
    Q = kura_query:limit(
        kura_query:where(
            kura_query:where(kura_query:from(asobi_player_identity), {provider, ?PROVIDER}),
            {updated_at, '<', Cutoff}
        ),
        ?REAP_BATCH
    ),
    case asobi_repo:all(Q) of
        {ok, Identities} ->
            reap_all(Identities, 0);
        Other ->
            ?LOG_WARNING(#{event => guest_reap_query_failed, result => Other}),
            0
    end.

-spec reap_all([map()], non_neg_integer()) -> non_neg_integer().
reap_all([], Count) ->
    Count;
reap_all([Identity | Rest], Count) ->
    case reap_one(Identity) of
        reaped -> reap_all(Rest, Count + 1);
        skipped -> reap_all(Rest, Count)
    end.

-spec reap_one(map()) -> reaped | skipped.
reap_one(Identity) ->
    PlayerId = maps:get(player_id, Identity),
    case unclaimed_guest(PlayerId) of
        true -> erase_guest(PlayerId);
        false -> skipped
    end.

%% One transaction around the retention decision and the erasure, so a guest
%% that gets claimed mid-sweep is not half-deleted. Only count a genuine
%% deletion; a rolled-back or failed sweep reports skipped, not reaped.
-spec erase_guest(binary()) -> reaped | skipped.
erase_guest(PlayerId) ->
    Fun = fun() ->
        %% Re-check inside the transaction: a guest can call /auth/guest/upgrade
        %% between the pre-check and here, becoming a claimed account with a
        %% password and fresh tokens. Deleting it then would be silent loss of a
        %% real account, so a concurrent upgrade must win - abort the reap.
        case unclaimed_guest(PlayerId) of
            false -> {error, claimed_during_sweep};
            true -> asobi_player_erase:steps(PlayerId)
        end
    end,
    try asobi_repo:transaction(Fun) of
        ok ->
            asobi_player_erase:after_commit(PlayerId),
            reaped;
        {error, Reason} ->
            ?LOG_DEBUG(#{event => guest_reap_skipped, player_id => PlayerId, reason => Reason}),
            skipped;
        Other ->
            ?LOG_WARNING(#{event => guest_reap_unexpected, player_id => PlayerId, result => Other}),
            skipped
    catch
        Class:CReason:Stacktrace ->
            case asobi_player_erase:orphan_blocker(CReason) of
                {orphaned_extension_rows, Table} ->
                    ?LOG_WARNING(#{
                        event => guest_reap_orphaned_extension_rows,
                        player_id => PlayerId,
                        table => Table
                    }),
                    skipped;
                not_orphaned ->
                    ?LOG_WARNING(#{
                        event => guest_reap_cascade_error,
                        player_id => PlayerId,
                        class => Class,
                        reason => CReason,
                        stacktrace => Stacktrace
                    }),
                    skipped
            end
    end.

-doc """
Whether `PlayerId` is a guest nobody has claimed.

Unclaimed means the player never set a password **and** owns no identity from
another provider - linking Google or Steam is a claim even though
`asobi_oauth_controller:link/1` sets no password and leaves the guest identity
in place. The upgrade predicate inside `m:asobi_guest_controller` is a
deliberately different, looser question - may this account be *upgraded* - and
is not a substitute for this one anywhere erasure is involved.

Answers `false` when a lookup fails, so a caller about to delete something
fails closed.
""".
-spec unclaimed_guest(binary()) -> boolean().
unclaimed_guest(PlayerId) ->
    NoPassword =
        case asobi_repo:get(asobi_player, PlayerId) of
            {ok, Player} -> maps:get(hashed_password, Player, undefined) =:= undefined;
            _ -> false
        end,
    OnlyDevice =
        case
            asobi_repo:all(
                kura_query:where(kura_query:from(asobi_player_identity), {player_id, PlayerId})
            )
        of
            {ok, Ids} ->
                lists:all(
                    fun(I) -> is_map(I) andalso maps:get(provider, I) =:= ?PROVIDER end, Ids
                );
            _ ->
                false
        end,
    NoPassword andalso OnlyDevice.

-spec subtract_seconds(calendar:datetime(), non_neg_integer()) -> calendar:datetime().
subtract_seconds(DateTime, Seconds) ->
    Gregorian = calendar:datetime_to_gregorian_seconds(DateTime),
    calendar:gregorian_seconds_to_datetime(Gregorian - Seconds).
