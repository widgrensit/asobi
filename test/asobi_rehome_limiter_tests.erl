-module(asobi_rehome_limiter_tests).
-include_lib("eunit/include/eunit.hrl").

%% asobi#248: asobi_rehome_limiter:allow/1 runs inside a zone's tick handler,
%% so any failure checking the underlying seki limiters must fail open
%% (allow) rather than crash the zone - a crash there cascades through
%% asobi_zone_sup's restart intensity to the whole world instance
%% (one_for_all). These pin the two failure modes found in review.

unregistered_limiter_fails_open_test() ->
    catch seki:delete_limiter(asobi_rehome_limiter),
    ?assert(asobi_rehome_limiter:allow(~"p1")).

%% `limit => 0` is a natural way to try to express "never allow" in
%% rate_limits config. It registers cleanly but seki:check/2 then raises
%% badarith on the first check (division by Limit). The ?assertError pins
%% *why* the wide catch is needed - if this ever narrows back to a specific
%% error pattern, this fails loudly instead of quietly passing.
zero_limit_fails_open_test() ->
    {ok, _} = application:ensure_all_started(seki),
    %% Delete first: seki:new_limiter/2 returns {error, already_registered}
    %% rather than raising if another test in this run already registered
    %% this name with different options - catch alone would not surface
    %% that, and this test's limit => 0 would silently not take effect.
    catch seki:delete_limiter(asobi_rehome_limiter),
    ok = seki:new_limiter(asobi_rehome_limiter, #{
        algorithm => sliding_window, limit => 0, window => 1000
    }),
    ?assertError(badarith, seki:check(asobi_rehome_limiter, ~"p1")),
    ?assert(asobi_rehome_limiter:allow(~"p1")).
