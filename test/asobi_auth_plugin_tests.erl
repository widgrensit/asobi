-module(asobi_auth_plugin_tests).

-include_lib("eunit/include/eunit.hrl").

%% This is the gate every authenticated HTTP route sits behind, and it is
%% small enough that a refactor could plausibly widen it - a catch-all
%% clause returning `true`, or a scheme comparison that stops being
%% case-sensitive - without any other test failing. Pin every input that
%% must be rejected.

verify_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        fun accepts_a_resolvable_bearer_token/0,
        fun exposes_only_the_player_id/0,
        fun rejects_an_unresolvable_token/0,
        fun rejects_a_missing_header/0,
        fun rejects_a_non_bearer_scheme/0,
        fun rejects_a_lowercase_scheme/0,
        fun rejects_a_bare_token_with_no_scheme/0,
        fun rejects_an_empty_bearer_token/0
    ]}.

setup() ->
    meck:new(asobi_auth_cache, [passthrough]),
    meck:expect(asobi_auth_cache, resolve_token, fun
        (~"good") -> {ok, #{id => ~"p1", email => ~"ada@example.com", password_hash => ~"secret"}};
        (_) -> {error, not_found}
    end),
    ok.

cleanup(_) ->
    meck:unload(asobi_auth_cache).

req(Headers) -> #{headers => Headers}.

accepts_a_resolvable_bearer_token() ->
    ?assertEqual(
        {true, #{player_id => ~"p1"}},
        asobi_auth_plugin:verify(req(#{~"authorization" => ~"Bearer good"}))
    ).

%% The plugin's return value travels into the request map, so anything it
%% copies out of the player record is exposed to every downstream plugin
%% and controller. It must carry the id and nothing else.
exposes_only_the_player_id() ->
    {true, AuthData} = asobi_auth_plugin:verify(req(#{~"authorization" => ~"Bearer good"})),
    ?assertEqual([player_id], maps:keys(AuthData)).

rejects_an_unresolvable_token() ->
    ?assertEqual(false, asobi_auth_plugin:verify(req(#{~"authorization" => ~"Bearer expired"}))).

rejects_a_missing_header() ->
    ?assertEqual(false, asobi_auth_plugin:verify(req(#{}))).

rejects_a_non_bearer_scheme() ->
    ?assertEqual(false, asobi_auth_plugin:verify(req(#{~"authorization" => ~"Basic good"}))).

%% RFC 7235 makes the scheme case-insensitive, but asobi matches "Bearer "
%% exactly. Pin the current behaviour so the looser reading is a deliberate
%% change rather than an accident.
rejects_a_lowercase_scheme() ->
    ?assertEqual(false, asobi_auth_plugin:verify(req(#{~"authorization" => ~"bearer good"}))).

rejects_a_bare_token_with_no_scheme() ->
    ?assertEqual(false, asobi_auth_plugin:verify(req(#{~"authorization" => ~"good"}))).

rejects_an_empty_bearer_token() ->
    ?assertEqual(false, asobi_auth_plugin:verify(req(#{~"authorization" => ~"Bearer "}))).
