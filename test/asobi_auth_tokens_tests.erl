-module(asobi_auth_tokens_tests).

-include_lib("eunit/include/eunit.hrl").

%% Every login path funnels through issue/2,3, so the response shape here
%% is the shape all seven SDKs parse. revoke_access/1 is the logout path:
%% if it stops invalidating the cache, a logged-out token keeps working
%% until the TTL expires, which no other test would notice.

issue_test_() ->
    {setup, fun setup_refresh/0, fun cleanup/1, [
        fun issue_returns_the_pair_and_player_id/0,
        fun issue_passes_the_status_through/0,
        fun issue_merges_extra/0,
        fun issue_lets_extra_override_the_base_body/0,
        fun issue_degrades_to_500_on_generate_failure/0
    ]}.

setup_refresh() ->
    meck:new(nova_auth_refresh, [non_strict]),
    meck:expect(nova_auth_refresh, generate_pair, fun(asobi_auth, _Player) ->
        {ok, #{access_token => ~"access-1", refresh_token => ~"refresh-1"}}
    end),
    [nova_auth_refresh].

cleanup(Mods) ->
    [meck:unload(M) || M <- Mods],
    ok.

issue_returns_the_pair_and_player_id() ->
    {json, Status, Headers, Body} = asobi_auth_tokens:issue(#{id => ~"p1"}, 200),
    ?assertEqual(200, Status),
    ?assertEqual(#{}, Headers),
    ?assertEqual(
        #{
            player_id => ~"p1",
            access_token => ~"access-1",
            refresh_token => ~"refresh-1"
        },
        Body
    ).

issue_passes_the_status_through() ->
    ?assertMatch({json, 201, _, _}, asobi_auth_tokens:issue(#{id => ~"p1"}, 201)).

issue_merges_extra() ->
    {json, _, _, Body} = asobi_auth_tokens:issue(#{id => ~"p1"}, 200, #{username => ~"ada"}),
    ?assertEqual(~"ada", maps:get(username, Body)),
    ?assertEqual(~"p1", maps:get(player_id, Body)).

%% Extra wins the merge. Pinning it means a caller cannot start relying on
%% the opposite precedence without this failing first.
issue_lets_extra_override_the_base_body() ->
    {json, _, _, Body} = asobi_auth_tokens:issue(#{id => ~"p1"}, 200, #{player_id => ~"other"}),
    ?assertEqual(~"other", maps:get(player_id, Body)).

%% A token-store failure must not leak the reason to the client, and must
%% not be reported as a successful login.
issue_degrades_to_500_on_generate_failure() ->
    meck:expect(nova_auth_refresh, generate_pair, fun(_, _) -> {error, redis_down} end),
    Result = asobi_auth_tokens:issue(#{id => ~"p1"}, 200),
    ?assertEqual({asobi_error, ~"auth.token_issue_failed"}, Result),
    ?assertEqual(500, asobi_error:status(~"auth.token_issue_failed")).

revoke_test_() ->
    {setup, fun setup_revoke/0, fun cleanup/1, [
        fun revoke_deletes_and_invalidates_a_bearer_token/0,
        fun revoke_ignores_a_non_bearer_scheme/0,
        fun revoke_ignores_a_missing_header/0,
        fun revoke_ignores_a_bare_bearer_prefix/0
    ]}.

setup_revoke() ->
    meck:new(nova_auth_refresh, [non_strict]),
    meck:expect(nova_auth_refresh, delete_access_token, fun(asobi_auth, _Token) -> ok end),
    meck:new(asobi_auth_cache, [passthrough]),
    meck:expect(asobi_auth_cache, invalidate, fun(_Token) -> ok end),
    [nova_auth_refresh, asobi_auth_cache].

req(Headers) -> #{headers => Headers}.

revoke_deletes_and_invalidates_a_bearer_token() ->
    meck:reset(nova_auth_refresh),
    meck:reset(asobi_auth_cache),
    ?assertEqual(ok, asobi_auth_tokens:revoke_access(req(#{~"authorization" => ~"Bearer abc"}))),
    ?assert(meck:called(nova_auth_refresh, delete_access_token, [asobi_auth, ~"abc"])),
    ?assert(meck:called(asobi_auth_cache, invalidate, [~"abc"])).

revoke_ignores_a_non_bearer_scheme() ->
    meck:reset(asobi_auth_cache),
    ?assertEqual(ok, asobi_auth_tokens:revoke_access(req(#{~"authorization" => ~"Basic abc"}))),
    ?assertEqual(0, meck:num_calls(asobi_auth_cache, invalidate, '_')).

revoke_ignores_a_missing_header() ->
    meck:reset(asobi_auth_cache),
    ?assertEqual(ok, asobi_auth_tokens:revoke_access(req(#{}))),
    ?assertEqual(0, meck:num_calls(asobi_auth_cache, invalidate, '_')).

%% "Bearer " with nothing after it is an empty token, not a valid one -
%% it must not reach the store as a lookup for the empty string.
revoke_ignores_a_bare_bearer_prefix() ->
    meck:reset(asobi_auth_cache),
    ?assertEqual(ok, asobi_auth_tokens:revoke_access(req(#{~"authorization" => ~"Bearer"}))),
    ?assertEqual(0, meck:num_calls(asobi_auth_cache, invalidate, '_')).
