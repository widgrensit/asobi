-module(asobi_transaction).
-behaviour(kura_schema).

-include_lib("kura/include/kura.hrl").

-export([table/0, fields/0, associations/0, indexes/0]).

-spec table() -> binary().
table() -> ~"transactions".

-spec fields() -> [#kura_field{}].
fields() ->
    [
        #kura_field{name = id, type = uuid, primary_key = true, nullable = false},
        #kura_field{name = wallet_id, type = uuid, nullable = false},
        #kura_field{name = amount, type = integer, nullable = false},
        #kura_field{name = balance_after, type = integer, nullable = false},
        #kura_field{name = reason, type = string, nullable = false},
        #kura_field{name = reference_type, type = string},
        #kura_field{name = reference_id, type = string},
        #kura_field{name = metadata, type = jsonb, default = #{}},
        #kura_field{name = inserted_at, type = utc_datetime, nullable = false}
    ].

-spec associations() -> [#kura_assoc{}].
associations() ->
    [
        #kura_assoc{
            name = wallet, type = belongs_to, schema = asobi_wallet, foreign_key = wallet_id
        }
    ].

-spec indexes() -> [{[atom()], map()}].
indexes() ->
    [
        {[wallet_id], #{}}
    ].
