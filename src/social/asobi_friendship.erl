-module(asobi_friendship).
-behaviour(kura_schema).

-include_lib("kura/include/kura.hrl").

-export([table/0, fields/0, associations/0, indexes/0]).
-export([changeset/2]).

-spec table() -> binary().
table() -> ~"friendships".

-spec fields() -> [#kura_field{}].
fields() ->
    [
        #kura_field{name = id, type = uuid, primary_key = true, nullable = false},
        #kura_field{name = player_id, type = uuid, nullable = false},
        #kura_field{name = friend_id, type = uuid, nullable = false},
        #kura_field{name = status, type = string, default = ~"pending", nullable = false},
        #kura_field{name = inserted_at, type = utc_datetime, nullable = false},
        #kura_field{name = updated_at, type = utc_datetime, nullable = false}
    ].

-spec associations() -> [#kura_assoc{}].
associations() ->
    [
        #kura_assoc{
            name = player, type = belongs_to, schema = asobi_player, foreign_key = player_id
        },
        #kura_assoc{
            name = friend, type = belongs_to, schema = asobi_player, foreign_key = friend_id
        }
    ].

-spec indexes() -> [{[atom()], map()}].
indexes() ->
    [
        {[player_id, friend_id], #{unique => true}},
        {[player_id], #{}},
        {[friend_id], #{}}
    ].

-spec changeset(map(), map()) -> #kura_changeset{}.
changeset(Data, Params) ->
    CS = kura_changeset:cast(?MODULE, Data, Params, [player_id, friend_id, status]),
    CS1 = kura_changeset:validate_required(CS, [player_id, friend_id]),
    kura_changeset:validate_inclusion(CS1, status, [~"pending", ~"accepted", ~"blocked"]).
