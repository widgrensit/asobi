-module(m20260401094412_create_votes).
-moduledoc false.
-behaviour(kura_migration).
-include_lib("kura/include/kura.hrl").
-export([up/0, down/0]).

-spec up() -> [kura_migration:operation()].
up() ->
    [{create_table, <<"votes">>, [
        #kura_column{name = id, type = uuid, primary_key = true, nullable = false},
        #kura_column{name = match_id, type = uuid, nullable = false},
        #kura_column{name = template, type = string, nullable = false},
        #kura_column{name = method, type = string, nullable = false},
        #kura_column{name = options, type = jsonb, nullable = false, default = []},
        #kura_column{name = votes_cast, type = jsonb, default = #{}},
        #kura_column{name = result, type = jsonb, default = #{}},
        #kura_column{name = distribution, type = jsonb, default = #{}},
        #kura_column{name = turnout, type = float, default = 0.0},
        #kura_column{name = eligible_count, type = integer, default = 0},
        #kura_column{name = window_ms, type = integer, nullable = false},
        #kura_column{name = opened_at, type = utc_datetime},
        #kura_column{name = closed_at, type = utc_datetime},
        #kura_column{name = inserted_at, type = utc_datetime, nullable = false}
    ]}].

-spec down() -> [kura_migration:operation()].
down() ->
    [{drop_table, <<"votes">>}].
