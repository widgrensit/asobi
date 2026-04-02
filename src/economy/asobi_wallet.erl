-module(asobi_wallet).
-behaviour(kura_schema).

-include_lib("kura/include/kura.hrl").

-export([table/0, fields/0, associations/0, indexes/0, generate_id/0]).

-spec table() -> binary().
table() -> ~"wallets".

-spec fields() -> [#kura_field{}].
fields() ->
    [
        #kura_field{name = id, type = uuid, primary_key = true, nullable = false},
        #kura_field{name = player_id, type = uuid, nullable = false},
        #kura_field{name = currency, type = string, nullable = false},
        #kura_field{name = balance, type = integer, default = 0, nullable = false},
        #kura_field{name = inserted_at, type = utc_datetime, nullable = false},
        #kura_field{name = updated_at, type = utc_datetime, nullable = false}
    ].

-spec generate_id() -> binary().
generate_id() -> asobi_id:generate().

-spec associations() -> [#kura_assoc{}].
associations() ->
    [
        #kura_assoc{
            name = player, type = belongs_to, schema = asobi_player, foreign_key = player_id
        },
        #kura_assoc{
            name = transactions,
            type = has_many,
            schema = asobi_transaction,
            foreign_key = wallet_id
        }
    ].

-spec indexes() -> [{[atom()], map()}].
indexes() ->
    [
        {[player_id, currency], #{unique => true}}
    ].
