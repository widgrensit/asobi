-module(asobi_ops_stats).
-moduledoc """
Live runtime stats for the operator console's dashboard.

What an operator wants during an incident, in one cheap read: is the node
healthy, how much is it holding, and how many players are on it. Everything
here comes from the VM or from `m:asobi_presence` - nothing touches Postgres,
so this endpoint stays answerable when the database is the thing that is
unwell.

## Why this is polled rather than pushed

The equivalent in the old `asobi_admin` was a WebSocket that pushed every two
seconds, and it carried its own in-protocol authentication because a ws
upgrade cannot be rejected cleanly before it completes. The ops plane already
has bearer tokens and capability classes; a second auth path for a payload
this small is not worth maintaining. The console polls.

## Why `node` is reported

asobi clusters (see the clustering guide), and every node serves its own copy
of this endpoint. An operator behind a load balancer would otherwise have no
way to tell which node answered - and since the numbers here are per-node,
a reading without a node name is a reading you cannot act on.
""".

-export([collect/0]).

-spec collect() -> map().
collect() ->
    Memory = erlang:memory(),
    #{
        data => #{
            node => atom_to_binary(node(), utf8),
            online_players => online_players(),
            process_count => erlang:system_info(process_count),
            process_limit => erlang:system_info(process_limit),
            memory_total => proplists:get_value(total, Memory),
            memory_processes => proplists:get_value(processes, Memory),
            memory_ets => proplists:get_value(ets, Memory),
            memory_binary => proplists:get_value(binary, Memory),
            run_queue => erlang:statistics(run_queue),
            scheduler_count => erlang:system_info(schedulers_online),
            uptime_ms => element(1, erlang:statistics(wall_clock))
        }
    }.

%% Presence is a supervised process, and a dashboard that 500s because one
%% gauge is briefly unavailable is worse than a dashboard reporting `null` for
%% it. Everything else here is a VM call that cannot fail.
-spec online_players() -> non_neg_integer() | null.
online_players() ->
    try
        asobi_presence:online_count()
    catch
        _:_ -> null
    end.
