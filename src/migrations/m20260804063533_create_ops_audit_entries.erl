-module(m20260804063533_create_ops_audit_entries).
-moduledoc false.
-behaviour(kura_migration).
-include_lib("kura/include/kura.hrl").
-export([up/0, down/0]).

-spec up() -> [kura_migration:operation()].
up() ->
    [
        {create_table, ~"ops_audit_entries", [
            #kura_column{name = id, type = uuid, primary_key = true, nullable = false},
            #kura_column{name = actor_id, type = string, nullable = false},
            #kura_column{name = actor_display, type = string, nullable = false},
            #kura_column{name = actor_source, type = string, nullable = false},
            #kura_column{name = actor_attested, type = boolean, nullable = false, default = false},
            #kura_column{name = action, type = string, nullable = false},
            #kura_column{name = target_type, type = string},
            #kura_column{name = target_id, type = string},
            #kura_column{name = outcome, type = string, nullable = false},
            #kura_column{name = succeeded_count, type = integer, nullable = false, default = 0},
            #kura_column{name = failed_count, type = integer, nullable = false, default = 0},
            #kura_column{name = details, type = jsonb, default = #{}},
            #kura_column{name = occurred_at, type = utc_datetime, nullable = false}
        ]},
        {create_index, ~"ops_audit_entries", [actor_id, occurred_at], #{}},
        {create_index, ~"ops_audit_entries", [action, occurred_at], #{}},
        {create_index, ~"ops_audit_entries", [target_id], #{}}
    ].

-spec down() -> [kura_migration:operation()].
down() ->
    [
        {drop_table, ~"ops_audit_entries"},
        {drop_index, ~"ops_audit_entries_actor_id_occurred_at_index"},
        {drop_index, ~"ops_audit_entries_action_occurred_at_index"},
        {drop_index, ~"ops_audit_entries_target_id_index"}
    ].
