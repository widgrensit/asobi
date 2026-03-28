-module('20260328000001_create_players').
-behaviour(kura_migration).

-include_lib("kura/include/kura.hrl").

-export([up/0, down/0]).

up() ->
    [
        {create_table, <<"players">>, [
            #kura_column{name = id, type = uuid, primary_key = true},
            #kura_column{name = username, type = string, nullable = false},
            #kura_column{name = hashed_password, type = string},
            #kura_column{name = display_name, type = string},
            #kura_column{name = avatar_url, type = string},
            #kura_column{name = metadata, type = jsonb, default = <<"'{}'::jsonb">>},
            #kura_column{name = banned_at, type = utc_datetime},
            #kura_column{name = inserted_at, type = utc_datetime, nullable = false},
            #kura_column{name = updated_at, type = utc_datetime, nullable = false}
        ]},
        {create_index, <<"players">>, [username], #{unique => true}},

        {create_table, <<"player_stats">>, [
            #kura_column{name = player_id, type = uuid, primary_key = true,
                         references = {<<"players">>, id}, on_delete = cascade},
            #kura_column{name = games_played, type = integer, default = <<"0">>, nullable = false},
            #kura_column{name = wins, type = integer, default = <<"0">>, nullable = false},
            #kura_column{name = losses, type = integer, default = <<"0">>, nullable = false},
            #kura_column{name = rating, type = float, default = <<"1500.0">>, nullable = false},
            #kura_column{name = rating_deviation, type = float, default = <<"350.0">>, nullable = false},
            #kura_column{name = metadata, type = jsonb, default = <<"'{}'::jsonb">>},
            #kura_column{name = updated_at, type = utc_datetime, nullable = false}
        ]},

        {create_table, <<"player_tokens">>, [
            #kura_column{name = id, type = uuid, primary_key = true},
            #kura_column{name = user_id, type = uuid, nullable = false,
                         references = {<<"players">>, id}, on_delete = cascade},
            #kura_column{name = token, type = string, nullable = false},
            #kura_column{name = context, type = string, nullable = false},
            #kura_column{name = inserted_at, type = utc_datetime, nullable = false}
        ]},
        {create_index, <<"player_tokens">>, [token, context], #{}},
        {create_index, <<"player_tokens">>, [user_id], #{}}
    ].

down() ->
    [
        {drop_table, <<"player_tokens">>},
        {drop_table, <<"player_stats">>},
        {drop_table, <<"players">>}
    ].
