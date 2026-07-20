-module(asobi_auth_cache_tests).
-include_lib("eunit/include/eunit.hrl").

cache_test_() ->
    {setup, fun setup/0, fun teardown/1, [
        {"resolve_token returns cached positive without DB", fun positive_hit/0},
        {"resolve_token caches negative with shorter TTL", fun negative_hit/0},
        {"invalidate clears the entry", fun invalidate_clears/0},
        {"expired entries are not returned", fun expired_skipped/0},
        {"banned players are rejected", fun banned_rejected/0},
        {"active players (nil banned_at) pass", fun active_passes/0},
        {"the raw token never appears as an ETS key", fun token_not_stored_raw/0},
        {"hashed_password is never cached", fun hashed_password_not_cached/0}
    ]}.

setup() ->
    application:set_env(asobi, auth_cache_ttl_ms, 60_000),
    application:set_env(asobi, auth_cache_negative_ttl_ms, 5_000),
    {ok, Pid} = asobi_auth_cache:start_link(),
    Pid.

teardown(Pid) ->
    asobi_auth_cache:clear(),
    gen_server:stop(Pid),
    application:unset_env(asobi, auth_cache_ttl_ms),
    application:unset_env(asobi, auth_cache_negative_ttl_ms),
    ok.

positive_hit() ->
    Token = ~"tok-positive",
    Player = #{id => ~"player-1", username => ~"alice"},
    asobi_auth_cache:put_positive(Token, Player),
    %% The cache projects to the fields the auth path uses; `username` and any
    %% other row field (incl. hashed_password) are dropped, so the id is what
    %% comes back.
    ?assertEqual({ok, #{id => ~"player-1"}}, asobi_auth_cache:resolve_token(Token)).

negative_hit() ->
    Token = ~"tok-negative",
    asobi_auth_cache:put_negative(Token),
    ?assertEqual({error, not_found}, asobi_auth_cache:resolve_token(Token)).

invalidate_clears() ->
    Token = ~"tok-invalidate",
    Player = #{id => ~"player-2"},
    asobi_auth_cache:put_positive(Token, Player),
    ?assertEqual({ok, Player}, asobi_auth_cache:resolve_token(Token)),
    asobi_auth_cache:invalidate(Token),
    %% After invalidate the cache no longer holds the entry; resolve_token
    %% would fall back to nova_auth_refresh, but with the asobi_auth ets
    %% configuration not set up in eunit it will surface as an error.
    ?assertMatch({error, _}, asobi_auth_cache:resolve_token(Token)).

banned_rejected() ->
    Token = ~"tok-banned",
    Player = #{id => ~"player-banned", banned_at => {{2026, 1, 1}, {0, 0, 0}}},
    asobi_auth_cache:put_positive(Token, Player),
    ?assertEqual({error, banned}, asobi_auth_cache:resolve_token(Token)).

active_passes() ->
    Token = ~"tok-active",
    Player = #{id => ~"player-active", banned_at => nil},
    asobi_auth_cache:put_positive(Token, Player),
    ?assertEqual(
        {ok, #{id => ~"player-active", banned_at => nil}}, asobi_auth_cache:resolve_token(Token)
    ).

token_not_stored_raw() ->
    %% asobi#168: a crash dump / observer read of the cache table must not
    %% yield a usable session token. The key is the SHA-256 of the token, so
    %% the raw token appears nowhere in the row.
    Token = ~"tok-secret-value",
    asobi_auth_cache:put_positive(Token, #{id => ~"p"}),
    Rows = ets:tab2list(asobi_auth_cache_tab),
    Keys = [K || {K, _V, _E} <- Rows],
    ?assert(lists:member(crypto:hash(sha256, Token), Keys)),
    ?assertNot(
        lists:member(Token, Keys),
        "the raw token is stored as an ETS key - a dump would leak it"
    ),
    %% And it is genuinely still resolvable through the hash chokepoint.
    ?assertEqual({ok, #{id => ~"p"}}, asobi_auth_cache:resolve_token(Token)).

hashed_password_not_cached() ->
    %% asobi#168: the full player row carries hashed_password (pbkdf2). Parking
    %% it in the public cache table reopens the crash-dump surface for a
    %% credential, so put_positive/2 projects the row before storing.
    Token = ~"tok-with-secret",
    Player = #{id => ~"p", banned_at => nil, hashed_password => ~"$pbkdf2-sha256$secret"},
    asobi_auth_cache:put_positive(Token, Player),
    %% Look up by the hashed key rather than assuming a single-row table -
    %% the setup/0 table is shared across tests.
    [{_, {ok, Cached}, _}] = ets:lookup(asobi_auth_cache_tab, crypto:hash(sha256, Token)),
    ?assertNot(
        maps:is_key(hashed_password, Cached),
        "hashed_password is in the cached row - a dump would leak a crackable credential"
    ),
    ?assertEqual(#{id => ~"p", banned_at => nil}, Cached).

%% A short-TTL setup confirms expired rows are not served.
expired_skipped() ->
    application:set_env(asobi, auth_cache_ttl_ms, 1),
    try
        Token = ~"tok-expire",
        Player = #{id => ~"player-3"},
        asobi_auth_cache:put_positive(Token, Player),
        timer:sleep(10),
        ?assertMatch({error, _}, asobi_auth_cache:resolve_token(Token))
    after
        application:set_env(asobi, auth_cache_ttl_ms, 60_000)
    end.
