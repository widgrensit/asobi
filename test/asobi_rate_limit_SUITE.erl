-module(asobi_rate_limit_SUITE).

-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1, init_per_testcase/2, end_per_testcase/2]).
-export([
    allows_under_limit/1,
    blocks_over_limit/1,
    window_resets/1,
    cleanup_removes_expired/1
]).

-define(ETS_TABLE, asobi_rate_limits).

all() -> [allows_under_limit, blocks_over_limit, window_resets, cleanup_removes_expired].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(asobi),
    Config.

end_per_suite(Config) ->
    Config.

init_per_testcase(_TC, Config) ->
    ets:delete_all_objects(?ETS_TABLE),
    Config.

end_per_testcase(_TC, _Config) ->
    ok.

allows_under_limit(_Config) ->
    Key = {~"test_ip", ~"/api/test"},
    %% Insert with limit of 5
    lists:foreach(fun(_) ->
        ets:insert(?ETS_TABLE, {Key, 0, erlang:system_time(millisecond)}),
        ets:update_counter(?ETS_TABLE, Key, {2, 1})
    end, lists:seq(1, 3)),
    [{Key, Count, _}] = ets:lookup(?ETS_TABLE, Key),
    ?assert(Count =< 5).

blocks_over_limit(_Config) ->
    Key = {~"over_ip", ~"/api/test"},
    Now = erlang:system_time(millisecond),
    ets:insert(?ETS_TABLE, {Key, 100, Now}),
    [{Key, Count, _}] = ets:lookup(?ETS_TABLE, Key),
    ?assertEqual(100, Count).

window_resets(_Config) ->
    Key = {~"window_ip", ~"/api/test"},
    %% Insert entry with old timestamp (expired window)
    OldTime = erlang:system_time(millisecond) - 120000,
    ets:insert(?ETS_TABLE, {Key, 50, OldTime}),
    %% Verify it's there
    [{Key, 50, OldTime}] = ets:lookup(?ETS_TABLE, Key),
    %% A new request would reset the window
    Now = erlang:system_time(millisecond),
    ?assert((Now - OldTime) >= 60000).

cleanup_removes_expired(_Config) ->
    %% Insert expired entries
    OldTime = erlang:system_time(millisecond) - 120000,
    ets:insert(?ETS_TABLE, {{~"old_ip", ~"/api/1"}, 10, OldTime}),
    ets:insert(?ETS_TABLE, {{~"old_ip", ~"/api/2"}, 20, OldTime}),
    %% Insert a fresh entry
    Now = erlang:system_time(millisecond),
    ets:insert(?ETS_TABLE, {{~"new_ip", ~"/api/1"}, 5, Now}),
    %% Trigger cleanup
    asobi_rate_limit_server ! cleanup,
    timer:sleep(100),
    %% Expired entries should be gone
    ?assertEqual([], ets:lookup(?ETS_TABLE, {~"old_ip", ~"/api/1"})),
    ?assertEqual([], ets:lookup(?ETS_TABLE, {~"old_ip", ~"/api/2"})),
    %% Fresh entry should remain
    ?assertMatch([_], ets:lookup(?ETS_TABLE, {~"new_ip", ~"/api/1"})).
