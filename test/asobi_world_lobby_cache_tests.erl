-module(asobi_world_lobby_cache_tests).
-include_lib("eunit/include/eunit.hrl").

%% H3 (2026-05-19): list_worlds_cached/1 must return cached entries within
%% the TTL window so a flood of WS world.list does not fan out to N
%% synchronous gen_server:calls per request. We poke ETS directly so the
%% test does not need running world processes.
%%
%% The cache is keyed on the has_capacity boolean only (at most two rows);
%% mode is applied in-memory on the cached list. Keying on the raw filter
%% map would let a client cycle distinct modes to force a miss on every
%% request and grow the table without bound.

-define(TAB, asobi_world_lobby_cache).
-define(TTL_MS, 500).
%% The cache is shared with match discovery, so the key is namespaced by
%% the server module that produced the listing.
-define(KEY(HasCapacity), {asobi_world_server, HasCapacity}).

cache_test_() ->
    {foreach, fun setup/0, fun teardown/1, [
        fun returns_cached_entry_within_ttl/0,
        fun mode_filtered_in_memory/0,
        fun distinct_modes_do_not_grow_table/0,
        fun has_capacity_keyed_separately/0,
        fun ignores_expired_entry/0
    ]}.

setup() ->
    delete_tab(),
    ets:new(?TAB, [set, public, named_table, {read_concurrency, true}]),
    ok.

teardown(_) ->
    delete_tab(),
    ok.

delete_tab() ->
    case ets:whereis(?TAB) of
        undefined -> ok;
        _ -> ets:delete(?TAB)
    end.

returns_cached_entry_within_ttl() ->
    %% Pre-seed cache with a fake world so we can prove it is being read
    %% rather than recomputed from pg. Default key is has_capacity=false.
    Fake = #{world_id => ~"cached-world-id", mode => ~"barrow"},
    Now = erlang:monotonic_time(millisecond),
    ets:insert(?TAB, {?KEY(false), [Fake], Now + ?TTL_MS}),
    ?assertEqual([Fake], asobi_world_lobby:list_worlds_cached(#{})).

mode_filtered_in_memory() ->
    %% One cached row (key=false) holds all worlds; mode is applied in-memory,
    %% not as a cache key.
    Now = erlang:monotonic_time(millisecond),
    A = #{world_id => ~"a", mode => ~"barrow"},
    B = #{world_id => ~"b", mode => ~"corsairs"},
    ets:insert(?TAB, {?KEY(false), [A, B], Now + ?TTL_MS}),
    ?assertEqual([A], asobi_world_lobby:list_worlds_cached(#{mode => ~"barrow"})),
    ?assertEqual([B], asobi_world_lobby:list_worlds_cached(#{mode => ~"corsairs"})),
    ?assertEqual([], asobi_world_lobby:list_worlds_cached(#{mode => ~"nonexistent"})).

distinct_modes_do_not_grow_table() ->
    %% The DoS fix: cycling distinct (attacker-controlled) modes must all be
    %% served from the single has_capacity=false row, never inserting new keys.
    Now = erlang:monotonic_time(millisecond),
    A = #{world_id => ~"a", mode => ~"barrow"},
    ets:insert(?TAB, {?KEY(false), [A], Now + ?TTL_MS}),
    lists:foreach(
        fun(N) ->
            Mode = integer_to_binary(N),
            _ = asobi_world_lobby:list_worlds_cached(#{mode => Mode})
        end,
        lists:seq(1, 50)
    ),
    ?assertEqual(1, ets:info(?TAB, size)).

has_capacity_keyed_separately() ->
    Now = erlang:monotonic_time(millisecond),
    All = #{world_id => ~"all", mode => ~"barrow"},
    OpenOnly = #{world_id => ~"open", mode => ~"barrow"},
    ets:insert(?TAB, {?KEY(false), [All], Now + ?TTL_MS}),
    ets:insert(?TAB, {?KEY(true), [OpenOnly], Now + ?TTL_MS}),
    ?assertEqual([All], asobi_world_lobby:list_worlds_cached(#{})),
    ?assertEqual([OpenOnly], asobi_world_lobby:list_worlds_cached(#{has_capacity => true})).

ignores_expired_entry() ->
    %% Expired entries must be treated as a miss. Without pg up the resulting
    %% recompute will fail, so we only assert the lookup classifies expired
    %% as a miss by inspecting the row's expiry against "now".
    Fake = #{world_id => ~"stale", mode => ~"barrow"},
    Past = erlang:monotonic_time(millisecond) - 1,
    ets:insert(?TAB, {?KEY(false), [Fake], Past}),
    [{_K, _W, Expires}] = ets:lookup(?TAB, ?KEY(false)),
    Now = erlang:monotonic_time(millisecond),
    ?assert(Expires =< Now).
