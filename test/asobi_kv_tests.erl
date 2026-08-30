-module(asobi_kv_tests).
-include_lib("eunit/include/eunit.hrl").

setup() ->
    {ok, Pid} = asobi_kv:start_link(),
    Pid.

cleanup(Pid) ->
    gen_server:stop(Pid),
    application:unset_env(asobi, kv_max_keys),
    application:unset_env(asobi, kv_ttl_seconds),
    ok.

kv_test_() ->
    {foreach, fun setup/0, fun cleanup/1, [
        fun(_) -> {"set then get", fun set_get/0} end,
        fun(_) -> {"get of an absent key", fun get_absent/0} end,
        fun(_) -> {"merge creates from an empty map", fun merge_creates/0} end,
        fun(_) -> {"merge accumulates across calls", fun merge_accumulates/0} end,
        fun(_) -> {"merge returns the merged value", fun merge_returns_value/0} end,
        fun(_) -> {"a bad operator is reported, not applied", fun merge_bad_op/0} end,
        fun(_) -> {"delete removes the key", fun delete_removes/0} end,
        fun(_) -> {"scopes do not collide", fun scopes_isolated/0} end,
        fun(_) -> {"an expired entry reads as absent", fun ttl_expires/0} end,
        fun(_) -> {"a write refreshes the ttl", fun write_refreshes_ttl/0} end,
        fun(_) -> {"a new key past the cap is refused", fun cap_refuses_new_keys/0} end,
        fun(_) -> {"an existing key is writable past the cap", fun cap_allows_existing/0} end
    ]}.

set_get() ->
    ok = asobi_kv:set(~"w1", ~"ships", ~"s1", #{~"hull" => 100}),
    ?assertEqual({ok, #{~"hull" => 100}}, asobi_kv:get(~"w1", ~"ships", ~"s1")).

get_absent() ->
    ?assertEqual(not_found, asobi_kv:get(~"w1", ~"ships", ~"nope")).

merge_creates() ->
    {ok, V} = asobi_kv:merge(~"w1", ~"ships", ~"s1", #{~"kills" => #{~"incr" => 1}}),
    ?assertEqual(#{~"kills" => 1}, V).

merge_accumulates() ->
    Ops = #{~"hull" => #{~"incr" => -40}},
    ok = asobi_kv:set(~"w1", ~"ships", ~"s1", #{~"hull" => 100}),
    {ok, _} = asobi_kv:merge(~"w1", ~"ships", ~"s1", Ops),
    {ok, V} = asobi_kv:merge(~"w1", ~"ships", ~"s1", Ops),
    ?assertEqual(#{~"hull" => 20}, V),
    ?assertEqual({ok, #{~"hull" => 20}}, asobi_kv:get(~"w1", ~"ships", ~"s1")).

%% A cast could not answer this, and "did that hit kill it" is the question the
%% caller actually has.
merge_returns_value() ->
    ok = asobi_kv:set(~"w1", ~"ships", ~"s1", #{~"hull" => 10}),
    {ok, V} = asobi_kv:merge(~"w1", ~"ships", ~"s1", #{
        ~"hull" => #{~"incr" => -10}, ~"dead" => #{~"latch" => true}
    }),
    ?assertEqual(#{~"hull" => 0, ~"dead" => true}, V).

merge_bad_op() ->
    ok = asobi_kv:set(~"w1", ~"ships", ~"s1", #{~"hull" => 100}),
    ?assertMatch({error, _}, asobi_kv:merge(~"w1", ~"ships", ~"s1", #{~"hull" => #{~"nope" => 1}})),
    ?assertEqual({ok, #{~"hull" => 100}}, asobi_kv:get(~"w1", ~"ships", ~"s1")).

delete_removes() ->
    ok = asobi_kv:set(~"w1", ~"ships", ~"s1", #{~"hull" => 100}),
    ok = asobi_kv:delete(~"w1", ~"ships", ~"s1"),
    ?assertEqual(not_found, asobi_kv:get(~"w1", ~"ships", ~"s1")).

%% Two worlds running the same mode script use the same collection and key.
scopes_isolated() ->
    ok = asobi_kv:set(~"w1", ~"ships", ~"s1", #{~"hull" => 100}),
    ok = asobi_kv:set(~"w2", ~"ships", ~"s1", #{~"hull" => 50}),
    ?assertEqual({ok, #{~"hull" => 100}}, asobi_kv:get(~"w1", ~"ships", ~"s1")),
    ?assertEqual({ok, #{~"hull" => 50}}, asobi_kv:get(~"w2", ~"ships", ~"s1")).

ttl_expires() ->
    ok = asobi_kv:set(~"w1", ~"ships", ~"s1", #{~"hull" => 100}, 1),
    ?assertMatch({ok, _}, asobi_kv:get(~"w1", ~"ships", ~"s1")),
    expire_now(~"w1", ~"ships", ~"s1"),
    ?assertEqual(not_found, asobi_kv:get(~"w1", ~"ships", ~"s1")).

write_refreshes_ttl() ->
    ok = asobi_kv:set(~"w1", ~"ships", ~"s1", #{~"hull" => 100}, 1),
    expire_now(~"w1", ~"ships", ~"s1"),
    %% Merging an expired entry starts from empty, and re-arms the expiry.
    {ok, _} = asobi_kv:merge(~"w1", ~"ships", ~"s1", #{~"hull" => #{~"set" => 5}}, 60),
    ?assertEqual({ok, #{~"hull" => 5}}, asobi_kv:get(~"w1", ~"ships", ~"s1")).

cap_refuses_new_keys() ->
    application:set_env(asobi, kv_max_keys, 1),
    ok = asobi_kv:set(~"w1", ~"ships", ~"s1", #{~"hull" => 100}),
    ?assertEqual({error, kv_full}, asobi_kv:set(~"w1", ~"ships", ~"s2", #{~"hull" => 100})).

cap_allows_existing() ->
    application:set_env(asobi, kv_max_keys, 1),
    ok = asobi_kv:set(~"w1", ~"ships", ~"s1", #{~"hull" => 100}),
    ?assertMatch({ok, _}, asobi_kv:merge(~"w1", ~"ships", ~"s1", #{~"hull" => #{~"incr" => -1}})).

%% Backdate the row rather than sleeping out a real TTL.
expire_now(Scope, Collection, Key) ->
    K = {Scope, Collection, Key},
    [{K, Value, _}] = ets:lookup(asobi_kv, K),
    true = ets:insert(asobi_kv, {K, Value, erlang:monotonic_time(millisecond) - 1}).
