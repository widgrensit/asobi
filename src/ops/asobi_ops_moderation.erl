-module(asobi_ops_moderation).
-moduledoc """
Ban and unban, the `player_data` half of the ops write plane (ADR 0007).

## A ban is four facts, not one

`players.banned_at` is the durable one, and on its own it bans nobody for up
to a minute. Three caches and one live connection stand between that column
and a player who stops playing:

1. **`banned_at`** - the record. Everything else derives from it.
2. **`nova_auth`'s token rows** - deleted, so a refresh cannot mint a new
   access token after the ban.
3. **`asobi_auth_cache`** - a positive entry caches `id` and `banned_at` as
   they were *before* the ban, and `ensure_active/1` reads the cached value.
   So the entry keeps admitting the banned player for up to
   `auth_cache_ttl_ms` (60s by default) unless it is evicted. This is the
   step a ban path is most likely to forget, and `m:asobi_auth_cache`'s
   revocation SLA names "a future ban/admin-suspend path" as the caller that
   must not.
4. **The open WebSocket** - already authenticated, and re-checks nothing per
   frame. A ban that does not close it leaves the banned player in the match
   until they choose to leave.

They are applied in that order, and the order is the argument for why a
partial application is not a half-applied ban. The record lands first, so
every later step is closing a window rather than creating the ban: if the
node dies between steps 1 and 4, the player is banned, holds tokens that
resolve to a row saying so, and is rejected on the next request the cache
does not answer - within the cache TTL, not indefinitely. The reverse order
would leave a disconnected player who reconnects into a cache that still
says they are fine.

Only step 1 can fail. `nova_auth_refresh:revoke_all/2` swallows its delete
result and answers `ok`, and the cache eviction and the disconnect are an ETS
`select_delete` and a set of local sends. So the operation is "the record
changed, or nothing did", and the audit outcome says which.

## Idempotency

Both are idempotent, and both report whether anything actually changed.

Re-banning an already-banned player does **not** rewrite `banned_at`: the
first ban's timestamp is evidence, and a second press of the button must not
move it. The revocation sweep runs anyway - it is cheap, it cannot make
things worse, and it is exactly what an operator pressing ban twice is asking
for. The outcome is `{ok, [], []}`: succeeded, changed nothing.

Unbanning also evicts the auth cache. The entry cached *during* the ban
carries `banned_at`, so without the eviction the unbanned player keeps being
rejected for up to the TTL - the same stale-cache bug as the ban path, with
the sign flipped.

## Scope

`asobi_auth_cache` is node-local ETS and `asobi_presence` delivers through
`pg`. asobi is single-node by design, so "evict the cache" and "close the
sockets" mean the whole deployment.
""".

-export([ban/2, unban/2]).

-define(BAN_ACTION, ~"players.ban").
-define(UNBAN_ACTION, ~"players.unban").
-define(TARGET_TYPE, ~"player").
-define(CLASS, player_data).
-define(REASON, ~"banned").

-doc """
Ban `PlayerId` as `Actor`, revoking every credential and connection it holds.

`{ok, [PlayerId], []}` when the ban was newly applied, `{ok, [], []}` when it
was already in force, `{error, not_found}` for a player that does not exist.
""".
-spec ban(asobi_ops_auth:actor(), binary()) -> asobi_ops_audit:outcome().
ban(Actor, PlayerId) ->
    audited(Actor, ?BAN_ACTION, PlayerId, fun() -> apply_ban(PlayerId) end).

-doc """
Lift `PlayerId`'s ban as `Actor`.

`{ok, [PlayerId], []}` when a ban was lifted, `{ok, [], []}` when the player
was not banned.
""".
-spec unban(asobi_ops_auth:actor(), binary()) -> asobi_ops_audit:outcome().
unban(Actor, PlayerId) ->
    audited(Actor, ?UNBAN_ACTION, PlayerId, fun() -> apply_unban(PlayerId) end).

%% The capability check lives inside the operation as well as on the route.
%% `asobi_admin` calls these as Erlang functions in the same node (integration
%% plan, stage 3), and an in-process caller reaches no router security
%% callback - so the entry point an operator actually reaches has to be the
%% one that authorises. Same function the router uses, called from one more
%% place.
-spec audited(
    asobi_ops_auth:actor(), binary(), binary(), fun(() -> asobi_ops_audit:outcome())
) -> asobi_ops_audit:outcome().
audited(#{caps := Caps} = Actor, Action, PlayerId, Fun) ->
    asobi_ops_audit:mutation(Actor, Action, {?TARGET_TYPE, PlayerId}, fun() ->
        case asobi_ops_caps:authorised(?CLASS, Caps) of
            true -> Fun();
            false -> {error, forbidden}
        end
    end).

-spec apply_ban(binary()) -> asobi_ops_audit:outcome().
apply_ban(PlayerId) ->
    case asobi_repo:get(asobi_player, PlayerId) of
        {ok, Player} -> ban_player(PlayerId, Player, banned_at(Player));
        {error, not_found} -> {error, not_found};
        {error, Reason} -> {error, Reason}
    end.

-spec ban_player(binary(), map(), undefined | calendar:datetime()) -> asobi_ops_audit:outcome().
ban_player(PlayerId, _Player, Banned) when Banned =/= undefined ->
    revoke(PlayerId),
    {ok, [], []};
ban_player(PlayerId, Player, _Banned) ->
    case write(Player, calendar:universal_time()) of
        {ok, _Updated} ->
            revoke(PlayerId),
            {ok, [PlayerId], []};
        {error, Reason} ->
            {ok, [], [{PlayerId, Reason}]}
    end.

-spec apply_unban(binary()) -> asobi_ops_audit:outcome().
apply_unban(PlayerId) ->
    case asobi_repo:get(asobi_player, PlayerId) of
        {ok, Player} -> unban_player(PlayerId, Player, banned_at(Player));
        {error, not_found} -> {error, not_found};
        {error, Reason} -> {error, Reason}
    end.

-spec unban_player(binary(), map(), undefined | calendar:datetime()) -> asobi_ops_audit:outcome().
unban_player(_PlayerId, _Player, undefined) ->
    {ok, [], []};
unban_player(PlayerId, Player, _Banned) ->
    case write(Player, undefined) of
        {ok, _Updated} ->
            asobi_auth_cache:revoke_player(PlayerId),
            {ok, [PlayerId], []};
        {error, Reason} ->
            {ok, [], [{PlayerId, Reason}]}
    end.

-spec write(map(), calendar:datetime() | undefined) -> {ok, map()} | {error, term()}.
write(Player, BannedAt) ->
    asobi_repo:update(
        kura_changeset:cast(asobi_player, Player, #{banned_at => BannedAt}, [
            banned_at
        ])
    ).

%% kura reads a NULL timestamp back as `nil` on some paths and leaves the key
%% absent on others, so both are "not banned" - the same pair
%% `asobi_auth_cache:is_banned/1` already treats as active.
-spec banned_at(map()) -> undefined | calendar:datetime().
banned_at(#{banned_at := {{_, _, _}, {_, _, _}} = At}) -> At;
banned_at(_Player) -> undefined.

-spec revoke(binary()) -> ok.
revoke(PlayerId) ->
    _ = nova_auth_refresh:revoke_all(asobi_auth, PlayerId),
    asobi_auth_cache:revoke_player(PlayerId),
    asobi_presence:disconnect(PlayerId, ?REASON).
