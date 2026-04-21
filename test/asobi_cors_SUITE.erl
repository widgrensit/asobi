-module(asobi_cors_SUITE).

%% CORS preflight tests.
%%
%% Nova's middleware chain runs `nova_router` before the CORS plugin, so an
%% OPTIONS request to a route only registered with `methods => [post]` gets
%% 405 from the router before the CORS plugin's OPTIONS short-circuit ever
%% runs. asobi_router adds `options` to every route's methods list so the
%% CORS plugin's `pre_request` sees the request and replies 200; these tests
%% lock in that behaviour across auth, IAP, and authed API routes.

-include_lib("nova_test/include/nova_test.hrl").

-export([
    all/0,
    init_per_suite/1,
    end_per_suite/1
]).
-export([
    options_on_auth_register_returns_2xx/1,
    options_on_auth_login_returns_2xx/1,
    options_on_iap_apple_returns_2xx/1,
    options_on_api_matches_returns_2xx/1,
    options_on_api_wallets_returns_2xx/1,
    options_on_authed_route_skips_auth/1,
    options_preflight_includes_cors_headers/1,
    post_register_still_works/1
]).

all() ->
    [
        options_on_auth_register_returns_2xx,
        options_on_auth_login_returns_2xx,
        options_on_iap_apple_returns_2xx,
        options_on_api_matches_returns_2xx,
        options_on_api_wallets_returns_2xx,
        options_on_authed_route_skips_auth,
        options_preflight_includes_cors_headers,
        post_register_still_works
    ].

init_per_suite(Config) ->
    asobi_test_helpers:start(Config).

end_per_suite(Config) ->
    Config.

%% --- OPTIONS preflight returns 2xx on every route group ---

options_on_auth_register_returns_2xx(Config) ->
    {ok, Resp} = nova_test:request(options, "/api/v1/auth/register", #{}, Config),
    assert_preflight_ok(Resp).

options_on_auth_login_returns_2xx(Config) ->
    {ok, Resp} = nova_test:request(options, "/api/v1/auth/login", #{}, Config),
    assert_preflight_ok(Resp).

options_on_iap_apple_returns_2xx(Config) ->
    %% IAP routes are auth-gated; preflight must still succeed without a token.
    {ok, Resp} = nova_test:request(options, "/api/v1/iap/apple", #{}, Config),
    assert_preflight_ok(Resp).

options_on_api_matches_returns_2xx(Config) ->
    %% Authed API route — preflight short-circuits before auth runs.
    {ok, Resp} = nova_test:request(options, "/api/v1/matches", #{}, Config),
    assert_preflight_ok(Resp).

options_on_api_wallets_returns_2xx(Config) ->
    {ok, Resp} = nova_test:request(options, "/api/v1/wallets", #{}, Config),
    assert_preflight_ok(Resp).

%% --- Preflight explicitly bypasses auth (no Bearer token) ---

options_on_authed_route_skips_auth(Config) ->
    %% GET /api/v1/matches without auth → 401 (auth plugin rejects).
    {ok, GetResp} = nova_test:request(get, "/api/v1/matches", #{}, Config),
    ?assertEqual(401, maps:get(status, GetResp)),
    %% OPTIONS to the same route without auth → 2xx (CORS plugin short-circuits).
    {ok, OptResp} = nova_test:request(options, "/api/v1/matches", #{}, Config),
    assert_preflight_ok(OptResp).

%% --- CORS headers are present on the preflight response ---

options_preflight_includes_cors_headers(Config) ->
    Opts = #{
        headers => [
            {~"origin", ~"http://localhost:3000"},
            {~"access-control-request-method", ~"POST"},
            {~"access-control-request-headers", ~"content-type"}
        ]
    },
    {ok, Resp} = nova_test:request(options, "/api/v1/auth/register", Opts, Config),
    assert_preflight_ok(Resp),
    ?assertNotEqual(undefined, header(<<"access-control-allow-origin">>, Resp)),
    ?assertNotEqual(undefined, header(<<"access-control-allow-methods">>, Resp)),
    ?assertNotEqual(undefined, header(<<"access-control-allow-headers">>, Resp)).

%% --- Regression: POST /register still works after adding options to methods ---

post_register_still_works(Config) ->
    Username = asobi_test_helpers:unique_username(~"cors_test"),
    {ok, Resp} = nova_test:post(
        "/api/v1/auth/register",
        #{json => #{~"username" => Username, ~"password" => ~"testpass123"}},
        Config
    ),
    ?assertStatus(200, Resp),
    Body = nova_test:json(Resp),
    ?assertMatch(#{~"player_id" := _, ~"session_token" := _}, Body).

%% --- Helpers ---

-spec assert_preflight_ok(nova_test:response()) -> ok.
assert_preflight_ok(#{status := Status} = Resp) ->
    %% nova_cors_plugin replies 200 on OPTIONS short-circuit.
    case Status =:= 200 orelse Status =:= 204 of
        true ->
            ok;
        false ->
            ct:fail({preflight_status_unexpected, Status, Resp})
    end.

-spec header(binary(), nova_test:response()) -> binary() | undefined.
header(Name, #{headers := Headers}) ->
    case lists:keyfind(binary_to_list(Name), 1, Headers) of
        {_, Value} -> list_to_binary(Value);
        false -> undefined
    end.
