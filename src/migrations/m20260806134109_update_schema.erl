-module(m20260806134109_update_schema).
-moduledoc false.
-behaviour(kura_migration).
-include_lib("kura/include/kura.hrl").
-export([up/0, down/0]).

-spec up() -> [kura_migration:operation()].
up() ->
    [
        {execute, ~"ALTER TABLE \"groups\" ALTER COLUMN \"creator_id\" DROP NOT NULL"},
        {execute, ~"ALTER TABLE \"iap_transactions\" ALTER COLUMN \"player_id\" DROP NOT NULL"}
    ].

-spec down() -> [kura_migration:operation()].
down() ->
    [
        {execute, ~"ALTER TABLE \"groups\" ALTER COLUMN \"creator_id\" SET NOT NULL"},
        {execute, ~"ALTER TABLE \"iap_transactions\" ALTER COLUMN \"player_id\" SET NOT NULL"}
    ].
