-module(asobi_guest_reaper).
-behaviour(gen_server).

%% Opt-in sweeper for stale, unclaimed guest accounts. Retention is operator
%% policy, never a core default: it does nothing unless `guest_reap_after` (a
%% number of seconds) is configured. "Permanent guests" = leave it unset. It
%% only removes guests that were never claimed - no password and no non-device
%% identity - so an upgraded account is never touched.

-export([start_link/0, sweep_now/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-include_lib("kernel/include/logger.hrl").
-include_lib("kura/include/kura.hrl").

-define(PROVIDER, ~"guest").
-define(DEFAULT_INTERVAL_MS, 3600000).
-define(REAP_BATCH, 500).

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
    schedule(),
    {ok, #{}}.

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
        {ok, Identities} -> reap_all(Identities, 0);
        _ -> 0
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
        _ = asobi_repo:delete_all(by_player(asobi_player_stats, PlayerId)),
        _ = asobi_repo:delete_all(by_player(asobi_player_token, PlayerId)),
        _ = asobi_repo:delete_all(by_player(asobi_player_identity, PlayerId)),
        case asobi_repo:get(asobi_player, PlayerId) of
            {ok, Player} -> asobi_repo:delete(asobi_player, Player);
            _ -> ok
        end
    end,
    try asobi_repo:transaction(Fun) of
        {error, _} -> skipped;
        _ -> reaped
    catch
        _:_ -> skipped
    end.

-spec by_player(module(), binary()) -> #kura_query{}.
by_player(Schema, PlayerId) ->
    kura_query:where(kura_query:from(Schema), {player_id, PlayerId}).

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
