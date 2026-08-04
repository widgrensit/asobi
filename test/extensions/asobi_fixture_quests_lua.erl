-module(asobi_fixture_quests_lua).
-moduledoc """
The Lua bindings `asobi_fixture_quests_extension:lua/0` declares.

`progress/2` records its call in the process dictionary so a test can tell
"the binding was reached" from "the binding returned something plausible" -
the distinction the whole Wave 2b change is about. It is also the `write`
binding, so the same counter proves a probe VM stubbed it out.
""".

-export([progress/2, status/1, calls/0, reset/0]).

-define(KEY, {?MODULE, calls}).

-spec progress(binary(), integer()) -> {ok, integer()} | {error, binary()}.
progress(_PlayerId, Amount) when Amount < 0 ->
    {error, ~"amount must not be negative"};
progress(PlayerId, Amount) ->
    erlang:put(?KEY, [{PlayerId, Amount} | calls()]),
    {ok, Amount}.

-spec status(binary()) -> {ok, map()} | {error, binary()} | not_the_contract.
status(~"boom") ->
    error(deliberate);
status(~"wrong") ->
    not_the_contract;
status(PlayerId) ->
    {ok, #{~"player_id" => PlayerId, ~"completed" => 3}}.

-spec calls() -> [{binary(), integer()}].
calls() ->
    case erlang:get(?KEY) of
        undefined -> [];
        Calls -> Calls
    end.

-spec reset() -> ok.
reset() ->
    _ = erlang:erase(?KEY),
    ok.
