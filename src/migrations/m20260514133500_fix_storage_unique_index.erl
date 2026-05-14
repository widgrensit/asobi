-module(m20260514133500_fix_storage_unique_index).
-moduledoc false.
-behaviour(kura_migration).
-include_lib("kura/include/kura.hrl").
-export([up/0, down/0]).

%% Split the storage unique index so player-scoped rows can coexist with
%% the same (collection, key) across different player_id values.
%%
%% The original `(collection, key)` index was created before
%% `player_id` existed on the table and was never widened. As a result
%% `game.storage.player_set(p1, "inventory", "gold", ...)` and
%% `game.storage.player_set(p2, "inventory", "gold", ...)` collide:
%% the second insert silently fails the unique constraint.
%%
%% Replace it with two partial indexes:
%% - global rows (player_id IS NULL) remain unique on (collection, key)
%% - per-player rows (player_id IS NOT NULL) are unique on
%%   (collection, key, player_id)
%%
%% Postgres treats two NULL `player_id` values as distinct in a normal
%% unique index, so a single combined index wouldn't catch duplicate
%% global rows. Partial indexes give us the right uniqueness in each
%% scope.

-spec up() -> [kura_migration:operation()].
up() ->
    [
        {drop_index, ~"storage_collection_key_index"},
        {create_index, ~"storage_collection_key_index", ~"storage", [collection, key], [
            unique, {where, ~"player_id IS NULL"}
        ]},
        {create_index, ~"storage_collection_key_player_id_index", ~"storage",
            [collection, key, player_id], [unique, {where, ~"player_id IS NOT NULL"}]}
    ].

-spec down() -> [kura_migration:operation()].
down() ->
    [
        {drop_index, ~"storage_collection_key_index"},
        {drop_index, ~"storage_collection_key_player_id_index"},
        {create_index, ~"storage", [collection, key], #{unique => true}}
    ].
