-module(asobi_rate_limit_SUITE).

-include_lib("stdlib/include/assert.hrl").
-include_lib("nova_test/include/nova_test.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([
    allows_under_limit/1,
    blocks_over_limit/1,
    returns_rate_limit_headers/1
]).

all() -> [allows_under_limit, blocks_over_limit, returns_rate_limit_headers].

init_per_suite(Config) ->
    Config0 = asobi_test_helpers:start(Config),
    U = asobi_test_helpers:unique_username(~"ratelimit"),
    {ok, R} = nova_test:post(
        "/api/v1/auth/register",
        #{json => #{~"username" => U, ~"password" => ~"testpass123"}},
        Config0
    ),
    #{~"session_token" := Token} = nova_test:json(R),
    true = is_binary(Token),
    [{token, Token} | Config0].

end_per_suite(Config) ->
    Config.

auth(Config) ->
    {token, Token} = lists:keyfind(token, 1, Config),
    true = is_binary(Token),
    [{~"authorization", <<"Bearer ", Token/binary>>}].

allows_under_limit(Config) ->
    {ok, Resp} = nova_test:get(
        "/api/v1/friends",
        #{headers => auth(Config)},
        Config
    ),
    ?assertStatus(200, Resp),
    Config.

blocks_over_limit(Config) ->
    %% Auth limiter is 20 req/60s — exhaust it
    seki:reset(asobi_auth_limiter, ~"exhaust_test"),
    lists:foreach(
        fun(_) ->
            seki:check(asobi_auth_limiter, ~"exhaust_test")
        end,
        lists:seq(1, 20)
    ),
    {deny, #{retry_after := RetryAfter}} = seki:check(asobi_auth_limiter, ~"exhaust_test"),
    ?assert(RetryAfter > 0),
    Config.

returns_rate_limit_headers(Config) ->
    {ok, Resp} = nova_test:get(
        "/api/v1/friends",
        #{headers => auth(Config)},
        Config
    ),
    ?assertStatus(200, Resp),
    ?assertNotEqual(undefined, nova_test:header("x-ratelimit-remaining", Resp)),
    Config.
