-module(asobi_extension_routes_SUITE).
-moduledoc """
The declared route seam, over a real server.

Unit tests prove declaration, validation and the compiled table. This proves
the wiring: a fixture extension's route serving through the running node, the
player-token chain refusing exactly as it refuses on a core route, a webhook
route open to a caller with no token, and an uninstalled extension's path
answering as any unknown route does - which is where a route group, a plugin
list or a security callback goes wrong without any unit test noticing.
""".

-include_lib("nova_test/include/nova_test.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([
    a_mounted_route_serves_authenticated_traffic/1,
    the_global_plugin_chain_applies/1,
    an_unauthenticated_request_gets_the_core_refusal/1,
    a_webhook_route_needs_no_player_token/1,
    the_404_discipline_is_path_level/1
]).

-define(QUESTS, asobi_fixture_quests).

all() ->
    [
        a_mounted_route_serves_authenticated_traffic,
        the_global_plugin_chain_applies,
        an_unauthenticated_request_gets_the_core_refusal,
        a_webhook_route_needs_no_player_token,
        the_404_discipline_is_path_level
    ].

%% The route table compiles inside Nova's boot, so unlike the RPC suite the
%% fixture must be installed before the node starts - there is no memo to
%% clear afterwards, a route either was mounted or was not. Another suite may
%% have booted the node already; restarting nova is what recompiles the table
%% (nova_app:prep_stop/1 closes the listener, so the port is free again). If
%% the boot then fails, the fixture must not stay loaded for whichever suite
%% runs next.
init_per_suite(Config) ->
    restart([
        fun() -> ok = asobi_fixture_app:install(?QUESTS, asobi_fixture_quests_extension, []) end
    ]),
    try
        asobi_test_helpers:start(Config)
    catch
        Class:Reason:Stack ->
            asobi_fixture_app:uninstall(?QUESTS),
            asobi_extensions:reset(),
            erlang:raise(Class, Reason, Stack)
    end.

%% Restarted without the fixture so later suites compile a clean table.
end_per_suite(Config) ->
    restart([fun() -> asobi_fixture_app:uninstall(?QUESTS) end]),
    _ = asobi_test_helpers:start(Config),
    Config.

%% The telemetry handler survives an application stop - telemetry itself
%% keeps running - and `asobi_telemetry:setup/0` refuses a duplicate id, so
%% a restart in the same VM must detach it first (ensure_all_started because
%% this suite may also be the first boot, with no telemetry to ask). Only
%% this suite restarts.
restart(Steps) ->
    _ = application:stop(asobi),
    _ = application:stop(nova),
    {ok, _} = application:ensure_all_started(telemetry),
    _ = telemetry:detach(~"asobi-metrics-logger"),
    _ = [Step() || Step <- Steps],
    asobi_extensions:reset(),
    ok.

a_mounted_route_serves_authenticated_traffic(Config) ->
    {PlayerId, Token} = register_player(~"extroute", Config),
    {ok, Resp} = nova_test:get(
        "/api/v1/quests/board",
        #{headers => [{~"authorization", <<"Bearer ", Token/binary>>}]},
        Config
    ),
    ?assertEqual(200, nova_test:status(Resp)),
    ?assertEqual(#{~"player_id" => PlayerId, ~"quests" => []}, nova_test:json(Resp)),
    Config.

%% The mount sits inside core's global plugin chain and lists `options` on
%% every entry, exactly as core routes do: a tokenless CORS preflight is
%% intercepted by the global plugin and answers 2xx with the CORS headers,
%% never 401 from the security callback or 405 from the router.
the_global_plugin_chain_applies(Config) ->
    Opts = #{
        headers => [
            {~"origin", ~"http://localhost:3000"},
            {~"access-control-request-method", ~"GET"}
        ]
    },
    {ok, Resp} = nova_test:request(options, "/api/v1/quests/board", Opts, Config),
    Status = nova_test:status(Resp),
    ?assert(Status >= 200 andalso Status < 300),
    ?assertNotEqual(undefined, nova_test:header("access-control-allow-origin", Resp)),
    Config.

%% `security => player` is core's own chain, not one shaped like it: a bare
%% request is refused with the same status a core route gives it.
an_unauthenticated_request_gets_the_core_refusal(Config) ->
    {ok, Resp} = nova_test:get("/api/v1/quests/board", Config),
    {ok, CoreResp} = nova_test:get("/api/v1/matches", Config),
    ?assertEqual(nova_test:status(CoreResp), nova_test:status(Resp)),
    ?assertEqual(401, nova_test:status(Resp)),
    Config.

a_webhook_route_needs_no_player_token(Config) ->
    {ok, Resp} = nova_test:post(
        "/api/v1/quests/webhook",
        #{json => #{~"receipt" => ~"abc-123"}},
        Config
    ),
    ?assertEqual(200, nova_test:status(Resp)),
    ?assertEqual(#{~"received" => #{~"receipt" => ~"abc-123"}}, nova_test:json(Resp)),
    %% The dedicated webhook bucket (limit 10), not the 300/s api one: the
    %% remaining budget after one request gives the bucket away.
    Remaining =
        case nova_test:header("x-ratelimit-remaining", Resp) of
            undefined -> ct:fail(missing_rate_limit_header);
            Value -> list_to_integer(Value)
        end,
    ?assert(Remaining < 10),
    Config.

%% The 404 discipline is path-level: a path the installed set never declared
%% answers 404 exactly as a path that never meant anything, while a
%% wrong-method probe on a mounted path answers 405 with an allow header,
%% as on any core route - method enumeration on declared paths is the
%% accepted trade, not a leak this suite pretends is closed.
the_404_discipline_is_path_level(Config) ->
    {ok, Resp} = nova_test:get("/api/v1/quests/undeclared", Config),
    ?assertEqual(404, nova_test:status(Resp)),
    {ok, WrongMethod} = nova_test:delete("/api/v1/quests/board", Config),
    ?assertEqual(405, nova_test:status(WrongMethod)),
    ?assertNotEqual(undefined, nova_test:header("allow", WrongMethod)),
    {ok, CoreWrongMethod} = nova_test:delete("/api/v1/matches", Config),
    ?assertEqual(nova_test:status(CoreWrongMethod), nova_test:status(WrongMethod)),
    Config.

%% --- helpers (mirrors asobi_rpc_SUITE) ---

register_player(Suffix, Config) ->
    Username = <<"extr_", Suffix/binary, "_", (asobi_id:rand_suffix(4))/binary>>,
    {ok, Resp} = nova_test:post(
        "/api/v1/auth/register",
        #{json => #{~"username" => Username, ~"password" => ~"testpass123"}},
        Config
    ),
    #{~"player_id" := PlayerId, ~"access_token" := Token} = nova_test:json(Resp),
    {PlayerId, Token}.
