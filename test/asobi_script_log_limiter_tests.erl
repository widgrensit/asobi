-module(asobi_script_log_limiter_tests).
-include_lib("eunit/include/eunit.hrl").

%% asobi#252: a tick-loop script that fails on every tick must not flood the
%% logs forever. These pin that the limiter actually suppresses past its
%% configured rate, that suppression is scoped per key (one broken zone/script
%% doesn't silence another's), and that a suppressed run is reported (not
%% just silently swallowed) the next time a log line is allowed through.

-define(LIMITER, asobi_script_log_limiter).

setup() ->
    application:ensure_all_started(seki),
    catch seki:new_limiter(?LIMITER, #{algorithm => sliding_window, limit => 3, window => 60000}),
    ok = asobi_script_log_limiter:init_table(),
    ok.

cleanup(_) ->
    ok.

script_log_limiter_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        {"allows up to the limit then denies", fun denies_past_limit/0},
        {"buckets are per key", fun per_key_buckets/0},
        {"a denied call is counted and reported on the next allow",
            fun reports_dropped_count_on_next_allow/0},
        {"an allowed call with nothing suppressed reports zero", fun reports_zero_when_clean/0},
        {"forget drops a pending count so a later allow reports zero, not stale",
            fun forget_clears_pending_drop_count/0}
    ]}.

denies_past_limit() ->
    Key = unique_key(),
    [?assertMatch({true, _}, asobi_script_log_limiter:allow(Key)) || _ <- lists:seq(1, 3)],
    ?assertEqual(
        false,
        asobi_script_log_limiter:allow(Key),
        "an unbounded per-tick log rate is exactly what this exists to prevent"
    ).

per_key_buckets() ->
    A = unique_key(),
    B = unique_key(),
    [?assertMatch({true, _}, asobi_script_log_limiter:allow(A)) || _ <- lists:seq(1, 3)],
    ?assertEqual(false, asobi_script_log_limiter:allow(A)),
    ?assertMatch(
        {true, _},
        asobi_script_log_limiter:allow(B),
        "one key's broken script must not silence another key's logs"
    ).

reports_dropped_count_on_next_allow() ->
    Key = unique_key(),
    [asobi_script_log_limiter:allow(Key) || _ <- lists:seq(1, 3)],
    %% Deny window: 2 suppressed calls before the bucket refills.
    ?assertEqual(false, asobi_script_log_limiter:allow(Key)),
    ?assertEqual(false, asobi_script_log_limiter:allow(Key)),
    catch seki:reset(?LIMITER, Key),
    ?assertEqual({true, 2}, asobi_script_log_limiter:allow(Key)).

reports_zero_when_clean() ->
    Key = unique_key(),
    ?assertEqual({true, 0}, asobi_script_log_limiter:allow(Key)).

%% asobi#252 review (used from asobi_zone:terminate/2): a Key with a bounded
%% lifetime (a zone's {WorldId, Coords}) must not leave a stale drop-count
%% row behind forever once that lifetime ends.
forget_clears_pending_drop_count() ->
    Key = unique_key(),
    [asobi_script_log_limiter:allow(Key) || _ <- lists:seq(1, 3)],
    %% Suppressed once - a pending count is now sitting in the drop table.
    ?assertEqual(false, asobi_script_log_limiter:allow(Key)),
    ok = asobi_script_log_limiter:forget(Key),
    catch seki:reset(?LIMITER, Key),
    ?assertEqual(
        {true, 0},
        asobi_script_log_limiter:allow(Key),
        "forget/1 must clear the pending count, not just let the next allow report it"
    ).

unique_key() ->
    {test, erlang:unique_integer([positive])}.
