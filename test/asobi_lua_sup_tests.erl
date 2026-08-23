-module(asobi_lua_sup_tests).

-include_lib("eunit/include/eunit.hrl").

%% A function rather than a macro: erlfmt rejects updating a literal map.
defaults() -> #{algorithm => sliding_window, limit => 30, window => 1000}.

merged(Overrides) -> asobi_lua_sup:merged_opts(log, defaults(), Overrides).

with(Extra) -> maps:merge(defaults(), Extra).

%% `rate_limits` is operator-supplied and reaches seki's registry, where a
%% `limit` of 0 is a division by zero at register time - and that registry owns
%% every limiter on the node. These pin what survives validation and what falls
%% back to asobi's own defaults.
merged_opts_test_() ->
    [
        {"no override keeps the defaults", ?_assertEqual(defaults(), merged(#{}))},
        {"a valid limit override is honoured",
            ?_assertEqual(with(#{limit => 5}), merged(#{limit => 5}))},
        {"burst survives, since an operator may genuinely tune it",
            ?_assertEqual(with(#{burst => 2}), merged(#{burst => 2}))},
        {"seki's own plumbing keys are dropped",
            ?_assertEqual(defaults(), merged(#{backend => some_mod}))},
        {"a zero limit never reaches seki", ?_assertEqual(defaults(), merged(#{limit => 0}))},
        {"a non-integer limit falls back", ?_assertEqual(defaults(), merged(#{limit => "5"}))},
        {"a zero window falls back", ?_assertEqual(defaults(), merged(#{window => 0}))},
        {"an unknown algorithm falls back",
            ?_assertEqual(defaults(), merged(#{algorithm => leaky_buckets}))},
        {"an absurd limit is capped out rather than registered",
            ?_assertEqual(defaults(), merged(#{limit => 1_000_000_000}))},
        {"a bad sibling discards the whole override",
            ?_assertEqual(defaults(), merged(#{limit => 5, window => bad}))}
    ] ++
        [
            {"every seki algorithm is accepted",
                ?_assertEqual(with(#{algorithm => A}), merged(#{algorithm => A}))}
         || A <- [token_bucket, sliding_window, gcra, leaky_bucket]
        ].
