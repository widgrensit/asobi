-module(asobi_group).
-behaviour(kura_schema).

-include_lib("kura/include/kura.hrl").

-export([table/0, fields/0, associations/0, generate_id/0]).
-export([changeset/2]).

-spec table() -> binary().
table() -> ~"groups".

-spec fields() -> [#kura_field{}].
fields() ->
    [
        #kura_field{name = id, type = uuid, primary_key = true, nullable = false},
        #kura_field{name = name, type = string, nullable = false},
        #kura_field{name = description, type = string},
        #kura_field{name = max_members, type = integer, default = 50},
        #kura_field{name = open, type = boolean, default = false, nullable = false},
        #kura_field{name = creator_id, type = uuid, nullable = false},
        #kura_field{name = metadata, type = jsonb, default = #{}},
        #kura_field{name = inserted_at, type = utc_datetime, nullable = false},
        #kura_field{name = updated_at, type = utc_datetime, nullable = false}
    ].

-spec generate_id() -> binary().
generate_id() -> asobi_id:generate().

-spec associations() -> [#kura_assoc{}].
associations() ->
    [
        #kura_assoc{
            name = creator, type = belongs_to, schema = asobi_player, foreign_key = creator_id
        },
        #kura_assoc{
            name = members, type = has_many, schema = asobi_group_member, foreign_key = group_id
        }
    ].

-spec changeset(map(), map()) -> #kura_changeset{}.
changeset(Data, Params) ->
    CS = kura_changeset:cast(?MODULE, Data, Params, [
        name, description, max_members, open, creator_id, metadata
    ]),
    CS1 = kura_changeset:validate_required(CS, [name, creator_id]),
    CS2 = kura_changeset:validate_length(CS1, name, [{min, 2}, {max, 64}]),
    %% F-17: cap description length so an attacker cannot store
    %% megabytes of text in the groups table.
    kura_changeset:validate_length(CS2, description, [{max, 1024}]).
