-module(m20260701120000_create_iap_transactions).
-moduledoc false.
-behaviour(kura_migration).
-include_lib("kura/include/kura.hrl").
-export([up/0, down/0]).

-spec up() -> [kura_migration:operation()].
up() ->
    [
        {create_table, <<"iap_transactions">>, [
            #kura_column{name = id, type = uuid, primary_key = true, nullable = false},
            #kura_column{
                name = player_id,
                type = uuid,
                nullable = false,
                references = {<<"players">>, id},
                on_delete = no_action
            },
            #kura_column{name = provider, type = string, nullable = false},
            #kura_column{name = transaction_id, type = string, nullable = false},
            #kura_column{name = original_transaction_id, type = string},
            #kura_column{name = product_id, type = string},
            #kura_column{name = inserted_at, type = utc_datetime, nullable = false}
        ]},
        %% Unique per provider transaction: the DB backstop against receipt
        %% replay (a store transaction can be claimed exactly once).
        {create_index, <<"iap_transactions">>, [provider, transaction_id], #{unique => true}},
        {create_index, <<"iap_transactions">>, [player_id], #{}}
    ].

-spec down() -> [kura_migration:operation()].
down() ->
    [
        {drop_table, <<"iap_transactions">>}
    ].
