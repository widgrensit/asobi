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
-spec calls() -> [{atom(), binary()}].
calls() ->
    lists:reverse(persistent_term:get(?CALLS, [])).

-doc "What this extension's export path does: `{ok, Data}`, `{error, R}` or `{raise, R}`.".
-spec outcome(atom(), term()) -> ok.
outcome(Name, Outcome) ->
    persistent_term:put(?OUTCOMES, maps:put(Name, Outcome, persistent_term:get(?OUTCOMES, #{}))).

-spec run(atom(), binary()) -> term().
run(Name, PlayerId) ->
    persistent_term:put(?CALLS, [{Name, PlayerId} | persistent_term:get(?CALLS, [])]),
    case maps:get(Name, persistent_term:get(?OUTCOMES, #{}), {ok, #{~"rows" => [PlayerId]}}) of
        {raise, Reason} -> error(Reason);
        Outcome -> Outcome
    end.
