-module(asobi_zone_snapshot).
-behaviour(kura_schema).

-include_lib("kura/include/kura.hrl").

-export([table/0, fields/0, associations/0, indexes/0, generate_id/0]).

-spec table() -> binary().
table() -> ~"zone_snapshots".

-spec fields() -> [#kura_field{}].
fields() ->
    [
        #kura_field{name = id, type = uuid, primary_key = true, nullable = false},
        #kura_field{name = world_id, type = uuid, nullable = false},
        #kura_field{name = zone_x, type = integer, nullable = false},
        #kura_field{name = zone_y, type = integer, nullable = false},
        #kura_field{name = entities, type = jsonb, nullable = false, default = #{}},
        #kura_field{name = zone_state, type = jsonb, default = #{}},
        #kura_field{name = entity_timers, type = jsonb, default = #{}},
        #kura_field{name = spawner_state, type = jsonb, default = #{}},
        #kura_field{name = tick, type = bigint, nullable = false, default = 0},
        #kura_field{name = snapshot_at, type = utc_datetime, nullable = false}
    ].

-spec generate_id() -> binary().
generate_id() -> asobi_id:generate().

-spec associations() -> [#kura_assoc{}].
associations() -> [].

-spec indexes() -> [{[atom()], map()}].
indexes() ->
    [
        {[world_id, zone_x, zone_y], #{unique => true}}
    ].
