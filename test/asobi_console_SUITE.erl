-module(asobi_console_SUITE).

-include_lib("nova_test/include/nova_test.hrl").

%% The console over real HTTP: what the shell answers with, what the assets
%% answer with, and whether the cookie the login hands out actually opens the
%% ops plane. The eunit suites cover the pieces; this one covers the wiring,
%% which is where a route group, a plugin order or a cookie attribute goes
%% wrong without any unit test noticing.

-define(OPS_SECRET, ~"31d0f7a5c8b26e94103fa87c5d29b6e0475cf1a83b9d6e2047ca5813fd6e9b02").
-define(SIGNING_SECRET, ~"a-per-env-ops-signing-secret-32b!").
-define(ENV_ID, ~"019f7646-9ddb-77ee-82f5-b5e7f3b9ee9d").

-export([all/0, groups/0, init_per_suite/1, end_per_suite/1, init_per_group/2, end_per_group/2]).
-export([
    shell_is_served/1,
    shell_carries_a_fresh_nonce_and_is_not_cached/1,
    shell_script_tag_carries_the_policy_nonce/1,
    asset_is_served_immutable/1,
    asset_revalidates_with_its_etag/1,
    unknown_asset_is_404/1,
    traversal_in_an_asset_name_is_404/1,
    console_is_404_when_disabled/1,
    ops_is_unreachable_when_disabled/1,
    login_rejects_a_wrong_secret/1,
    login_sets_both_cookies/1,
    session_cookie_opens_the_ops_plane/1,
    cookie_without_csrf_is_refused/1,
    whoami_reports_the_actor/1,
    logout_ends_the_session/1,
    a_minted_token_opens_a_session/1,
    a_minted_session_carries_only_the_token_s_caps/1,
    a_minted_session_does_not_outlive_its_token/1,
    a_bad_minted_token_is_refused_like_a_bad_secret/1
]).

all() ->
    [{group, disabled}, {group, serving}, {group, session}].

groups() ->
    [
        {disabled, [sequence], [console_is_404_when_disabled, ops_is_unreachable_when_disabled]},
        {serving, [sequence], [
            shell_is_served,
            shell_carries_a_fresh_nonce_and_is_not_cached,
            shell_script_tag_carries_the_policy_nonce,
            asset_is_served_immutable,
            asset_revalidates_with_its_etag,
            unknown_asset_is_404,
            traversal_in_an_asset_name_is_404
        ]},
        {session, [sequence], [
            login_rejects_a_wrong_secret,
            login_sets_both_cookies,
            a_minted_token_opens_a_session,
            a_minted_session_carries_only_the_token_s_caps,
            a_minted_session_does_not_outlive_its_token,
            a_bad_minted_token_is_refused_like_a_bad_secret,
            session_cookie_opens_the_ops_plane,
            cookie_without_csrf_is_refused,
            whoami_reports_the_actor,
            logout_ends_the_session
        ]}
    ].

init_per_suite(Config) ->
    Was = {application:get_env(asobi, console), application:get_env(asobi, ops_secret)},
    [{console_env_was, Was} | asobi_test_helpers:start(Config)].

end_per_suite(Config) ->
    {console_env_was, {Console, Secret}} = lists:keyfind(console_env_was, 1, Config),
    restore(console, Console),
    restore(ops_secret, Secret),
    Config.

init_per_group(disabled, Config) ->
    application:unset_env(asobi, console),
    Config;
init_per_group(_Group, Config) ->
    application:set_env(asobi, console, true),
    application:set_env(asobi, ops_secret, ?OPS_SECRET),
    application:set_env(asobi, ops_token_secret, ?SIGNING_SECRET),
    application:set_env(asobi, env_id, ?ENV_ID),
    Config.

%% A token the way asobi_saas mints one.
minted(Caps) ->
    Now = erlang:system_time(second),
    asobi_ops_token:sign(?SIGNING_SECRET, #{
        env => ?ENV_ID,
        sub => ~"user-7",
        caps => Caps,
        iat => Now,
        exp => Now + asobi_ops_token:max_ttl()
    }).

end_per_group(_Group, Config) ->
    Config.

restore(Key, {ok, Value}) -> application:set_env(asobi, Key, Value);
restore(Key, undefined) -> application:unset_env(asobi, Key).

%%--------------------------------------------------------------------
%% Off by default
%%
%% Nova starts one listener, so the console shares the game port. A surface
%% that bans players must not appear there because someone upgraded.
%%--------------------------------------------------------------------

console_is_404_when_disabled(Config) ->
    {ok, Shell} = nova_test:get("/console", Config),
    ?assertStatus(404, Shell),
    {ok, Login} = nova_test:post(
        "/console/session", #{json => #{~"secret" => ?OPS_SECRET}}, Config
    ),
    ?assertStatus(404, Login),
    Config.

%% Disabling the console must not disable the ops plane: the bearer transport
%% is a different thing and CI depends on it.
ops_is_unreachable_when_disabled(Config) ->
    application:set_env(asobi, ops_secret, ?OPS_SECRET),
    {ok, Resp} = nova_test:get("/api/v1/ops/players", bearer(), Config),
    ?assertStatus(200, Resp),
    Config.

%%--------------------------------------------------------------------
%% Serving
%%--------------------------------------------------------------------

shell_is_served(Config) ->
    {ok, Resp} = nova_test:get("/console", Config),
    ?assertStatus(200, Resp),
    ?assertEqual("text/html; charset=utf-8", nova_test:header("content-type", Resp)),
    ?assertNotEqual(nomatch, binary:match(nova_test:body(Resp), ~"<div id=\"root\"></div>")),
    Config.

%% A cached shell would reuse its nonce, and a reused nonce is not a nonce.
shell_carries_a_fresh_nonce_and_is_not_cached(Config) ->
    {ok, First} = nova_test:get("/console", Config),
    {ok, Second} = nova_test:get("/console", Config),
    ?assertEqual("no-store", nova_test:header("cache-control", First)),
    ?assertNotEqual(nonce(First), nonce(Second)),
    Config.

%% The join between the two halves: the nonce the header allows has to be the
%% nonce the one script tag carries, or the console is blank with no server
%% error anywhere.
shell_script_tag_carries_the_policy_nonce(Config) ->
    {ok, Resp} = nova_test:get("/console", Config),
    Nonce = nonce(Resp),
    ?assert(byte_size(Nonce) > 0),
    Body = nova_test:body(Resp),
    ?assertEqual(1, length(binary:matches(Body, ~"<script"))),
    ?assertNotEqual(nomatch, binary:match(Body, <<"nonce=\"", Nonce/binary, "\"">>)),
    Policy = list_to_binary(nova_test:header("content-security-policy", Resp)),
    ?assertEqual(nomatch, binary:match(Policy, ~"unsafe-inline")),
    ?assertEqual(nomatch, binary:match(Policy, ~"unsafe-eval")),
    Config.

asset_is_served_immutable(Config) ->
    {ok, Resp} = nova_test:get(asset_path(), Config),
    ?assertStatus(200, Resp),
    ?assertEqual("text/javascript; charset=utf-8", nova_test:header("content-type", Resp)),
    ?assertEqual("public, max-age=31536000, immutable", nova_test:header("cache-control", Resp)),
    ?assertNotEqual(undefined, nova_test:header("etag", Resp)),
    Config.

asset_revalidates_with_its_etag(Config) ->
    {ok, First} = nova_test:get(asset_path(), Config),
    Etag = nova_test:header("etag", First),
    {ok, Second} = nova_test:get(
        asset_path(), #{headers => [{~"if-none-match", list_to_binary(Etag)}]}, Config
    ),
    ?assertStatus(304, Second),
    ?assertEqual(~"", nova_test:body(Second)),
    Config.

unknown_asset_is_404(Config) ->
    {ok, Resp} = nova_test:get("/console/assets/main-deadbeef.js", Config),
    ?assertStatus(404, Resp),
    Config.

%% Browsers normalise `..` before sending, so this arrives as whatever the
%% router makes of it. Either way it must not reach a file: the asset name is
%% a map key, never a path segment joined onto a directory.
traversal_in_an_asset_name_is_404(Config) ->
    [
        begin
            {ok, Resp} = nova_test:get(Path, Config),
            ?assert(lists:member(nova_test:status(Resp), [400, 404]), {Path, Resp})
        end
     || Path <- [
            "/console/assets/..%2f..%2frebar.config",
            "/console/assets/%2e%2e%2f%2e%2e%2frebar.config",
            "/console/assets/.env"
        ]
    ],
    Config.

%%--------------------------------------------------------------------
%% The session
%%--------------------------------------------------------------------

login_rejects_a_wrong_secret(Config) ->
    {ok, Resp} = nova_test:post(
        "/console/session", #{json => #{~"secret" => ~"not-the-secret"}}, Config
    ),
    ?assertStatus(403, Resp),
    ?assertMatch(#{~"error" := #{~"code" := ~"forbidden"}}, nova_test:json(Resp)),
    %% Nova sets its own `session_id` cookie on every response, so this asks
    %% the only question that matters: a refused login must not hand out a
    %% console session.
    ?assertEqual([], [C || C <- set_cookies(Resp), binary:match(C, ~"asobi_console") =/= nomatch]),
    Config.

login_sets_both_cookies(Config) ->
    {ok, Resp} = nova_test:post(
        "/console/session", #{json => #{~"secret" => ?OPS_SECRET, ~"label" => ~"kaito"}}, Config
    ),
    ?assertStatus(200, Resp),
    ?assertMatch(#{~"data" := #{~"display" := ~"kaito", ~"csrf" := _}}, nova_test:json(Resp)),
    Cookies = set_cookies(Resp),
    Session = find(~"asobi_console=", Cookies),
    Csrf = find(~"asobi_console_csrf=", Cookies),
    %% The session id must be unreadable by script; the CSRF companion must
    %% not be, because the page has to send it back as a header after reload.
    ?assertNotEqual(nomatch, binary:match(string:lowercase(Session), ~"httponly")),
    ?assertEqual(nomatch, binary:match(string:lowercase(Csrf), ~"httponly")),
    [
        ?assertNotEqual(nomatch, binary:match(string:lowercase(Cookie), ~"samesite=strict"))
     || Cookie <- [Session, Csrf]
    ],
    Config.

%% The managed path: a tenant's browser posts the token the control plane
%% minted and then holds a cookie, so the token never has to live in
%% JavaScript for the length of a session.
a_minted_token_opens_a_session(Config) ->
    {ok, Resp} = nova_test:post(
        "/console/session", #{json => #{~"token" => minted([read])}}, Config
    ),
    ?assertStatus(200, Resp),
    ?assertMatch(#{~"data" := #{~"display" := ~"user-7"}}, nova_test:json(Resp)),
    Config.

%% The whole point of mapping roles to classes at mint time would be undone if
%% the exchange widened them back out.
a_minted_session_carries_only_the_token_s_caps(Config) ->
    {ok, Resp} = nova_test:post(
        "/console/session", #{json => #{~"token" => minted([read])}}, Config
    ),
    Csrf = maps:get(~"csrf", maps:get(~"data", nova_test:json(Resp))),
    Cookie = find(~"asobi_console=", set_cookies(Resp)),
    {ok, Whoami} = nova_test:get(
        "/console/session",
        #{headers => [{~"cookie", Cookie}, {~"x-csrf-token", Csrf}]},
        Config
    ),
    ?assertMatch(#{~"data" := #{~"caps" := [~"read"]}}, nova_test:json(Whoami)),
    Config.

%% A fifteen-minute credential must not buy a twelve-hour session.
a_minted_session_does_not_outlive_its_token(Config) ->
    {ok, Resp} = nova_test:post(
        "/console/session", #{json => #{~"token" => minted([read])}}, Config
    ),
    #{~"data" := #{~"expires_at" := ExpiresAt}} = nova_test:json(Resp),
    Now = erlang:system_time(second),
    ?assert(ExpiresAt =< Now + asobi_ops_token:max_ttl()),
    ?assert(ExpiresAt > Now),
    Config.

a_bad_minted_token_is_refused_like_a_bad_secret(Config) ->
    {ok, Resp} = nova_test:post(
        "/console/session", #{json => #{~"token" => ~"v1.not.valid"}}, Config
    ),
    ?assertStatus(403, Resp),
    Config.

session_cookie_opens_the_ops_plane(Config) ->
    {Config0, Csrf} = signed_in(Config),
    {ok, Resp} = nova_test:get(
        "/api/v1/ops/players", #{headers => [{~"x-csrf-token", Csrf}]}, Config0
    ),
    ?assertStatus(200, Resp),
    ?assertMatch(#{~"data" := _, ~"page" := _}, nova_test:json(Resp)),
    Config.

%% The property the whole second layer exists for: a cross-site request
%% carries the browser's cookie and cannot carry the header.
cookie_without_csrf_is_refused(Config) ->
    {Config0, _Csrf} = signed_in(Config),
    {ok, Resp} = nova_test:get("/api/v1/ops/players", Config0),
    ?assertStatus(403, Resp),
    {ok, Wrong} = nova_test:get(
        "/api/v1/ops/players", #{headers => [{~"x-csrf-token", ~"guessed"}]}, Config0
    ),
    ?assertStatus(403, Wrong),
    Config.

whoami_reports_the_actor(Config) ->
    {Config0, Csrf} = signed_in(Config),
    {ok, Resp} = nova_test:get(
        "/console/session", #{headers => [{~"x-csrf-token", Csrf}]}, Config0
    ),
    ?assertStatus(200, Resp),
    #{~"data" := Actor} = nova_test:json(Resp),
    ?assertEqual(~"kaito", maps:get(~"display", Actor)),
    ?assertEqual(~"local_user", maps:get(~"source", Actor)),
    ?assertEqual(false, maps:get(~"attested", Actor)),
    Config.

logout_ends_the_session(Config) ->
    {Config0, Csrf} = signed_in(Config),
    {ok, Out} = nova_test:delete("/console/session", Config0),
    ?assertStatus(200, Out),
    {ok, After} = nova_test:get(
        "/api/v1/ops/players", #{headers => [{~"x-csrf-token", Csrf}]}, Config0
    ),
    ?assertStatus(403, After),
    Config.

%%--------------------------------------------------------------------
%% Helpers
%%--------------------------------------------------------------------

bearer() ->
    #{headers => [{~"authorization", <<"Bearer ", ?OPS_SECRET/binary>>}]}.

signed_in(Config) ->
    Clean = nova_test:clear_cookies(Config),
    {ok, Resp} = nova_test:post(
        "/console/session", #{json => #{~"secret" => ?OPS_SECRET, ~"label" => ~"kaito"}}, Clean
    ),
    ?assertStatus(200, Resp),
    #{~"data" := #{~"csrf" := Csrf}} = nova_test:json(Resp),
    {nova_test:save_cookies(Resp, Clean), Csrf}.

asset_path() ->
    {ok, #{script := Script}} = asobi_console:load(filename:join(code:priv_dir(asobi), "console")),
    binary_to_list(<<"/console/assets/", Script/binary>>).

set_cookies(#{headers := Headers}) ->
    [list_to_binary(Value) || {"set-cookie", Value} <- Headers].

find(Prefix, Cookies) ->
    Size = byte_size(Prefix),
    case [C || <<P:Size/binary, _/binary>> = C <- Cookies, P =:= Prefix] of
        [Cookie | _] -> Cookie;
        [] -> ct:fail({no_cookie, Prefix, Cookies})
    end.

nonce(Resp) ->
    Policy = list_to_binary(nova_test:header("content-security-policy", Resp)),
    [_, Rest] = binary:split(Policy, ~"script-src 'nonce-"),
    [Nonce | _] = binary:split(Rest, ~"'"),
    Nonce.
