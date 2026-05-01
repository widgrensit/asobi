-module(asobi_auth_cache).
-moduledoc """
In-memory cache for session-token → player resolution.

The WS connect path and every authenticated HTTP request hit
`nova_auth_session:get_user_by_session_token/2`, which costs two
kura queries (one for the token row, one for the user). Under
mobile-reconnect storms this is the dominant per-connect cost. The
cache turns a hit into one ETS lookup.

## Lifetime and freshness

Entries TTL after `asobi.auth_cache_ttl_ms` (default 60_000ms) so a
revoked token's fallout is bounded. Invalidation must be wired into
every code path that deletes or replaces a token; see `invalidate/1`.

Negative results (token not found, expired) are also cached but with
a much shorter TTL (`asobi.auth_cache_negative_ttl_ms`, default
5_000ms) so a fresh-token race doesn't keep returning errors after
the token actually exists.

## Process model

A single named gen_server owns the ETS table. Lookups are direct ETS
reads from any process; writes go through the gen_server only for
expiry-sweep coordination — `put/2,3` and `invalidate/1` write
directly via `public` ETS for latency. The gen_server runs a
periodic sweep (every TTL/2) that removes expired rows so the table
doesn't grow unbounded under attack.
""".

-behaviour(gen_server).

-export([start_link/0]).
-export([resolve_token/1, invalidate/1, put_positive/2, put_negative/1, clear/0, info/0]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(TABLE, asobi_auth_cache_tab).
-define(DEFAULT_TTL_MS, 60_000).
-define(DEFAULT_NEGATIVE_TTL_MS, 5_000).

-spec start_link() -> gen_server:start_ret().
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% Single chokepoint helper: cache hit returns immediately, miss falls
%% back to nova_auth_session and populates the cache. Both call sites
%% (`asobi_ws_handler:authenticate/1` and `asobi_auth_plugin:verify/1`)
%% should call this rather than nova_auth_session directly.
-spec resolve_token(binary()) -> {ok, map()} | {error, term()}.
resolve_token(Token) when is_binary(Token) ->
    Now = erlang:system_time(millisecond),
    case ets:lookup(?TABLE, Token) of
        [{_, {ok, Player}, ExpiresAt}] when ExpiresAt > Now ->
            asobi_telemetry:auth_cache_hit(positive),
            {ok, Player};
        [{_, {error, Reason}, ExpiresAt}] when ExpiresAt > Now ->
            asobi_telemetry:auth_cache_hit(negative),
            {error, Reason};
        _ ->
            miss(Token)
    end;
resolve_token(_) ->
    {error, invalid_token}.

-spec invalidate(binary()) -> ok.
invalidate(Token) when is_binary(Token) ->
    case ets:whereis(?TABLE) of
        undefined ->
            ok;
        _ ->
            ets:delete(?TABLE, Token),
            ok
    end;
invalidate(_) ->
    ok.

-spec put_positive(binary(), map()) -> ok.
put_positive(Token, Player) when is_binary(Token), is_map(Player) ->
    ExpiresAt = erlang:system_time(millisecond) + ttl_ms(),
    insert(Token, {ok, Player}, ExpiresAt).

-spec put_negative(binary()) -> ok.
put_negative(Token) when is_binary(Token) ->
    ExpiresAt = erlang:system_time(millisecond) + negative_ttl_ms(),
    insert(Token, {error, not_found}, ExpiresAt).

-spec clear() -> ok.
clear() ->
    case ets:whereis(?TABLE) of
        undefined ->
            ok;
        _ ->
            ets:delete_all_objects(?TABLE),
            ok
    end.

-spec info() -> #{size := non_neg_integer(), memory_words := non_neg_integer()}.
info() ->
    #{
        size => to_count(ets:info(?TABLE, size)),
        memory_words => to_count(ets:info(?TABLE, memory))
    }.

-spec to_count(non_neg_integer() | undefined | term()) -> non_neg_integer().
to_count(N) when is_integer(N), N >= 0 -> N;
to_count(_) -> 0.

%% --- gen_server callbacks ---

-spec init([]) -> {ok, map()}.
init([]) ->
    case ets:whereis(?TABLE) of
        undefined ->
            ?TABLE = ets:new(?TABLE, [
                named_table,
                public,
                set,
                {read_concurrency, true},
                {write_concurrency, true},
                {decentralized_counters, true}
            ]);
        _ ->
            ok
    end,
    schedule_sweep(),
    {ok, #{}}.

-spec handle_call(term(), gen_server:from(), map()) -> {reply, ok, map()}.
handle_call(_Req, _From, State) ->
    {reply, ok, State}.

-spec handle_cast(term(), map()) -> {noreply, map()}.
handle_cast(_Msg, State) ->
    {noreply, State}.

-spec handle_info(term(), map()) -> {noreply, map()}.
handle_info(sweep, State) ->
    sweep_expired(),
    schedule_sweep(),
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

%% --- Internal ---

miss(Token) ->
    case nova_auth_session:get_user_by_session_token(asobi_auth, Token) of
        {ok, Player} = OK ->
            asobi_telemetry:auth_cache_miss(positive),
            put_positive(Token, Player),
            OK;
        {error, _} = Err ->
            asobi_telemetry:auth_cache_miss(negative),
            put_negative(Token),
            Err
    end.

insert(Token, Value, ExpiresAt) ->
    case ets:whereis(?TABLE) of
        undefined ->
            %% Cache not yet running (test harness, app startup) —
            %% silently skip; the real lookup will go to the DB.
            ok;
        _ ->
            ets:insert(?TABLE, {Token, Value, ExpiresAt}),
            ok
    end.

-spec schedule_sweep() -> reference().
schedule_sweep() ->
    Half = ttl_ms() div 2,
    Interval =
        case Half >= 1000 of
            true -> Half;
            false -> 1000
        end,
    erlang:send_after(Interval, self(), sweep).

sweep_expired() ->
    Now = erlang:system_time(millisecond),
    %% Match every row with an ExpiresAt <= Now and delete it. Using a
    %% match-spec avoids dragging the whole table through the
    %% gen_server.
    MS = [{{'_', '_', '$1'}, [{'=<', '$1', Now}], [true]}],
    _ = ets:select_delete(?TABLE, MS),
    asobi_telemetry:auth_cache_sweep(),
    ok.

-spec ttl_ms() -> non_neg_integer().
ttl_ms() ->
    case application:get_env(asobi, auth_cache_ttl_ms) of
        {ok, N} when is_integer(N), N >= 0 -> N;
        _ -> ?DEFAULT_TTL_MS
    end.

-spec negative_ttl_ms() -> non_neg_integer().
negative_ttl_ms() ->
    case application:get_env(asobi, auth_cache_negative_ttl_ms) of
        {ok, N} when is_integer(N), N >= 0 -> N;
        _ -> ?DEFAULT_NEGATIVE_TTL_MS
    end.
