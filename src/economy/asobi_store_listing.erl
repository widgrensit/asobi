-module(asobi_store_listing).
-behaviour(kura_schema).

-include_lib("kura/include/kura.hrl").

-export([table/0, fields/0, associations/0, generate_id/0]).
-export([changeset/2]).

-spec table() -> binary().
table() -> ~"store_listings".

-spec fields() -> [#kura_field{}].
fields() ->
    [
        #kura_field{name = id, type = uuid, primary_key = true, nullable = false},
        #kura_field{name = item_def_id, type = uuid, nullable = false},
        #kura_field{name = currency, type = string, nullable = false},
        #kura_field{name = price, type = integer, nullable = false},
        #kura_field{name = active, type = boolean, default = true, nullable = false},
        #kura_field{name = valid_from, type = utc_datetime},
        #kura_field{name = valid_until, type = utc_datetime},
        #kura_field{name = metadata, type = jsonb, default = #{}}
    ].

-spec generate_id() -> binary().
generate_id() -> asobi_id:generate().

-spec associations() -> [#kura_assoc{}].
associations() ->
    [
        #kura_assoc{
            name = item_def, type = belongs_to, schema = asobi_item_def, foreign_key = item_def_id
        }
    ].

-spec changeset(map(), map()) -> #kura_changeset{}.
changeset(Data, Params) ->
    CS = kura_changeset:cast(?MODULE, Data, Params, [
        item_def_id, currency, price, active, valid_from, valid_until, metadata
    ]),
    kura_changeset:validate_required(CS, [item_def_id, currency, price]).
