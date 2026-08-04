-module(asobi_rpc_tests).

-include_lib("eunit/include/eunit.hrl").

-define(QUESTS, asobi_fixture_quests).
-define(PLAYER, ~"p-1").

rpc_test_() ->
    {foreach, fun setup/0, fun cleanup/1, [
        fun a_declared_method_is_actually_called/0,
        fun the_handler_sees_its_caller_and_its_method/0,
        fun params_reach_the_handler/0,
        fun an_undeclared_method_is_not_found/0,
        fun an_unresolved_registry_serves_no_method/0,
        fun an_extension_error_keeps_its_own_code/0,
        fun an_extension_error_carries_its_details/0,
        fun an_undeclared_code_does_not_reach_the_client/0,
        fun a_handler_that_raises_is_internal/0,
        fun a_handler_outside_the_contract_is_internal/0,
        fun a_result_that_cannot_be_encoded_is_internal/0,
        fun an_unauthenticated_caller_is_refused_before_lookup/0,
        fun a_not_ready_node_refuses_every_call/0,
        fun the_protocol_version_is_checked/0,
        fun params_must_be_an_object/0,
        fun the_cid_is_validated_and_echoed/0,
        fun a_rejected_cid_is_not_echoed_back/0
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

%% --- The gap this closes ---
%%
%% `rpc/0` was validated and then read by nothing. These assert the call
%% actually lands in the extension's module, not that the declaration parses.

a_declared_method_is_actually_called() ->
    {Cid, Outcome} = call(~"c-1", ~"quests.claim", #{}),
    ?assertEqual(~"c-1", Cid),
    ?assertEqual({ok, #{~"claimed_by" => ?PLAYER, ~"reward" => 100}}, Outcome).

the_handler_sees_its_caller_and_its_method() ->
    {_Cid, {ok, Result}} = call(~"c-2", ~"quests.list", #{}),
    ?assertMatch(#{~"player_id" := ?PLAYER, ~"method" := ~"quests.list"}, Result).

params_reach_the_handler() ->
    {_Cid, {ok, Result}} = call(~"c-3", ~"quests.list", #{~"echo" => ~"hello"}),
    ?assertEqual(~"hello", maps:get(~"echo", Result)).

an_undeclared_method_is_not_found() ->
    ?assertEqual(~"rpc.unknown_method", code(call(~"c-4", ~"quests.nope", #{}))).

%% The dispatch path reads a persistent_term, never `resolve/0`: a request
%% must not be able to trigger discovery. With nothing resolved the table is
%% empty rather than absent, so the answer is a 404, not a crash.
an_unresolved_registry_serves_no_method() ->
    asobi_extensions:reset(),
    ?assertEqual(#{}, asobi_extensions:rpc_methods()),
    ?assertEqual(~"rpc.unknown_method", code(call(~"c-5", ~"quests.claim", #{}))).

%% --- Errors ---
%%
%% #364 let an extension mint codes in its own domain. An RPC failure must
%% surface as that code; answering `internal` would hide the extension's own
%% contract behind a core defect.

an_extension_error_keeps_its_own_code() ->
    Outcome = call(~"c-6", ~"quests.claim", #{~"behaviour" => ~"declared_code"}),
    ?assertEqual(~"quests.already_claimed", code(Outcome)),
    ?assertEqual(~"This quest was already claimed.", message(Outcome)).

an_extension_error_carries_its_details() ->
    Outcome = call(~"c-7", ~"quests.claim", #{~"behaviour" => ~"declared_code_details"}),
    ?assertEqual(~"quests.not_found", code(Outcome)),
    ?assertEqual(#{~"quest_id" => ~"q-404"}, details(Outcome)).

%% The code set is closed, and every other call site's code is a binary literal
%% checked at build time by asobi_error_contract_tests. A handler's is a runtime
%% term it could have built from `params`, so the same guarantee is enforced
%% here instead: an undeclared code is logged and answered as `internal` rather
%% than reflected to a client that may branch on it.
an_undeclared_code_does_not_reach_the_client() ->
    Outcome = call(~"c-8", ~"quests.claim", #{~"behaviour" => ~"undeclared_code"}),
    ?assertEqual(~"internal", code(Outcome)),
    ?assertNot(lists:member(~"quests.never_declared", asobi_error:codes())).

a_handler_that_raises_is_internal() ->
    ?assertEqual(~"internal", code(call(~"c-9", ~"quests.claim", #{~"behaviour" => ~"raise"}))).

a_handler_outside_the_contract_is_internal() ->
    ?assertEqual(
        ~"internal", code(call(~"c-10", ~"quests.claim", #{~"behaviour" => ~"bad_return"}))
    ).

%% Encoding happens where the method is known, so a handler returning a pid
%% is reported as that method's failure rather than crashing the connection
%% process and answering with a generic socket error.
a_result_that_cannot_be_encoded_is_internal() ->
    ?assertEqual(
        ~"internal", code(call(~"c-11", ~"quests.claim", #{~"behaviour" => ~"unencodable"}))
    ).

%% --- Gates ---

an_unauthenticated_caller_is_refused_before_lookup() ->
    Outcome = asobi_rpc:handle(~"c-13", payload(~"quests.claim", #{}), unauthenticated),
    ?assertEqual(~"unauthenticated", code(Outcome)).

%% The route table compiles inside nova_sup:init/1 and migrations run after it,
%% so a socket is reachable before an extension's tables exist.
a_not_ready_node_refuses_every_call() ->
    asobi_readiness:reset(),
    Outcome = call(~"c-14", ~"quests.claim", #{}),
    ?assertEqual(~"not_ready", code(Outcome)),
    ?assertEqual(503, asobi_error:status(code(Outcome))).

the_protocol_version_is_checked() ->
    Outcome = asobi_rpc:handle(
        ~"c-15",
        #{~"protocol" => 99, ~"method" => ~"quests.claim", ~"params" => #{}},
        caller()
    ),
    ?assertEqual(~"rpc.unsupported_protocol", code(Outcome)),
    ?assertEqual(#{supported => [1]}, details(Outcome)).

params_must_be_an_object() ->
    Outcome = asobi_rpc:handle(
        ~"c-16",
        #{~"protocol" => 1, ~"method" => ~"quests.claim", ~"params" => [1, 2, 3]},
        caller()
    ),
    ?assertEqual(~"rpc.invalid_params", code(Outcome)).

%% --- cid ---

the_cid_is_validated_and_echoed() ->
    {Cid, {ok, _}} = call(~"corr-42", ~"quests.claim", #{}),
    ?assertEqual(~"corr-42", Cid).

%% The value is reflected into a frame, so a rejected one has nothing
%% trustworthy to echo and the reply carries no cid at all.
a_rejected_cid_is_not_echoed_back() ->
    Bad = [
        undefined,
        17,
        ~"",
        binary:copy(~"x", 65),
        <<"tab\there">>,
        <<200, 201>>
    ],
    [
        ?assertEqual(
            {undefined, {error, asobi_error:object(~"rpc.invalid_cid")}},
            asobi_rpc:handle(Cid, payload(~"quests.claim", #{}), caller())
        )
     || Cid <- Bad
    ],
    ?assertMatch({~"ok-cid", _}, call(~"ok-cid", ~"quests.claim", #{})).

%% --- helpers ---

call(Cid, Method, Params) ->
    asobi_rpc:handle(Cid, payload(Method, Params), caller()).

payload(Method, Params) ->
    #{~"protocol" => asobi_rpc:protocol(), ~"method" => Method, ~"params" => Params}.

caller() ->
    #{player_id => ?PLAYER, session => self()}.

%% The `{error, Object}` clause leads: an outcome's tag is the atom `error`,
%% and a `{Cid, Outcome}` pair's first element never is.
code({error, #{error := #{code := Code}}}) -> Code;
code({_Cid, Outcome}) -> code(Outcome).

message({error, #{error := #{message := Message}}}) -> Message;
message({_Cid, Outcome}) -> message(Outcome).

details({error, #{error := #{details := Details}}}) -> Details;
details({_Cid, Outcome}) -> details(Outcome).
