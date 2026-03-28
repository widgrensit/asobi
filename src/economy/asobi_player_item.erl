-module(asobi_player_item).
-behaviour(kura_schema).

-include_lib("kura/include/kura.hrl").

-export([table/0, fields/0, associations/0, indexes/0]).

-spec table() -> binary().
table() -> ~"player_items".

-spec fields() -> [#kura_field{}].
fields() ->
    [
        #kura_field{name = id, type = uuid, primary_key = true, nullable = false},
        #kura_field{name = item_def_id, type = uuid, nullable = false},
        #kura_field{name = player_id, type = uuid, nullable = false},
        #kura_field{name = quantity, type = integer, default = 1, nullable = false},
        #kura_field{name = metadata, type = jsonb, default = #{}},
        #kura_field{name = acquired_at, type = utc_datetime, nullable = false},
        #kura_field{name = updated_at, type = utc_datetime, nullable = false}
    ].

-spec associations() -> [#kura_assoc{}].
associations() ->
    [
        #kura_assoc{
            name = item_def, type = belongs_to, schema = asobi_item_def, foreign_key = item_def_id
        },
        #kura_assoc{
            name = player, type = belongs_to, schema = asobi_player, foreign_key = player_id
        }
    ].

-spec indexes() -> [{[atom()], map()}].
indexes() ->
    [
        {[player_id], #{}}
    ].
