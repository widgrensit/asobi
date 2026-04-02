-module(asobi_item_def).
-behaviour(kura_schema).

-include_lib("kura/include/kura.hrl").

-export([table/0, fields/0, associations/0, indexes/0, generate_id/0]).
-export([changeset/2]).

-spec table() -> binary().
table() -> ~"item_defs".

-spec fields() -> [#kura_field{}].
fields() ->
    [
        #kura_field{name = id, type = uuid, primary_key = true, nullable = false},
        #kura_field{name = slug, type = string, nullable = false},
        #kura_field{name = name, type = string, nullable = false},
        #kura_field{name = category, type = string, nullable = false},
        #kura_field{name = rarity, type = string, default = ~"common"},
        #kura_field{name = stackable, type = boolean, default = true, nullable = false},
        #kura_field{name = metadata, type = jsonb, default = #{}},
        #kura_field{name = inserted_at, type = utc_datetime, nullable = false},
        #kura_field{name = updated_at, type = utc_datetime, nullable = false}
    ].

-spec generate_id() -> binary().
generate_id() -> asobi_id:generate().

-spec associations() -> [#kura_assoc{}].
associations() -> [].

-spec indexes() -> [{[atom()], map()}].
indexes() ->
    [
        {[slug], #{unique => true}}
    ].

-spec changeset(map(), map()) -> #kura_changeset{}.
changeset(Data, Params) ->
    CS = kura_changeset:cast(?MODULE, Data, Params, [
        slug, name, category, rarity, stackable, metadata
    ]),
    CS1 = kura_changeset:validate_required(CS, [slug, name, category]),
    kura_changeset:validate_inclusion(CS1, rarity, [
        ~"common", ~"uncommon", ~"rare", ~"epic", ~"legendary"
    ]).
