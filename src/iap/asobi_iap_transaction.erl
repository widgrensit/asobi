-module(asobi_iap_transaction).
-behaviour(kura_schema).

-include_lib("kura/include/kura.hrl").

-export([table/0, fields/0, associations/0, indexes/0, generate_id/0, changeset/2]).

-spec table() -> binary().
table() -> ~"iap_transactions".

-spec fields() -> [#kura_field{}].
fields() ->
    [
        #kura_field{name = id, type = uuid, primary_key = true, nullable = false},
        %% Nullable so `m:asobi_player_erase` can sever the receipt from the
        %% player without destroying it. A purchase record outlives the account:
        %% a refund or chargeback dispute needs the provider transaction id long
        %% after an erasure request has been honoured. `changeset/2` still
        %% requires it, so nothing can write a receipt with no player.
        #kura_field{name = player_id, type = uuid},
        #kura_field{name = provider, type = string, nullable = false},
        #kura_field{name = transaction_id, type = string, nullable = false},
        #kura_field{name = original_transaction_id, type = string},
        #kura_field{name = product_id, type = string},
        #kura_field{name = inserted_at, type = utc_datetime, nullable = false}
    ].

%% The foreign key has existed since m20260701120000 created the table with
%% `references = {<<"players">>, id}`, but the schema never declared the
%% association to match. rebar3_kura could not see the difference until v0.16.0
%% taught the diff to compare references, and its first reading of the gap is to
%% propose dropping the constraint - which would take referential integrity off
%% purchase records. The database is right and the schema was incomplete.
%%
%% No `on_delete`: the constraint was created without one, so declaring anything
%% else here would generate a migration altering a live financial table.
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
        {[provider, transaction_id], #{unique => true}},
        {[player_id], #{}}
    ].

-spec generate_id() -> binary().
generate_id() -> asobi_id:generate().

-spec changeset(map(), map()) -> #kura_changeset{}.
changeset(Data, Params) ->
    CS = kura_changeset:cast(?MODULE, Data, Params, [
        player_id, provider, transaction_id, original_transaction_id, product_id
    ]),
    kura_changeset:validate_required(CS, [player_id, provider, transaction_id]).
