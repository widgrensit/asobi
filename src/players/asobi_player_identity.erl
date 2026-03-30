-module(asobi_player_identity).
-behaviour(kura_schema).

-include_lib("kura/include/kura.hrl").

-export([table/0, fields/0, associations/0, indexes/0]).
-export([changeset/2]).

-spec table() -> binary().
table() -> ~"player_identities".

-spec fields() -> [#kura_field{}].
fields() ->
    [
        #kura_field{name = id, type = uuid, primary_key = true, nullable = false},
        #kura_field{name = player_id, type = uuid, nullable = false},
        #kura_field{name = provider, type = string, nullable = false},
        #kura_field{name = provider_uid, type = string, nullable = false},
        #kura_field{name = provider_email, type = string},
        #kura_field{name = provider_display_name, type = string},
        #kura_field{name = provider_metadata, type = jsonb, default = #{}},
        #kura_field{name = inserted_at, type = utc_datetime, nullable = false},
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
        {[provider, provider_uid], #{unique => true}},
        {[player_id], #{}}
    ].

-spec changeset(map(), map()) -> #kura_changeset{}.
changeset(Data, Params) ->
    CS = kura_changeset:cast(?MODULE, Data, Params, [
        player_id,
        provider,
        provider_uid,
        provider_email,
        provider_display_name,
        provider_metadata
    ]),
    kura_changeset:validate_required(CS, [player_id, provider, provider_uid]).
