-module(asobi_player).
-behaviour(kura_schema).

-include_lib("kura/include/kura.hrl").

-export([table/0, fields/0, associations/0, indexes/0]).
-export([registration_changeset/2, update_changeset/2, password_changeset/2]).

-spec table() -> binary().
table() -> ~"players".

-spec fields() -> [#kura_field{}].
fields() ->
    [
        #kura_field{name = id, type = uuid, primary_key = true, nullable = false},
        #kura_field{name = username, type = string, nullable = false},
        #kura_field{name = display_name, type = string},
        #kura_field{name = avatar_url, type = string},
        #kura_field{name = password, type = string, virtual = true},
        #kura_field{name = hashed_password, type = string},
        #kura_field{name = metadata, type = jsonb, default = #{}},
        #kura_field{name = banned_at, type = utc_datetime},
        #kura_field{name = inserted_at, type = utc_datetime, nullable = false},
        #kura_field{name = updated_at, type = utc_datetime, nullable = false}
    ].

-spec associations() -> [#kura_assoc{}].
associations() ->
    [
        #kura_assoc{
            name = stats, type = has_one, schema = asobi_player_stats, foreign_key = player_id
        },
        #kura_assoc{name = wallets, type = has_many, schema = asobi_wallet, foreign_key = player_id}
    ].

-spec indexes() -> [{[atom()], map()}].
indexes() ->
    [
        {[username], #{unique => true}}
    ].

-spec registration_changeset(map(), map()) -> #kura_changeset{}.
registration_changeset(Data, Params) ->
    CS = kura_changeset:cast(?MODULE, Data, Params, [
        username, display_name, avatar_url, metadata, password
    ]),
    CS1 = kura_changeset:validate_required(CS, [username, password]),
    CS2 = kura_changeset:validate_length(CS1, username, [{min, 3}, {max, 32}]),
    CS3 = kura_changeset:validate_format(CS2, username, "^[a-zA-Z0-9_-]+$"),
    CS4 = kura_changeset:validate_length(CS3, password, [{min, 8}, {max, 128}]),
    hash_password(CS4).

-spec password_changeset(map(), map()) -> #kura_changeset{}.
password_changeset(Data, Params) ->
    CS = kura_changeset:cast(?MODULE, Data, Params, [password]),
    CS1 = kura_changeset:validate_required(CS, [password]),
    CS2 = kura_changeset:validate_length(CS1, password, [{min, 8}, {max, 128}]),
    hash_password(CS2).

-spec hash_password(#kura_changeset{}) -> #kura_changeset{}.
hash_password(CS) ->
    case kura_changeset:get_change(CS, password) of
        undefined ->
            CS;
        Password ->
            Hashed = nova_auth_password:hash(Password),
            kura_changeset:put_change(CS, hashed_password, Hashed)
    end.

-spec update_changeset(map(), map()) -> #kura_changeset{}.
update_changeset(Data, Params) ->
    CS = kura_changeset:cast(?MODULE, Data, Params, [display_name, avatar_url, metadata]),
    kura_changeset:validate_length(CS, display_name, [{max, 64}]).
