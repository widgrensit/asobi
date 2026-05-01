-module(asobi_auth_cache_tests).
-include_lib("eunit/include/eunit.hrl").

cache_test_() ->
    {setup, fun setup/0, fun teardown/1, [
        {"resolve_token returns cached positive without DB", fun positive_hit/0},
        {"resolve_token caches negative with shorter TTL", fun negative_hit/0},
        {"invalidate clears the entry", fun invalidate_clears/0},
        {"expired entries are not returned", fun expired_skipped/0}
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
    ?assertEqual({ok, Player}, asobi_auth_cache:resolve_token(Token)).

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
    %% would fall back to nova_auth_session, but with the asobi_auth ets
    %% configuration not set up in eunit it will surface as an error.
    ?assertMatch({error, _}, asobi_auth_cache:resolve_token(Token)).

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
