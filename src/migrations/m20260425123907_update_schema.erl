-module(m20260425123907_update_schema).
-moduledoc false.
-behaviour(kura_migration).
-include_lib("kura/include/kura.hrl").
-export([up/0, down/0]).

-spec up() -> [kura_migration:operation()].
up() ->
    [
        {create_index, ~"player_tokens", [token, context], #{}},
        {drop_index, ~"player_tokens_context_token_index"},
        {create_index, ~"seasons", [status], #{}},
        {create_index, ~"seasons", [starts_at], #{}},
        {create_index, ~"seasons", [ends_at], #{}},
        {create_index, ~"votes", [match_id], #{}},
        {create_index, ~"votes", [template], #{}},
        {create_index, ~"zone_snapshots", [world_id, zone_x, zone_y], #{unique => true}}
    ].

-spec down() -> [kura_migration:operation()].
down() ->
    [
        {drop_index, ~"player_tokens_token_context_index"},
        {create_index, ~"player_tokens", [context, token], #{}},
        {drop_index, ~"seasons_status_index"},
        {drop_index, ~"seasons_starts_at_index"},
        {drop_index, ~"seasons_ends_at_index"},
        {drop_index, ~"votes_match_id_index"},
        {drop_index, ~"votes_template_index"},
        {drop_index, ~"zone_snapshots_world_id_zone_x_zone_y_index"}
    ].
