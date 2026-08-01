-module(asobi_script_log_limiter).
-moduledoc """
Bounds the rate of *log lines* emitted from per-tick, script-driven error
paths - a game script that fails on every tick (a typo'd spawn template, a
Lua callback that always raises) would otherwise log once per tick forever
(asobi#252). Telemetry counters are unaffected: `asobi_telemetry:game_error/2`
is cheap to aggregate at any volume and callers should keep emitting it
unconditionally so dashboards/alerts see the true failure rate. Only the
disk/log-aggregator cost of the structured log line itself is bounded here.

Backed by the existing `seki` limiter (`asobi_script_log_limiter`,
registered in `asobi_sup`), keyed per call site by whatever the caller
considers "the same recurring failure" - typically `{WorldId, Coords}` for
a zone or `{Script, Callback}` for a Lua callback. Suppressed calls are not
silently dropped: `allow/1` returns how many were suppressed since the last
allowed call, so the next log line that does get through can say "and N
more like this were suppressed" instead of the gap just looking like the
failure stopped.
""".

-export([allow/1, forget/1, init_table/0]).

-define(DROP_TABLE, asobi_script_log_limiter_drops).

-doc "Create the drop-count table once at boot (asobi_sup); idempotent.".
-spec init_table() -> ok.
init_table() ->
    case ets:whereis(?DROP_TABLE) of
        undefined ->
            _ = ets:new(?DROP_TABLE, [
                named_table, public, set, {write_concurrency, true}
            ]),
            ok;
        _ ->
            ok
    end.

-doc """
Check whether a log line for `Key` is allowed right now.

Returns `{true, PreviouslyDropped}` when the caller should log -
`PreviouslyDropped` is the count of calls suppressed for this `Key` since
the last time `allow/1` returned `true` (0 the first time / when nothing
was suppressed). Returns `false` when the caller should skip logging this
occurrence (the drop is still counted for the next allowed call to report).
""".
-spec allow(term()) -> {true, non_neg_integer()} | false.
allow(Key) ->
    %% Fail open (allow, don't crash the caller) if seki isn't available -
    %% this is an observability feature, not a security control, so a
    %% misconfigured/test environment should over-log rather than take down
    %% the caller. asobi_sup:register_limiters/0 registers the limiter (and
    %% starts seki) in a real boot; lightweight eunit setups (e.g.
    %% asobi_zone_tests) don't - `{limiter_not_found, _}` covers seki running
    %% with no matching limiter, `badarg` covers seki's own registry table
    %% not existing at all (its application/supervisor never started). Both
    %% catches are scoped to the whole seki:check/2 call, not narrowed to
    %% exactly those two failure points inside it - a badarg raised for any
    %% other reason in seki's call chain also fails open here. Acceptable
    %% for a fail-open, non-security path; not narrowable further without a
    %% seki API change.
    try seki:check(asobi_script_log_limiter, Key) of
        {allow, _} ->
            {true, take_dropped(Key)};
        {deny, _} ->
            bump_dropped(Key),
            false
    catch
        error:{limiter_not_found, _} -> {true, take_dropped(Key)};
        error:badarg -> {true, take_dropped(Key)}
    end.

-doc """
Drop any pending drop-count row for `Key`. Callers whose Key's lifetime is
bounded (e.g. a zone process, keyed on `{WorldId, Coords}`) should call this
when that lifetime ends, so a Key that suppressed a log line right before
terminating doesn't leave a permanent stale row behind.
""".
-spec forget(term()) -> ok.
forget(Key) ->
    case ets:whereis(?DROP_TABLE) of
        undefined ->
            ok;
        _ ->
            _ = ets:delete(?DROP_TABLE, Key),
            ok
    end.

-spec take_dropped(term()) -> non_neg_integer().
take_dropped(Key) ->
    case ets:whereis(?DROP_TABLE) of
        %% Table not started (e.g. eunit without asobi_sup) - nothing to take.
        undefined ->
            0;
        _ ->
            case ets:take(?DROP_TABLE, Key) of
                [{_, N}] when is_integer(N) -> N;
                _ -> 0
            end
    end.

-spec bump_dropped(term()) -> ok.
bump_dropped(Key) ->
    case ets:whereis(?DROP_TABLE) of
        undefined ->
            ok;
        _ ->
            _ = ets:update_counter(?DROP_TABLE, Key, {2, 1}, {Key, 0}),
            ok
    end.
