-module(asobi_ops_stats_tests).

-include_lib("eunit/include/eunit.hrl").

%% The dashboard reads these during an incident, so the two properties that
%% matter are that it answers at all and that the answer says which node it
%% came from.

collect_reports_the_node_test() ->
    #{data := Data} = asobi_ops_stats:collect(),
    ?assertEqual(atom_to_binary(node(), utf8), maps:get(node, Data)).

collect_reports_vm_gauges_test() ->
    #{data := Data} = asobi_ops_stats:collect(),
    [
        ?assert(is_integer(maps:get(K, Data)))
     || K <- [
            process_count,
            process_limit,
            memory_total,
            memory_processes,
            memory_ets,
            memory_binary,
            run_queue,
            scheduler_count,
            uptime_ms
        ]
    ].

%% Nothing here may touch Postgres: the endpoint has to stay answerable when
%% the database is the thing that is unwell, which is exactly when an operator
%% opens the dashboard.
collect_needs_no_database_test() ->
    ?assertMatch(#{data := _}, asobi_ops_stats:collect()).

%% Presence is a supervised process. A dashboard that 500s because one gauge
%% is briefly unavailable is worse than one reporting null for it.
online_players_is_null_when_presence_is_down_test_() ->
    {setup,
        fun() ->
            meck:new(asobi_presence, [no_link, passthrough]),
            meck:expect(asobi_presence, online_count, fun() -> exit(noproc) end),
            ok
        end,
        fun(_) -> meck:unload(asobi_presence) end, [
            fun() ->
                #{data := Data} = asobi_ops_stats:collect(),
                ?assertEqual(null, maps:get(online_players, Data))
            end
        ]}.

online_players_passes_through_the_count_test_() ->
    {setup,
        fun() ->
            meck:new(asobi_presence, [no_link, passthrough]),
            meck:expect(asobi_presence, online_count, fun() -> 7 end),
            ok
        end,
        fun(_) -> meck:unload(asobi_presence) end, [
            fun() ->
                #{data := Data} = asobi_ops_stats:collect(),
                ?assertEqual(7, maps:get(online_players, Data))
            end
        ]}.

%% Read-only, so it must not require the config class - an operator with the
%% narrowest role still needs to see whether the node is alive.
stats_is_a_read_capability_test() ->
    ?assertEqual(read, asobi_ops_caps:class(~"GET", ~"/api/v1/ops/stats")).
