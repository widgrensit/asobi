-module(asobi_group_member).
-behaviour(kura_schema).

-include_lib("kura/include/kura.hrl").

-export([table/0, fields/0, associations/0, indexes/0, generate_id/0]).

-spec table() -> binary().
table() -> ~"group_members".

-spec fields() -> [#kura_field{}].
fields() ->
    [
        #kura_field{name = id, type = uuid, primary_key = true, nullable = false},
        #kura_field{name = group_id, type = uuid, nullable = false},
        #kura_field{name = player_id, type = uuid, nullable = false},
        #kura_field{name = role, type = string, default = ~"member", nullable = false},
        #kura_field{name = joined_at, type = utc_datetime, nullable = false}
    ].

-spec generate_id() -> binary().
generate_id() -> asobi_id:generate().

-spec associations() -> [#kura_assoc{}].
associations() ->
    [
        #kura_assoc{name = group, type = belongs_to, schema = asobi_group, foreign_key = group_id},
        #kura_assoc{
            name = player, type = belongs_to, schema = asobi_player, foreign_key = player_id
        }
    ].

-spec indexes() -> [{[atom()], map()}].
indexes() ->
    [
        {[group_id, player_id], #{unique => true}},
        {[player_id], #{}}
    ].
