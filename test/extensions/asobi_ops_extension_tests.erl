-module(asobi_ops_extension_tests).

-include_lib("eunit/include/eunit.hrl").

-define(QUESTS, asobi_fixture_quests).
-define(ACTOR, #{
    id => ~"op-1",
    display => ~"operator",
    source => static_secret,
    caps => [read, player_data, config],
    attested => false
}).

%% `ops/0` was the answer to the one gap the first extension filed that #365
%% deliberately left open: an extension had nowhere to put an operator action,
%% because `rpc/0` is player-scoped and a player never holds an operator
%% capability. These assertions are the difference between "the declaration is
%% well-formed" and "an operator can call it".

extension_ops_test_() ->
    {foreach, fun setup/0, fun cleanup/1, [
        fun a_declared_action_is_dispatched/0,
        fun a_read_action_gets_the_query_string/0,
        fun the_actor_reaches_the_handler/0,
        fun a_declared_code_survives/0,
        fun an_undeclared_code_is_a_defect/0,
        fun a_raising_handler_is_a_defect/0,
        fun an_off_contract_return_is_a_defect/0,
        fun an_unknown_action_answers_as_the_gate_did/0,
        fun a_write_is_audited/0,
        fun a_read_is_not_audited/0,
        fun nothing_is_served_before_migrations/0
    ]}.

setup() ->
    asobi_extensions:reset(),
    asobi_fixture_quests_ops:reset(),
    ok = asobi_fixture_app:install(?QUESTS, asobi_fixture_quests_extension, []),
    _ = asobi_extensions:resolve(),
    asobi_readiness:mark_ready(),
    meck:new(asobi_ops_audit, [passthrough, no_link]),
    meck:expect(asobi_ops_audit, mutation, fun(_Actor, Action, Target, Fun) ->
        persistent_term:put({?MODULE, audited}, {Action, Target}),
        Fun()
    end),
    ok.

cleanup(_) ->
    meck:unload(asobi_ops_audit),
    _ = persistent_term:erase({?MODULE, audited}),
    asobi_fixture_app:uninstall(?QUESTS),
    asobi_extensions:reset(),
    asobi_fixture_quests_ops:reset(),
    ok.

%% --- Dispatch ---

a_declared_action_is_dispatched() ->
    ?assertEqual(
        {json, #{~"defined" => ~"daily", ~"by" => ~"op-1"}},
        post(~"quests", ~"define", #{~"key" => ~"daily"})
    ).

a_read_action_gets_the_query_string() ->
    ?assertEqual(
        {json, #{~"count" => 2, ~"filter" => ~"active"}},
        get(~"quests", ~"summary", ~"filter=active")
    ).

the_actor_reaches_the_handler() ->
    _ = post(~"quests", ~"define", #{~"key" => ~"daily"}),
    [{define, _Params, Ctx}] = asobi_fixture_quests_ops:calls(),
    ?assertMatch(#{actor := #{id := ~"op-1"}, extension := ~"quests", action := ~"define"}, Ctx).

%% --- The error contract ---

a_declared_code_survives() ->
    ?assertEqual(
        {asobi_error, ~"quests.not_found", #{}},
        post(~"quests", ~"define", #{~"key" => ~"taken"})
    ).

%% A handler could build a code out of `params`, so a code nobody declared is
%% the extension's defect and answers `internal` rather than minting a status.
an_undeclared_code_is_a_defect() ->
    ?assertEqual({asobi_error, ~"internal"}, dispatch_mfa(undeclared_code)).

a_raising_handler_is_a_defect() ->
    ?assertEqual({asobi_error, ~"internal"}, dispatch_mfa(raises)).

an_off_contract_return_is_a_defect() ->
    ?assertEqual({asobi_error, ~"internal"}, dispatch_mfa(off_contract)).

%% Unreachable through the router - an undeclared action has no class and the
%% security callback denied it - but answered rather than crashed, because a
%% manifest can change under a live request. `forbidden` rather than a 404, so
%% the dispatcher agrees with the gate instead of confirming what is installed.
an_unknown_action_answers_as_the_gate_did() ->
    ?assertEqual({asobi_error, ~"forbidden"}, post(~"quests", ~"nope", #{})),
    ?assertEqual({asobi_error, ~"forbidden"}, post(~"nothing", ~"define", #{})).

%% --- The audit ---

a_write_is_audited() ->
    _ = post(~"quests", ~"define", #{~"key" => ~"daily"}),
    ?assertEqual(
        {~"quests.define", {~"extension", ~"quests"}},
        persistent_term:get({?MODULE, audited}, undefined)
    ).

a_read_is_not_audited() ->
    _ = get(~"quests", ~"summary", ~""),
    ?assertEqual(undefined, persistent_term:get({?MODULE, audited}, undefined)).

%% --- Readiness ---

%% The route table compiles before migrations run, so an action is reachable
%% before its tables exist.
nothing_is_served_before_migrations() ->
    meck:new(asobi_readiness, [passthrough, no_link]),
    meck:expect(asobi_readiness, guard, fun() -> {error, asobi_error:object(~"not_ready")} end),
    try
        ?assertEqual({asobi_error, ~"not_ready"}, post(~"quests", ~"define", #{~"key" => ~"d"}))
    after
        meck:unload(asobi_readiness)
    end.

%% --- Helpers ---

post(Extension, Action, Params) ->
    asobi_ops_extension:handle(req(Extension, Action, #{json => Params})).

get(Extension, Action, Qs) ->
    asobi_ops_extension:handle(req(Extension, Action, #{qs => Qs})).

req(Extension, Action, Extra) ->
    maps:merge(
        #{
            bindings => #{~"extension" => Extension, ~"action" => Action},
            auth_data => #{ops_actor => ?ACTOR}
        },
        Extra
    ).

%% Re-point the declared action at another fixture function, so the handler
%% contract is exercised through the same dispatch a real call takes.
dispatch_mfa(Function) ->
    meck:new(asobi_extensions, [passthrough, no_link]),
    meck:expect(asobi_extensions, ops_action, fun(_Extension, _Action) ->
        #{method => post, mfa => {asobi_fixture_quests_ops, Function, 2}, class => config}
    end),
    try
        post(~"quests", ~"define", #{})
    after
        meck:unload(asobi_extensions)
    end.
