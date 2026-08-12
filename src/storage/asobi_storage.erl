-module(asobi_storage).
-behaviour(kura_schema).

-include_lib("kura/include/kura.hrl").

-export([enabled/0, table/0, fields/0, associations/0, indexes/0, generate_id/0]).

%% Storage is on unless a release explicitly sets `storage` to `false` - the
%% opposite default to the console (m:asobi_console), which is off until asked
%% for. When off the seven HTTP routes answer 404 and the game.storage.* Lua
%% namespace is withheld at VM install.
-spec enabled() -> boolean().
enabled() ->
    application:get_env(asobi, storage, true) =:= true.

-spec table() -> binary().
table() -> ~"storage".

-spec fields() -> [#kura_field{}].
fields() ->
    [
        #kura_field{name = id, type = uuid, primary_key = true, nullable = false},
        #kura_field{name = collection, type = string, nullable = false},
        #kura_field{name = key, type = string, nullable = false},
        #kura_field{name = player_id, type = uuid},
        #kura_field{name = value, type = jsonb, default = #{}},
        #kura_field{name = version, type = integer, default = 1, nullable = false},
        #kura_field{name = read_perm, type = string, default = ~"owner", nullable = false},
        #kura_field{name = write_perm, type = string, default = ~"owner", nullable = false},
        #kura_field{name = updated_at, type = utc_datetime, nullable = false}
    ].

-spec generate_id() -> binary().
generate_id() -> asobi_id:generate().

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
        {[collection, key], #{unique => true, where => ~"player_id IS NULL"}},
        {[collection, key, player_id], #{
            unique => true, where => ~"player_id IS NOT NULL"
        }},
        {[player_id], #{}}
    ].
