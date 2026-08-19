-module(asobi_rpc_controller_tests).

-include_lib("eunit/include/eunit.hrl").

%% The HTTP transport for the extension RPC dispatcher, without a socket or a
%% database. The quests fixture is installed and resolved the way asobi_rpc's
%% own unit tests do it, so `call/1` runs a real dispatch; a fake Nova req map
%% (bindings + json + auth_data, exactly the keys the plugins set) stands in for
%% the request. The real Nova stack - auth, routing, the body cap - is exercised
%% end to end in asobi_rpc_http_SUITE.

-define(QUESTS, asobi_fixture_quests).
-define(PLAYER, ~"p-1").

controller_test_() ->
    {foreach, fun setup/0, fun cleanup/1, [
        fun a_known_method_answers_200_and_an_rpc_ok_envelope/0,
        fun an_unknown_method_answers_404_and_an_rpc_error_envelope/0,
        fun an_extension_error_carries_its_own_code_and_status/0,
        fun non_map_params_answer_400_and_rpc_invalid_params/0,
        fun absent_params_answer_400_and_rpc_invalid_params/0,
        fun the_controller_marks_the_ctx_transport_http/0,
        fun one_envelope_feeds_both_transports/0
    ]}.

setup() ->
    asobi_extensions:reset(),
    ok = asobi_fixture_app:install(?QUESTS, asobi_fixture_quests_extension, []),
    _ = asobi_extensions:resolve(),
    asobi_readiness:mark_ready(),
    ok.

cleanup(_) ->
    asobi_readiness:reset(),
    asobi_fixture_app:uninstall(?QUESTS),
    asobi_extensions:reset(),
    ok.

a_known_method_answers_200_and_an_rpc_ok_envelope() ->
    {json, Status, _Headers, Body} =
        asobi_rpc_controller:call(req(~"quests.list", #{~"echo" => ~"pong"})),
    ?assertEqual(200, Status),
    ?assertMatch(#{~"type" := ~"rpc.ok", ~"payload" := #{~"result" := _}}, Body),
    #{~"payload" := #{~"result" := Result}} = Body,
    ?assertEqual(
        #{~"player_id" => ?PLAYER, ~"method" => ~"quests.list", ~"echo" => ~"pong"},
        Result
    ).

%% The error object is `asobi_error:object/1`, which keys with atoms - the same
%% term the socket encoder hands `json:encode` - so the in-memory payload here
%% carries atom keys, byte-identical to the WS path once serialised.
an_unknown_method_answers_404_and_an_rpc_error_envelope() ->
    {json, Status, _Headers, Body} = asobi_rpc_controller:call(req(~"quests.nope", #{})),
    ?assertEqual(404, Status),
    ?assertMatch(
        #{~"type" := ~"rpc.error", ~"payload" := #{error := #{code := ~"rpc.unknown_method"}}},
        Body
    ).

%% The status is the extension's own (409 for quests.already_claimed), routed
%% through asobi_error:status/1 exactly as the socket surfaces the code.
an_extension_error_carries_its_own_code_and_status() ->
    {json, Status, _Headers, Body} =
        asobi_rpc_controller:call(req(~"quests.claim", #{~"behaviour" => ~"declared_code"})),
    ?assertEqual(409, Status),
    ?assertMatch(
        #{~"type" := ~"rpc.error", ~"payload" := #{error := #{code := ~"quests.already_claimed"}}},
        Body
    ).

non_map_params_answer_400_and_rpc_invalid_params() ->
    {json, Status, _Headers, Body} = asobi_rpc_controller:call(req(~"quests.claim", [1, 2, 3])),
    ?assertEqual(400, Status),
    ?assertMatch(#{~"payload" := #{error := #{code := ~"rpc.invalid_params"}}}, Body).

%% Neither a `params` key nor a body at all reaches the dispatcher as
%% `undefined`, which it rejects the same way it rejects a non-object. The req
%% maps live in unspecced helpers so eqwalizer reads them as `dynamic()` and
%% accepts them against `cowboy_req:req()`, the pattern asobi_storage_controller_tests
%% uses (an inline literal req gets its precise shape inferred and rejected).
absent_params_answer_400_and_rpc_invalid_params() ->
    ?assertMatch(
        {json, 400, _, #{~"payload" := #{error := #{code := ~"rpc.invalid_params"}}}},
        asobi_rpc_controller:call(no_params_req())
    ),
    ?assertMatch(
        {json, 400, _, #{~"payload" := #{error := #{code := ~"rpc.invalid_params"}}}},
        asobi_rpc_controller:call(no_body_req())
    ).

%% The controller tags its caller `transport => http`, so a handler reading
%% Ctx.transport sees `http` (handle/3's `ws` default is asserted in
%% asobi_rpc_tests).
the_controller_marks_the_ctx_transport_http() ->
    {json, 200, _Headers, Body} =
        asobi_rpc_controller:call(req(~"quests.claim", #{~"behaviour" => ~"ctx_transport"})),
    ?assertMatch(
        #{~"type" := ~"rpc.ok", ~"payload" := #{~"result" := #{~"transport" := ~"http"}}},
        Body
    ).

%% The controller body's {type, payload} is asobi_rpc:envelope/1 applied to the
%% dispatch outcome, and the socket encoder (asobi_ws_handler:encode_rpc/2)
%% builds its frame from the same envelope/1 - so one outcome maps to one wire
%% payload on both transports. Pin envelope/1 against the shipped fixtures the
%% WS CT and every SDK dispatch-test against, closing the loop.
one_envelope_feeds_both_transports() ->
    Params = #{~"echo" => ~"pong"},
    Payload = #{
        ~"protocol" => asobi_rpc:protocol(),
        ~"method" => ~"quests.list",
        ~"params" => Params
    },
    Outcome = asobi_rpc:dispatch(Payload, #{player_id => ?PLAYER, session => self()}),
    {Type, Wire} = asobi_rpc:envelope(Outcome),
    {json, 200, _Headers, Body} = asobi_rpc_controller:call(req(~"quests.list", Params)),
    ?assertEqual(#{~"type" => Type, ~"payload" => Wire}, Body),
    assert_matches_fixture("rpc.ok", asobi_rpc:envelope({ok, #{~"reward" => 100}})),
    assert_matches_fixture(
        "rpc.error", asobi_rpc:envelope({error, asobi_error:object(~"quests.already_claimed")})
    ).

%% --- helpers ---

req(Method, Params) ->
    #{
        bindings => #{~"method" => Method},
        json => #{~"params" => Params},
        auth_data => #{player_id => ?PLAYER}
    }.

no_params_req() ->
    #{
        bindings => #{~"method" => ~"quests.claim"},
        json => #{},
        auth_data => #{player_id => ?PLAYER}
    }.

no_body_req() ->
    #{bindings => #{~"method" => ~"quests.claim"}, auth_data => #{player_id => ?PLAYER}}.

%% The fixture is the wire ground truth minus the transport's own `cid`, so
%% compare type and payload after a JSON round-trip that normalises the object's
%% atom keys to the binary keys the fixture carries.
assert_matches_fixture(Name, {Type, Wire}) ->
    {ok, Bin} = file:read_file("priv/protocol/fixtures/" ++ Name ++ ".json"),
    #{~"type" := FixtureType, ~"payload" := FixturePayload} = json:decode(Bin),
    Encoded = iolist_to_binary(json:encode(#{~"type" => Type, ~"payload" => Wire})),
    RoundTripped = json:decode(Encoded),
    ?assertEqual(#{~"type" => FixtureType, ~"payload" => FixturePayload}, RoundTripped).
