-module(asobi_auth_cache).
-moduledoc """
In-memory cache for access-token → player resolution.

The WS connect path and every authenticated HTTP request hit
`nova_auth_refresh:get_user_by_access_token/2`, which costs two
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

## Revocation SLA (asobi#215)

A revoked token's cache entry can outlive its DB row by up to
`auth_cache_ttl_ms` unless the revoking code path also touches this
cache. Audited as of asobi#215:

- **Single-device logout** (`asobi_auth_tokens:revoke_access/1`) calls
  `invalidate/1` for the one access token being logged out. Immediate.
- **Mass revoke keyed by player** (any path that deletes more tokens
  than the caller holds a single token for - e.g.
  `asobi_guest_controller`'s guest-to-real upgrade, which calls
  `nova_auth_refresh:revoke_all/2` for every token a player holds, or a
  future ban/admin-suspend path) MUST call `revoke_player/1` right
  after the DB-level revoke, passing the player id. The stored value
  carries `id` (see `cacheable/1`), so a match-spec scan can target
  every cached entry for one player without evicting every other
  player's session; there is no need to reach for `clear/0` here.
  "Targeted" is about blast radius, not cost: there is no secondary
  index on `id`, so `revoke_player/1` is still an O(total cache size)
  scan, same shape as `clear/0`'s `delete_all_objects/1`, not
  O(that player's token count).
- `clear/0` remains available for whole-table maintenance (test
  teardown, an operator-triggered flush) but is intentionally NOT the
  revocation primitive - a full clear scales with total cached
  sessions rather than the one player being revoked, and is an easy
  denial-of-service amplifier if wired to a client-reachable action.
- **Refresh-token rotation** (`nova_auth_refresh:refresh/2`) does NOT
  revoke the access token that was live before the rotation - by
  `nova_auth`'s design, access tokens are short-lived bearer credentials
  (60 min default, `asobi_auth:config/0`) that aren't tied to their
  refresh token's rotation state, so there is nothing to invalidate here
  even in principle. This is a `nova_auth` design characteristic, not an
  `asobi_auth_cache` gap.

## Revoke/read race

`invalidate/1` and `revoke_player/1` only delete what's in the table
*right now*. A `miss/1` already in flight (DB read returned, `put_positive/2`
not yet called) can still land its write after the revoke, caching the
stale row for a fresh TTL. `epoch/0` closes this: every revoke bumps a
counter first, and `miss/1` only caches its read if the epoch it read
before querying the DB is still current when the DB answers - otherwise
a revoke happened mid-read and the result is served once, uncached.

## Process model

A single named gen_server owns the ETS table. Lookups are direct ETS
reads from any process; writes go through the gen_server only for
expiry-sweep coordination — `put/2,3`, `invalidate/1` and
`revoke_player/1` write directly via `public` ETS for latency. The
gen_server runs a periodic sweep (every TTL/2) that removes expired
rows so the table doesn't grow unbounded under attack.
""".

-behaviour(gen_server).

-export([start_link/0]).
-export([
    resolve_token/1,
    invalidate/1,
    revoke_player/1,
    put_positive/2,
    put_negative/1,
    clear/0,
    info/0
]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(TABLE, asobi_auth_cache_tab).
-define(EPOCH_TABLE, asobi_auth_cache_epoch_tab).
-define(EPOCH_KEY, epoch).
-define(DEFAULT_TTL_MS, 60_000).
-define(DEFAULT_NEGATIVE_TTL_MS, 5_000).

-spec start_link() -> gen_server:start_ret().
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% Single chokepoint helper: cache hit returns immediately, miss falls
%% back to nova_auth_refresh and populates the cache. Both call sites
%% (`asobi_ws_handler:authenticate/1` and `asobi_auth_plugin:verify/1`)
%% should call this rather than nova_auth_refresh directly.
-spec resolve_token(binary()) -> {ok, map()} | {error, term()}.
resolve_token(Token) when is_binary(Token) ->
    ensure_active(lookup(Token));
resolve_token(_) ->
    {error, invalid_token}.

-spec lookup(binary()) -> {ok, map()} | {error, term()}.
lookup(Token) ->
    Now = erlang:system_time(millisecond),
    case ets:lookup(?TABLE, key(Token)) of
        [{_, {ok, Player}, ExpiresAt}] when ExpiresAt > Now ->
            asobi_telemetry:auth_cache_hit(positive),
            {ok, Player};
        [{_, {error, Reason}, ExpiresAt}] when ExpiresAt > Now ->
            asobi_telemetry:auth_cache_hit(negative),
            {error, Reason};
        _ ->
            miss(Token)
    end.

%% Reject sessions belonging to banned players, even when the token itself is
%% valid and cached. `banned_at` is nil/absent for active players.
-spec ensure_active({ok, map()} | {error, term()}) -> {ok, map()} | {error, term()}.
ensure_active({ok, Player} = OK) ->
    case is_banned(Player) of
        true -> {error, banned};
        false -> OK
    end;
ensure_active(Other) ->
    Other.

-spec is_banned(map()) -> boolean().
is_banned(#{banned_at := V}) -> V =/= nil andalso V =/= undefined;
is_banned(_) -> false.

-spec invalidate(binary()) -> ok.
invalidate(Token) when is_binary(Token) ->
    case ets:whereis(?TABLE) of
        undefined ->
            ok;
        _ ->
            bump_epoch(),
            ets:delete(?TABLE, key(Token)),
            ok
    end;
invalidate(_) ->
    ok.

%% Evict every cached entry for one player, without touching any other
%% player's session. The revocation primitive for mass-revoke paths
%% (guest-upgrade, a future ban path) - see the moduledoc's "Revocation SLA".
-spec revoke_player(binary()) -> ok.
revoke_player(PlayerId) when is_binary(PlayerId) ->
    case ets:whereis(?TABLE) of
        undefined ->
            ok;
        _ ->
            bump_epoch(),
            MS = [{{'_', {ok, #{id => '$1'}}, '_'}, [{'=:=', '$1', PlayerId}], [true]}],
            _ = ets:select_delete(?TABLE, MS),
            ok
    end.

-spec put_positive(binary(), map()) -> ok.
put_positive(Token, Player) when is_binary(Token), is_map(Player) ->
    ExpiresAt = erlang:system_time(millisecond) + ttl_ms(),
    insert(Token, {ok, cacheable(Player)}, ExpiresAt).

%% Cache only the fields the auth path consumes. The full player row from
%% nova_auth_refresh carries `hashed_password` (pbkdf2); parking that in a
%% `public` ETS table reopens the exact crash-dump/observer surface #168
%% closes for tokens - a per-session offline-cracking target. Both consumers
%% (asobi_ws_handler, asobi_auth_plugin) read only `id`; `is_banned/1` reads
%% only `banned_at`.
-spec cacheable(map()) -> map().
cacheable(Player) ->
    maps:with([id, banned_at], Player).

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
            bump_epoch(),
            ets:delete_all_objects(?TABLE),
            ok
    end.

-spec epoch() -> non_neg_integer().
epoch() ->
    case ets:whereis(?EPOCH_TABLE) of
        undefined ->
            0;
        _ ->
            %% No fallback clause: with a 4-arity call and a plain integer
            %% Incr (0), update_counter/4 always returns a single integer,
            %% never the list form its type covers for a list-of-UpdateOp
            %% call. Only here for eqwalizer narrowing (see to_count/1) -
            %% not defensive against a real alternate return.
            case ets:update_counter(?EPOCH_TABLE, ?EPOCH_KEY, 0, {?EPOCH_KEY, 0}) of
                N when is_integer(N) -> N
            end
    end.

-spec bump_epoch() -> ok.
bump_epoch() ->
    case ets:whereis(?EPOCH_TABLE) of
        undefined ->
            ok;
        _ ->
            _ = ets:update_counter(?EPOCH_TABLE, ?EPOCH_KEY, 1, {?EPOCH_KEY, 0}),
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
    case ets:whereis(?EPOCH_TABLE) of
        undefined ->
            ?EPOCH_TABLE = ets:new(?EPOCH_TABLE, [
                named_table,
                public,
                set,
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
    %% Capture the epoch before the DB round trip. A revoke/read race: if
    %% invalidate/1, revoke_player/1 or clear/0 bumps the epoch while this
    %% read is in flight, the row we're about to cache may already be stale
    %% (deleted DB-side, hence the revoke). Serve it once, don't cache it.
    Epoch = epoch(),
    case nova_auth_refresh:get_user_by_access_token(asobi_auth, Token) of
        {ok, Player} = OK ->
            asobi_telemetry:auth_cache_miss(positive),
            case epoch() of
                Epoch -> put_positive(Token, Player);
                _ -> ok
            end,
            OK;
        {error, _} = Err ->
            asobi_telemetry:auth_cache_miss(negative),
            case epoch() of
                Epoch -> put_negative(Token);
                _ -> ok
            end,
            Err
    end.

insert(Token, Value, ExpiresAt) ->
    case ets:whereis(?TABLE) of
        undefined ->
            %% Cache not yet running (test harness, app startup) —
            %% silently skip; the real lookup will go to the DB.
            ok;
        _ ->
            ets:insert(?TABLE, {key(Token), Value, ExpiresAt}),
            ok
    end.

-doc """
Derive the ETS key from a token.

The token itself is never stored - only its SHA-256. A crash dump,
`observer`, or a hot-loaded debugger reading the table yields hashes, not
usable session tokens. asobi is single-tenant so there is no untrusted Lua,
but the dump/observer/debugger surface is real; this closes it (asobi#168).

The stored `Value` holds only `id` and `banned_at` (see `cacheable/1`) -
never the token, never `hashed_password` - so the row as a whole leaks
nothing that resolves to a session or a credential.
""".
-spec key(binary()) -> binary().
key(Token) ->
    crypto:hash(sha256, Token).

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
