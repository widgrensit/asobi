-module(asobi_cloud_save).
-behaviour(kura_schema).

-include_lib("kura/include/kura.hrl").

-export([table/0, fields/0, associations/0, indexes/0]).

-spec table() -> binary().
table() -> ~"cloud_saves".

-spec fields() -> [#kura_field{}].
fields() ->
    [
        #kura_field{name = id, type = uuid, primary_key = true, nullable = false},
        #kura_field{name = player_id, type = uuid, nullable = false},
        #kura_field{name = slot, type = string, nullable = false},
        #kura_field{name = data, type = jsonb, default = #{}},
        #kura_field{name = version, type = integer, default = 1, nullable = false},
        #kura_field{name = updated_at, type = utc_datetime, nullable = false}
    ].

-spec associations() -> [#kura_assoc{}].
associations() ->
    [
        #kura_assoc{
            name = player, type = belongs_to, schema = asobi_player, foreign_key = player_id
        }
    ].

-spec indexes() -> [{[atom()], map()}].
indexes() ->
    [
        {[player_id, slot], #{unique => true}}
    ].
