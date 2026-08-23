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
    %% persistent_term is a boundary; narrowed at the read, and lists:reverse/1
    %% widens on the way back. See docs/eqwalizer-idioms.md.
    case persistent_term:get(?CALLS, []) of
        Calls when is_list(Calls) ->
            [{N, P} || {N, P} <- lists:reverse(Calls), is_atom(N), is_binary(P)]
    end.

-doc "What this extension's erase path does: `ok`, `{error, R}` or `{raise, R}`.".
-spec outcome(atom(), term()) -> ok.
outcome(Name, Outcome) ->
    Current =
        case persistent_term:get(?OUTCOMES, #{}) of
            M when is_map(M) -> M
        end,
    persistent_term:put(?OUTCOMES, maps:put(Name, Outcome, Current)).

%% `term()`, not `ok | {error, _}`: this fixture exists to hand core values
%% that are OUTSIDE the erase contract, so that core's own validation can be
%% tested. asobi_extension_erase_tests configures `other` and asserts core
%% answers `{bad_return, other}`. Narrowing the return here turned that into a
%% case_clause inside the fixture - the trap docs/eqwalizer-idioms.md warns
%% about, met in the wild.
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
    case maps:get(Name, Outcomes, ok) of
        {raise, Reason} -> error(Reason);
        Outcome -> Outcome
    end.
