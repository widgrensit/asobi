-module(asobi_fixture_export).
-moduledoc """
The export paths of the fixture extensions, and a record of what was called.

The same shape as `m:asobi_fixture_erase`, for the same reason: two extensions
must be observable in one run to pin ordering, and a manifest module has to be
named after its own application, so the recording lives here and each
fixture's `export_player/1` delegates to it.
""".

-export([reset/0, calls/0, outcome/2, run/2]).

-define(CALLS, {?MODULE, calls}).
-define(OUTCOMES, {?MODULE, outcomes}).

-spec reset() -> ok.
reset() ->
    _ = persistent_term:erase(?CALLS),
    _ = persistent_term:erase(?OUTCOMES),
    ok.

-doc "Every `export_player/1` call, in the order core made them.".
-spec calls() -> [term()].
calls() ->
    %% No guards on the elements: this is the observation side of a fixture
    %% whose whole job is catching a call core should not have made. Filtering
    %% a malformed record out here would hide exactly what a test is looking
    %% for, the same way narrowing run/2's return did.
    case persistent_term:get(?CALLS, []) of
        Calls when is_list(Calls) -> lists:reverse(Calls)
    end.

-doc "What this extension's export path does: `{ok, Data}`, `{error, R}` or `{raise, R}`.".
-spec outcome(atom(), term()) -> ok.
outcome(Name, Outcome) ->
    Current =
        case persistent_term:get(?OUTCOMES, #{}) of
            M when is_map(M) -> M
        end,
    persistent_term:put(?OUTCOMES, maps:put(Name, Outcome, Current)).

-spec run(atom(), binary()) -> term().
run(Name, PlayerId) ->
    Calls =
        case persistent_term:get(?CALLS, []) of
            L when is_list(L) -> L
        end,
    persistent_term:put(?CALLS, [{Name, PlayerId} | Calls]),
    Outcomes =
        case persistent_term:get(?OUTCOMES, #{}) of
            M when is_map(M) -> M
        end,
    case maps:get(Name, Outcomes, {ok, #{~"rows" => [PlayerId]}}) of
        {raise, Reason} -> error(Reason);
        Outcome -> Outcome
    end.
