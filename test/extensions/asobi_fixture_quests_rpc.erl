-module(asobi_fixture_quests_rpc).
-moduledoc """
The RPC handlers `asobi_fixture_quests_extension:rpc/0` declares.

Every branch of the handler contract, in one place: an ok result, an
extension-declared code, an extension code with details, a code nobody
declared, a return outside the contract, a raise, and a result that cannot be
JSON-encoded. Which branch runs is chosen by `params`, so one fixture covers
the whole mapping without seven manifest entries.
""".

-export([list/2, claim/2]).

-spec list(asobi_rpc:params(), asobi_rpc:ctx()) -> asobi_rpc:reply().
list(Params, #{player_id := PlayerId, method := Method}) ->
    {ok, #{
        ~"player_id" => PlayerId,
        ~"method" => Method,
        ~"echo" => maps:get(~"echo", Params, null)
    }}.

-spec claim(asobi_rpc:params(), asobi_rpc:ctx()) -> asobi_rpc:reply() | banana | no_return().
claim(#{~"behaviour" := ~"declared_code"}, _Ctx) ->
    {error, ~"quests.already_claimed"};
claim(#{~"behaviour" := ~"declared_code_details"}, _Ctx) ->
    {error, ~"quests.not_found", #{~"quest_id" => ~"q-404"}};
claim(#{~"behaviour" := ~"undeclared_code"}, _Ctx) ->
    {error, ~"quests.never_declared"};
claim(#{~"behaviour" := ~"bad_return"}, _Ctx) ->
    banana;
claim(#{~"behaviour" := ~"raise"}, _Ctx) ->
    error(deliberate);
claim(#{~"behaviour" := ~"unencodable"}, _Ctx) ->
    {ok, #{~"pid" => self()}};
claim(_Params, #{player_id := PlayerId}) ->
    {ok, #{~"claimed_by" => PlayerId, ~"reward" => 100}}.
