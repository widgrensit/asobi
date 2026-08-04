-module(asobi_fixture_erase).
-moduledoc """
The erase paths of the fixture extensions, and a record of what was called.

Two extensions must be observable in one run to pin ordering, and a manifest
module has to be named after its own application, so the recording lives here
and each fixture's `erase_player/1` delegates to it.
""".

-export([reset/0, calls/0, outcome/2, run/2]).

-define(CALLS, {?MODULE, calls}).
-define(OUTCOMES, {?MODULE, outcomes}).

-spec reset() -> ok.
reset() ->
    _ = persistent_term:erase(?CALLS),
    _ = persistent_term:erase(?OUTCOMES),
    ok.

-doc "Every `erase_player/1` call, in the order core made them.".
-spec calls() -> [{atom(), binary()}].
calls() ->
    lists:reverse(persistent_term:get(?CALLS, [])).

-doc "What this extension's erase path does: `ok`, `{error, R}` or `{raise, R}`.".
-spec outcome(atom(), term()) -> ok.
outcome(Name, Outcome) ->
    persistent_term:put(?OUTCOMES, maps:put(Name, Outcome, persistent_term:get(?OUTCOMES, #{}))).

-spec run(atom(), binary()) -> ok | {error, term()}.
run(Name, PlayerId) ->
    persistent_term:put(?CALLS, [{Name, PlayerId} | persistent_term:get(?CALLS, [])]),
    case maps:get(Name, persistent_term:get(?OUTCOMES, #{}), ok) of
        {raise, Reason} -> error(Reason);
        Outcome -> Outcome
    end.
