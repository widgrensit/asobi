-module(m20260330174743_create_player_identities).
-moduledoc false.
-behaviour(kura_migration).
-include_lib("kura/include/kura.hrl").
-export([up/0, down/0]).

-spec up() -> [kura_migration:operation()].
up() ->
    [{create_table, <<"player_identities">>, [
        #kura_column{name = id, type = uuid, primary_key = true, nullable = false},
        #kura_column{name = player_id, type = uuid, nullable = false, references = {<<"players">>,id}, on_delete = no_action},
        #kura_column{name = provider, type = string, nullable = false},
        #kura_column{name = provider_uid, type = string, nullable = false},
        #kura_column{name = provider_email, type = string},
        #kura_column{name = provider_display_name, type = string},
        #kura_column{name = provider_metadata, type = jsonb, default = #{}},
        #kura_column{name = inserted_at, type = utc_datetime, nullable = false},
        #kura_column{name = updated_at, type = utc_datetime, nullable = false}
    ]},
     {create_index, <<"chat_messages">>, [channel_id], #{}},
     {create_index, <<"chat_messages">>, [sender_id], #{}},
     {create_index, <<"chat_messages">>, [sent_at], #{}},
     {drop_index, <<"chat_messages_channel_id_sent_at_index">>},
     {create_index, <<"friendships">>, [player_id], #{}},
     {create_index, <<"friendships">>, [friend_id], #{}},
     {create_index, <<"group_members">>, [group_id,player_id], #{unique => true}},
     {create_index, <<"group_members">>, [player_id], #{}},
     {create_index, <<"item_defs">>, [slug], #{unique => true}},
     {create_index, <<"match_records">>, [mode], #{}},
     {create_index, <<"match_records">>, [status], #{}},
     {create_index, <<"notifications">>, [player_id], #{}},
     {create_index, <<"notifications">>, [sent_at], #{}},
     {drop_index, <<"notifications_player_id_sent_at_index">>},
     {create_index, <<"player_identities">>, [provider,provider_uid], #{unique => true}},
     {create_index, <<"player_identities">>, [player_id], #{}},
     {create_index, <<"player_items">>, [player_id], #{}},
     {create_index, <<"player_tokens">>, [context,token], #{}},
     {create_index, <<"player_tokens">>, [user_id], #{}},
     {create_index, <<"storage">>, [player_id], #{}},
     {create_index, <<"tournaments">>, [status], #{}},
     {create_index, <<"tournaments">>, [start_at], #{}},
     {create_index, <<"transactions">>, [wallet_id], #{}}].

-spec down() -> [kura_migration:operation()].
down() ->
    [{drop_table, <<"player_identities">>},
     {drop_index, <<"chat_messages_channel_id_index">>},
     {drop_index, <<"chat_messages_sender_id_index">>},
     {drop_index, <<"chat_messages_sent_at_index">>},
     {create_index, <<"chat_messages">>, [channel_id,sent_at], #{}},
     {drop_index, <<"friendships_player_id_index">>},
     {drop_index, <<"friendships_friend_id_index">>},
     {drop_index, <<"group_members_group_id_player_id_index">>},
     {drop_index, <<"group_members_player_id_index">>},
     {drop_index, <<"item_defs_slug_index">>},
     {drop_index, <<"match_records_mode_index">>},
     {drop_index, <<"match_records_status_index">>},
     {drop_index, <<"notifications_player_id_index">>},
     {drop_index, <<"notifications_sent_at_index">>},
     {create_index, <<"notifications">>, [player_id,sent_at], #{}},
     {drop_index, <<"player_identities_provider_provider_uid_index">>},
     {drop_index, <<"player_identities_player_id_index">>},
     {drop_index, <<"player_items_player_id_index">>},
     {drop_index, <<"player_tokens_context_token_index">>},
     {drop_index, <<"player_tokens_user_id_index">>},
     {drop_index, <<"storage_player_id_index">>},
     {drop_index, <<"tournaments_status_index">>},
     {drop_index, <<"tournaments_start_at_index">>},
     {drop_index, <<"transactions_wallet_id_index">>}].
