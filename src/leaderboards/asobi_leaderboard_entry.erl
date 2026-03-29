-module(asobi_leaderboard_entry).
-behaviour(kura_schema).

-include_lib("kura/include/kura.hrl").

-export([table/0, fields/0, associations/0, indexes/0]).

-spec table() -> binary().
table() -> ~"leaderboard_entries".

-spec fields() -> [#kura_field{}].
fields() ->
    [
        #kura_field{name = id, type = uuid, primary_key = true, nullable = false},
        #kura_field{name = leaderboard_id, type = string, nullable = false},
        #kura_field{name = player_id, type = uuid, nullable = false},
        #kura_field{name = score, type = bigint, nullable = false},
        #kura_field{name = sub_score, type = bigint, default = 0},
        #kura_field{name = metadata, type = jsonb, default = #{}},
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
        {[leaderboard_id, player_id], #{unique => true}},
        {[leaderboard_id, score], #{}}
    ].
