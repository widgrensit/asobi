-module(asobi_rpc_http_SUITE).
-moduledoc """
The extension RPC wire over HTTP.

`POST /api/v1/rpc/<method>` reaching the same dispatcher the socket `rpc.call`
frame does, through the real Nova stack - the player-token security callback,
the global plugin chain, `asobi_rpc_controller`. The socket path is proved in
asobi_rpc_SUITE; this proves the HTTP transport answers with the same
`rpc.ok` / `rpc.error` envelope and the code's own HTTP status, and that the
group refuses a tokenless request before the controller.
""".

-include_lib("nova_test/include/nova_test.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([
    rpc_call_reaches_the_extension/1,
    rpc_error_carries_the_extensions_own_code/1,
    rpc_unknown_method/1,
    rpc_requires_an_authenticated_request/1,
    rpc_rejects_non_object_params/1
]).

-define(QUESTS, asobi_fixture_quests).

all() ->
    [
        rpc_call_reaches_the_extension,
        rpc_error_carries_the_extensions_own_code,
        rpc_unknown_method,
        rpc_requires_an_authenticated_request,
        rpc_rejects_non_object_params
    ].

%% The rpc route is core-owned and always in the compiled table, so unlike the
%% extension-routes suite no restart is needed: the fixture is installed and the
%% memoised registry re-resolved, exactly as asobi_rpc_SUITE does for the
%% socket path.
init_per_suite(Config) ->
    Config1 = asobi_test_helpers:start(Config),
    ok = asobi_fixture_app:install(?QUESTS, asobi_fixture_quests_extension, []),
    asobi_extensions:reset(),
    _ = asobi_extensions:resolve(),
    Config1.

end_per_suite(Config) ->
    asobi_fixture_app:uninstall(?QUESTS),
    asobi_extensions:reset(),
    _ = asobi_extensions:resolve(),
    Config.

rpc_call_reaches_the_extension(Config) ->
    {PlayerId, Token} = register_player(~"ok", Config),
    {ok, Resp} = rpc_post(~"quests.list", #{~"echo" => ~"pong"}, Token, Config),
    ?assertEqual(200, nova_test:status(Resp)),
    ?assertMatch(#{~"type" := ~"rpc.ok", ~"payload" := #{~"result" := _}}, nova_test:json(Resp)),
    #{~"payload" := #{~"result" := Result}} = nova_test:json(Resp),
    ?assertEqual(
        #{~"player_id" => PlayerId, ~"method" => ~"quests.list", ~"echo" => ~"pong"},
        Result
    ),
    Config.

%% #364 gave an extension its own code domain. The HTTP status is that code's
%% own (409), not a flattened 400/500.
rpc_error_carries_the_extensions_own_code(Config) ->
    {_, Token} = register_player(~"err", Config),
    {ok, Resp} = rpc_post(~"quests.claim", #{~"behaviour" => ~"declared_code"}, Token, Config),
    ?assertEqual(409, nova_test:status(Resp)),
    ?assertMatch(
        #{
            ~"type" := ~"rpc.error",
            ~"payload" := #{
                ~"error" := #{
                    ~"code" := ~"quests.already_claimed",
                    ~"message" := ~"This quest was already claimed.",
                    ~"details" := #{}
                }
            }
        },
        nova_test:json(Resp)
    ),
    Config.

rpc_unknown_method(Config) ->
    {_, Token} = register_player(~"unk", Config),
    {ok, Resp} = rpc_post(~"quests.nothing_here", #{}, Token, Config),
    ?assertEqual(404, nova_test:status(Resp)),
    ?assertMatch(
        #{
            ~"type" := ~"rpc.error",
            ~"payload" := #{~"error" := #{~"code" := ~"rpc.unknown_method"}}
        },
        nova_test:json(Resp)
    ),
    Config.

%% The group security refuses a tokenless request before the controller, the
%% same 401 a core route in this group gives - consistent with dispatch's own
%% unauthenticated branch always erroring.
rpc_requires_an_authenticated_request(Config) ->
    {ok, Resp} = nova_test:post(
        "/api/v1/rpc/quests.claim",
        #{json => #{~"params" => #{}}},
        Config
    ),
    ?assertEqual(401, nova_test:status(Resp)),
    Config.

rpc_rejects_non_object_params(Config) ->
    {_, Token} = register_player(~"param", Config),
    {ok, Resp} = rpc_post(~"quests.claim", [1, 2, 3], Token, Config),
    ?assertEqual(400, nova_test:status(Resp)),
    ?assertMatch(
        #{
            ~"type" := ~"rpc.error",
            ~"payload" := #{~"error" := #{~"code" := ~"rpc.invalid_params"}}
        },
        nova_test:json(Resp)
    ),
    Config.

%% --- helpers (mirrors asobi_rpc_SUITE) ---

rpc_post(Method, Params, Token, Config) ->
    nova_test:post(
        binary_to_list(<<"/api/v1/rpc/", Method/binary>>),
        #{
            json => #{~"params" => Params},
            headers => [{~"authorization", <<"Bearer ", Token/binary>>}]
        },
        Config
    ).

register_player(Suffix, Config) ->
    Username = <<"rpch_", Suffix/binary, "_", (asobi_id:rand_suffix(4))/binary>>,
    {ok, Resp} = nova_test:post(
        "/api/v1/auth/register",
        #{json => #{~"username" => Username, ~"password" => ~"testpass123"}},
        Config
    ),
    #{~"player_id" := PlayerId, ~"access_token" := Token} = nova_test:json(Resp),
    {PlayerId, Token}.
