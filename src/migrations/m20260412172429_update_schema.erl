-module(m20260412172429_update_schema).
-moduledoc false.
-behaviour(kura_migration).
-include_lib("kura/include/kura.hrl").
-export([up/0, down/0]).

-spec up() -> [kura_migration:operation()].
up() ->
    [
        {create_table, <<"seasons">>, [
            #kura_column{name = id, type = uuid, primary_key = true, nullable = false},
            #kura_column{name = name, type = string, nullable = false},
            #kura_column{name = starts_at, type = bigint, nullable = false},
            #kura_column{name = ends_at, type = bigint, nullable = false},
            #kura_column{name = status, type = string, default = <<"upcoming">>},
            #kura_column{name = config, type = jsonb, default = #{}},
            #kura_column{name = ranked, type = jsonb, default = #{}},
            #kura_column{name = rewards, type = jsonb, default = #{}},
            #kura_column{name = inserted_at, type = utc_datetime, nullable = false}
        ]},
        {create_table, <<"zone_snapshots">>, [
            #kura_column{name = id, type = uuid, primary_key = true, nullable = false},
            #kura_column{name = world_id, type = uuid, nullable = false},
            #kura_column{name = zone_x, type = integer, nullable = false},
            #kura_column{name = zone_y, type = integer, nullable = false},
            #kura_column{name = entities, type = jsonb, nullable = false, default = #{}},
            #kura_column{name = zone_state, type = jsonb, default = #{}},
            #kura_column{name = entity_timers, type = jsonb, default = #{}},
            #kura_column{name = spawner_state, type = jsonb, default = #{}},
            #kura_column{name = tick, type = bigint, nullable = false, default = 0},
            #kura_column{name = snapshot_at, type = utc_datetime, nullable = false}
        ]}
    ].

-spec down() -> [kura_migration:operation()].
down() ->
    [
        {drop_table, <<"seasons">>},
        {drop_table, <<"zone_snapshots">>}
    ].
