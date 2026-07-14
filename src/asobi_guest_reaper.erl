-module(asobi_guest_reaper).
-behaviour(gen_server).

%% Opt-in sweeper for stale, unclaimed guest accounts. Retention is operator
%% policy, never a core default: it does nothing unless `guest_reap_after` (a
%% number of seconds) is configured. "Permanent guests" = leave it unset. It
%% only removes guests that were never claimed - no password and no non-device
%% identity - so an upgraded account is never touched.

-export([start_link/0, sweep_now/0, cached_unlinked_count/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-include_lib("kernel/include/logger.hrl").
-include_lib("kura/include/kura.hrl").

-define(PROVIDER, ~"guest").
-define(DEFAULT_INTERVAL_MS, 3600000).
-define(REAP_BATCH, 500).
-define(COUNT_CACHE, asobi_guest_count_cache).
-define(DEFAULT_COUNT_TTL_MS, 2000).

%% Only runs when guest auth is enabled - otherwise no process, no timer on
%% deployments that don't use guest auth.
-spec start_link() -> {ok, pid()} | ignore.
start_link() ->
    case application:get_env(asobi, guest_auth, false) of
        true -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []);
        _ -> ignore
    end.

%% For tests/ops: run a sweep synchronously.
-spec sweep_now() -> {ok, non_neg_integer()}.
sweep_now() ->
    gen_server:call(?MODULE, sweep, 30000).

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
                [{count, N, Expiry}] when Expiry > Now -> N;
                _ -> refresh_count(Now)
            end
    end.

-spec refresh_count(integer()) -> non_neg_integer() | unknown.
refresh_count(Now) ->
    case live_unlinked_count() of
        N when is_integer(N) ->
            Ttl = application:get_env(asobi, guest_unlinked_count_ttl_ms, ?DEFAULT_COUNT_TTL_MS),
            true = ets:insert(?COUNT_CACHE, {count, N, Now + Ttl}),
            N;
        unknown ->
            unknown
    end.

-spec live_unlinked_count() -> non_neg_integer() | unknown.
live_unlinked_count() ->
    Q = kura_query:where(kura_query:from(asobi_player_identity), {provider, ?PROVIDER}),
    case asobi_repo:aggregate(Q, count) of
        {ok, N} -> N;
        _ -> unknown
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
    Interval = application:get_env(asobi, guest_reap_interval_ms, ?DEFAULT_INTERVAL_MS),
    erlang:send_after(Interval, self(), sweep).

-spec run_sweep() -> non_neg_integer().
run_sweep() ->
    case application:get_env(asobi, guest_reap_after, undefined) of
        Seconds when is_integer(Seconds), Seconds > 0 ->
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
    Q = kura_query:limit(
        kura_query:where(
            kura_query:where(kura_query:from(asobi_player_identity), {provider, ?PROVIDER}),
            {inserted_at, '<', Cutoff}
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
        true -> delete_guest_cascade(PlayerId);
        false -> skipped
    end.

%% Delete the player and its FK children (which are ON DELETE NO ACTION, so the
%% player row can't go first) atomically, children before the player. Only count
%% a genuine deletion; a rolled-back/failed sweep reports skipped, not reaped.
-spec delete_guest_cascade(binary()) -> reaped | skipped.
delete_guest_cascade(PlayerId) ->
    Fun = fun() ->
        %% Re-check inside the transaction: a guest can call /auth/guest/upgrade
        %% between the pre-check and here, becoming a claimed account with a
        %% password and fresh tokens. Deleting it then would be silent loss of a
        %% real account, so a concurrent upgrade must win - abort the reap.
        case unclaimed_guest(PlayerId) of
            false ->
                {error, claimed_during_sweep};
            true ->
                %% Assert each delete: a bare `{error,_}` return (not a raise)
                %% would otherwise let pgo commit a partial cascade (children
                %% gone, player left). Matching {ok,_} turns that into a badmatch
                %% that raises, rolling the whole transaction back.
                {ok, _} = asobi_repo:delete_all(by_player(asobi_player_stats, PlayerId)),
                %% player_tokens keys players by `user_id`, not `player_id`.
                {ok, _} = asobi_repo:delete_all(by_user(asobi_player_token, PlayerId)),
                {ok, _} = asobi_repo:delete_all(by_player(asobi_player_identity, PlayerId)),
                case asobi_repo:get(asobi_player, PlayerId) of
                    {ok, Player} ->
                        {ok, _} = asobi_repo:delete(asobi_player, Player),
                        ok;
                    _ ->
                        ok
                end
        end
    end,
    try asobi_repo:transaction(Fun) of
        ok ->
            reaped;
        {error, Reason} ->
            ?LOG_DEBUG(#{event => guest_reap_skipped, player_id => PlayerId, reason => Reason}),
            skipped;
        Other ->
            ?LOG_WARNING(#{event => guest_reap_unexpected, player_id => PlayerId, result => Other}),
            skipped
    catch
        Class:CReason:Stacktrace ->
            ?LOG_WARNING(#{
                event => guest_reap_cascade_error,
                player_id => PlayerId,
                class => Class,
                reason => CReason,
                stacktrace => Stacktrace
            }),
            skipped
    end.

-spec by_player(module(), binary()) -> #kura_query{}.
by_player(Schema, PlayerId) ->
    kura_query:where(kura_query:from(Schema), {player_id, PlayerId}).

-spec by_user(module(), binary()) -> #kura_query{}.
by_user(Schema, PlayerId) ->
    kura_query:where(kura_query:from(Schema), {user_id, PlayerId}).

%% A guest is unclaimed only if the player never set a password and has no
%% identity from another provider (i.e. never upgraded/linked).
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
            {ok, Ids} -> lists:all(fun(I) -> maps:get(provider, I) =:= ?PROVIDER end, Ids);
            _ -> false
        end,
    NoPassword andalso OnlyDevice.

-spec subtract_seconds(calendar:datetime(), non_neg_integer()) -> calendar:datetime().
subtract_seconds(DateTime, Seconds) ->
    Gregorian = calendar:datetime_to_gregorian_seconds(DateTime),
    calendar:gregorian_seconds_to_datetime(Gregorian - Seconds).
