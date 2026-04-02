-module(asobi_player_token).
-behaviour(kura_schema).

-include_lib("kura/include/kura.hrl").

-export([table/0, fields/0, associations/0, indexes/0, generate_id/0]).

-spec table() -> binary().
table() -> ~"player_tokens".

-spec fields() -> [#kura_field{}].
fields() ->
    [
        #kura_field{name = id, type = uuid, primary_key = true, nullable = false},
        #kura_field{name = user_id, type = uuid, nullable = false},
        #kura_field{name = token, type = string, nullable = false},
        #kura_field{name = context, type = string, nullable = false},
        #kura_field{name = inserted_at, type = utc_datetime, nullable = false}
    ].

-spec generate_id() -> binary().
generate_id() -> asobi_id:generate().

-spec associations() -> [#kura_assoc{}].
associations() ->
    [
        #kura_assoc{name = player, type = belongs_to, schema = asobi_player, foreign_key = user_id}
    ].

-spec indexes() -> [{[atom()], map()}].
indexes() ->
    [
        {[token, context], #{}},
        {[user_id], #{}}
    ].
