-module(m20260328112858_update_schema).
-behaviour(kura_migration).
-compile(nowarn_missing_spec).
-include_lib("kura/include/kura.hrl").
-export([up/0, down/0]).

up() ->
    [{create_table, <<"chat_messages">>, [
        #kura_column{name = id, type = uuid, primary_key = true, nullable = false},
        #kura_column{name = channel_type, type = string, nullable = false},
        #kura_column{name = channel_id, type = string, nullable = false},
        #kura_column{name = sender_id, type = uuid, nullable = false, references = {<<"players">>,id}, on_delete = no_action},
        #kura_column{name = content, type = text, nullable = false},
        #kura_column{name = metadata, type = jsonb, default = #{}},
        #kura_column{name = sent_at, type = utc_datetime, nullable = false}
    ]},
     {create_table, <<"cloud_saves">>, [
        #kura_column{name = player_id, type = uuid, nullable = false, references = {<<"players">>,id}, on_delete = no_action},
        #kura_column{name = slot, type = string, nullable = false},
        #kura_column{name = data, type = jsonb, default = #{}},
        #kura_column{name = version, type = integer, nullable = false, default = 1},
        #kura_column{name = updated_at, type = utc_datetime, nullable = false}
    ]},
     {create_table, <<"friendships">>, [
        #kura_column{name = id, type = uuid, primary_key = true, nullable = false},
        #kura_column{name = player_id, type = uuid, nullable = false, references = {<<"players">>,id}, on_delete = no_action},
        #kura_column{name = friend_id, type = uuid, nullable = false, references = {<<"players">>,id}, on_delete = no_action},
        #kura_column{name = status, type = string, nullable = false, default = <<"pending">>},
        #kura_column{name = inserted_at, type = utc_datetime, nullable = false},
        #kura_column{name = updated_at, type = utc_datetime, nullable = false}
    ]},
     {create_table, <<"group_members">>, [
        #kura_column{name = group_id, type = uuid, nullable = false, references = {<<"groups">>,id}, on_delete = no_action},
        #kura_column{name = player_id, type = uuid, nullable = false, references = {<<"players">>,id}, on_delete = no_action},
        #kura_column{name = role, type = string, nullable = false, default = <<"member">>},
        #kura_column{name = joined_at, type = utc_datetime, nullable = false}
    ]},
     {create_table, <<"groups">>, [
        #kura_column{name = id, type = uuid, primary_key = true, nullable = false},
        #kura_column{name = name, type = string, nullable = false},
        #kura_column{name = description, type = string},
        #kura_column{name = max_members, type = integer, default = 50},
        #kura_column{name = open, type = boolean, nullable = false, default = false},
        #kura_column{name = creator_id, type = uuid, nullable = false, references = {<<"players">>,id}, on_delete = no_action},
        #kura_column{name = metadata, type = jsonb, default = #{}},
        #kura_column{name = inserted_at, type = utc_datetime, nullable = false},
        #kura_column{name = updated_at, type = utc_datetime, nullable = false}
    ]},
     {create_table, <<"item_defs">>, [
        #kura_column{name = id, type = uuid, primary_key = true, nullable = false},
        #kura_column{name = slug, type = string, nullable = false},
        #kura_column{name = name, type = string, nullable = false},
        #kura_column{name = category, type = string, nullable = false},
        #kura_column{name = rarity, type = string, default = <<"common">>},
        #kura_column{name = stackable, type = boolean, nullable = false, default = true},
        #kura_column{name = metadata, type = jsonb, default = #{}},
        #kura_column{name = inserted_at, type = utc_datetime, nullable = false},
        #kura_column{name = updated_at, type = utc_datetime, nullable = false}
    ]},
     {create_table, <<"leaderboard_entries">>, [
        #kura_column{name = leaderboard_id, type = string, nullable = false},
        #kura_column{name = player_id, type = uuid, nullable = false, references = {<<"players">>,id}, on_delete = no_action},
        #kura_column{name = score, type = bigint, nullable = false},
        #kura_column{name = sub_score, type = bigint, default = 0},
        #kura_column{name = metadata, type = jsonb, default = #{}},
        #kura_column{name = updated_at, type = utc_datetime, nullable = false}
    ]},
     {create_table, <<"match_records">>, [
        #kura_column{name = id, type = uuid, primary_key = true, nullable = false},
        #kura_column{name = mode, type = string},
        #kura_column{name = status, type = string, nullable = false},
        #kura_column{name = players, type = jsonb, default = []},
        #kura_column{name = result, type = jsonb, default = #{}},
        #kura_column{name = metadata, type = jsonb, default = #{}},
        #kura_column{name = started_at, type = utc_datetime},
        #kura_column{name = finished_at, type = utc_datetime},
        #kura_column{name = inserted_at, type = utc_datetime, nullable = false}
    ]},
     {create_table, <<"notifications">>, [
        #kura_column{name = id, type = uuid, primary_key = true, nullable = false},
        #kura_column{name = player_id, type = uuid, nullable = false, references = {<<"players">>,id}, on_delete = no_action},
        #kura_column{name = type, type = string, nullable = false},
        #kura_column{name = subject, type = string, nullable = false},
        #kura_column{name = content, type = jsonb, default = #{}},
        #kura_column{name = read, type = boolean, nullable = false, default = false},
        #kura_column{name = sent_at, type = utc_datetime, nullable = false}
    ]},
     {create_table, <<"player_items">>, [
        #kura_column{name = id, type = uuid, primary_key = true, nullable = false},
        #kura_column{name = item_def_id, type = uuid, nullable = false, references = {<<"item_defs">>,id}, on_delete = no_action},
        #kura_column{name = player_id, type = uuid, nullable = false, references = {<<"players">>,id}, on_delete = no_action},
        #kura_column{name = quantity, type = integer, nullable = false, default = 1},
        #kura_column{name = metadata, type = jsonb, default = #{}},
        #kura_column{name = acquired_at, type = utc_datetime, nullable = false},
        #kura_column{name = updated_at, type = utc_datetime, nullable = false}
    ]},
     {create_table, <<"player_stats">>, [
        #kura_column{name = player_id, type = uuid, primary_key = true, nullable = false, references = {<<"players">>,id}, on_delete = no_action},
        #kura_column{name = games_played, type = integer, nullable = false, default = 0},
        #kura_column{name = wins, type = integer, nullable = false, default = 0},
        #kura_column{name = losses, type = integer, nullable = false, default = 0},
        #kura_column{name = rating, type = float, nullable = false, default = 1.5e3},
        #kura_column{name = rating_deviation, type = float, nullable = false, default = 350.0},
        #kura_column{name = metadata, type = jsonb, default = #{}},
        #kura_column{name = updated_at, type = utc_datetime, nullable = false}
    ]},
     {create_table, <<"player_tokens">>, [
        #kura_column{name = id, type = uuid, primary_key = true, nullable = false},
        #kura_column{name = user_id, type = uuid, nullable = false, references = {<<"players">>,id}, on_delete = no_action},
        #kura_column{name = token, type = string, nullable = false},
        #kura_column{name = context, type = string, nullable = false},
        #kura_column{name = inserted_at, type = utc_datetime, nullable = false}
    ]},
     {create_table, <<"players">>, [
        #kura_column{name = id, type = uuid, primary_key = true, nullable = false},
        #kura_column{name = username, type = string, nullable = false},
        #kura_column{name = display_name, type = string},
        #kura_column{name = avatar_url, type = string},
        #kura_column{name = hashed_password, type = string},
        #kura_column{name = metadata, type = jsonb, default = #{}},
        #kura_column{name = banned_at, type = utc_datetime},
        #kura_column{name = inserted_at, type = utc_datetime, nullable = false},
        #kura_column{name = updated_at, type = utc_datetime, nullable = false}
    ]},
     {create_table, <<"storage">>, [
        #kura_column{name = collection, type = string, nullable = false},
        #kura_column{name = key, type = string, nullable = false},
        #kura_column{name = player_id, type = uuid, references = {<<"players">>,id}, on_delete = no_action},
        #kura_column{name = value, type = jsonb, default = #{}},
        #kura_column{name = version, type = integer, nullable = false, default = 1},
        #kura_column{name = read_perm, type = string, nullable = false, default = <<"owner">>},
        #kura_column{name = write_perm, type = string, nullable = false, default = <<"owner">>},
        #kura_column{name = updated_at, type = utc_datetime, nullable = false}
    ]},
     {create_table, <<"store_listings">>, [
        #kura_column{name = id, type = uuid, primary_key = true, nullable = false},
        #kura_column{name = item_def_id, type = uuid, nullable = false, references = {<<"item_defs">>,id}, on_delete = no_action},
        #kura_column{name = currency, type = string, nullable = false},
        #kura_column{name = price, type = integer, nullable = false},
        #kura_column{name = active, type = boolean, nullable = false, default = true},
        #kura_column{name = valid_from, type = utc_datetime},
        #kura_column{name = valid_until, type = utc_datetime},
        #kura_column{name = metadata, type = jsonb, default = #{}}
    ]},
     {create_table, <<"tournaments">>, [
        #kura_column{name = id, type = uuid, primary_key = true, nullable = false},
        #kura_column{name = name, type = string, nullable = false},
        #kura_column{name = leaderboard_id, type = string, nullable = false},
        #kura_column{name = max_entries, type = integer},
        #kura_column{name = entry_fee, type = jsonb, default = #{}},
        #kura_column{name = rewards, type = jsonb, default = #{}},
        #kura_column{name = status, type = string, nullable = false, default = <<"pending">>},
        #kura_column{name = start_at, type = utc_datetime, nullable = false},
        #kura_column{name = end_at, type = utc_datetime, nullable = false},
        #kura_column{name = metadata, type = jsonb, default = #{}},
        #kura_column{name = inserted_at, type = utc_datetime, nullable = false}
    ]},
     {create_table, <<"transactions">>, [
        #kura_column{name = id, type = uuid, primary_key = true, nullable = false},
        #kura_column{name = wallet_id, type = uuid, nullable = false, references = {<<"wallets">>,id}, on_delete = no_action},
        #kura_column{name = amount, type = integer, nullable = false},
        #kura_column{name = balance_after, type = integer, nullable = false},
        #kura_column{name = reason, type = string, nullable = false},
        #kura_column{name = reference_type, type = string},
        #kura_column{name = reference_id, type = string},
        #kura_column{name = metadata, type = jsonb, default = #{}},
        #kura_column{name = inserted_at, type = utc_datetime, nullable = false}
    ]},
     {create_table, <<"wallets">>, [
        #kura_column{name = id, type = uuid, primary_key = true, nullable = false},
        #kura_column{name = player_id, type = uuid, nullable = false, references = {<<"players">>,id}, on_delete = no_action},
        #kura_column{name = currency, type = string, nullable = false},
        #kura_column{name = balance, type = integer, nullable = false, default = 0},
        #kura_column{name = inserted_at, type = utc_datetime, nullable = false},
        #kura_column{name = updated_at, type = utc_datetime, nullable = false}
    ]}].

down() ->
    [{drop_table, <<"chat_messages">>},
     {drop_table, <<"cloud_saves">>},
     {drop_table, <<"friendships">>},
     {drop_table, <<"group_members">>},
     {drop_table, <<"groups">>},
     {drop_table, <<"item_defs">>},
     {drop_table, <<"leaderboard_entries">>},
     {drop_table, <<"match_records">>},
     {drop_table, <<"notifications">>},
     {drop_table, <<"player_items">>},
     {drop_table, <<"player_stats">>},
     {drop_table, <<"player_tokens">>},
     {drop_table, <<"players">>},
     {drop_table, <<"storage">>},
     {drop_table, <<"store_listings">>},
     {drop_table, <<"tournaments">>},
     {drop_table, <<"transactions">>},
     {drop_table, <<"wallets">>}].
