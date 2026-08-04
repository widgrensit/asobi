-module(asobi_fixture_quests_ops).
-moduledoc "Operator actions for the quests fixture, plus a record of the calls.".

-export([define/2, summary/2, raises/2, undeclared_code/2, off_contract/2]).
-export([reset/0, calls/0]).

-define(KEY, {?MODULE, calls}).

-spec define(map(), asobi_ops_extension:ctx()) -> asobi_rpc:reply().
define(#{~"key" := ~"taken"}, _Ctx) ->
    {error, ~"quests.not_found"};
define(Params, #{actor := #{id := ActorId}} = Ctx) ->
    record({define, Params, Ctx}),
    {ok, #{~"defined" => maps:get(~"key", Params, ~""), ~"by" => ActorId}}.

-spec summary(map(), asobi_ops_extension:ctx()) -> asobi_rpc:reply().
summary(Params, Ctx) ->
    record({summary, Params, Ctx}),
    {ok, #{~"count" => 2, ~"filter" => maps:get(~"filter", Params, ~"all")}}.

-spec raises(map(), asobi_ops_extension:ctx()) -> no_return().
raises(_Params, _Ctx) ->
    error(deliberate).

-spec undeclared_code(map(), asobi_ops_extension:ctx()) -> asobi_rpc:reply().
undeclared_code(_Params, _Ctx) ->
    {error, ~"quests.never_declared"}.

-spec off_contract(map(), asobi_ops_extension:ctx()) -> term().
off_contract(_Params, _Ctx) ->
    surprise.

-spec reset() -> ok.
reset() ->
    persistent_term:put(?KEY, []).

-spec calls() -> [term()].
calls() ->
    lists:reverse(persistent_term:get(?KEY, [])).

record(Call) ->
    persistent_term:put(?KEY, [Call | persistent_term:get(?KEY, [])]).
