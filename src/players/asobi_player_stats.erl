-module(asobi_player_stats).
-behaviour(kura_schema).

-include_lib("kura/include/kura.hrl").

-export([table/0, fields/0, associations/0, generate_id/0]).

-spec table() -> binary().
table() -> ~"player_stats".

-spec fields() -> [#kura_field{}].
fields() ->
    [
        #kura_field{name = player_id, type = uuid, primary_key = true, nullable = false},
        #kura_field{name = games_played, type = integer, default = 0, nullable = false},
        #kura_field{name = wins, type = integer, default = 0, nullable = false},
        #kura_field{name = losses, type = integer, default = 0, nullable = false},
        #kura_field{name = rating, type = float, default = 1500.0, nullable = false},
        #kura_field{name = rating_deviation, type = float, default = 350.0, nullable = false},
        #kura_field{name = metadata, type = jsonb, default = #{}},
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
