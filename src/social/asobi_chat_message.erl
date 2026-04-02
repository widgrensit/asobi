-module(asobi_chat_message).
-behaviour(kura_schema).

-include_lib("kura/include/kura.hrl").

-export([table/0, fields/0, associations/0, indexes/0, generate_id/0]).

-spec table() -> binary().
table() -> ~"chat_messages".

-spec fields() -> [#kura_field{}].
fields() ->
    [
        #kura_field{name = id, type = uuid, primary_key = true, nullable = false},
        #kura_field{name = channel_type, type = string, nullable = false},
        #kura_field{name = channel_id, type = string, nullable = false},
        #kura_field{name = sender_id, type = uuid, nullable = false},
        #kura_field{name = content, type = text, nullable = false},
        #kura_field{name = metadata, type = jsonb, default = #{}},
        #kura_field{name = sent_at, type = utc_datetime, nullable = false}
    ].

-spec generate_id() -> binary().
generate_id() -> asobi_id:generate().

-spec associations() -> [#kura_assoc{}].
associations() ->
    [
        #kura_assoc{
            name = sender, type = belongs_to, schema = asobi_player, foreign_key = sender_id
        }
    ].

-spec indexes() -> [{[atom()], map()}].
indexes() ->
    [
        {[channel_id], #{}},
        {[sender_id], #{}},
        {[sent_at], #{}}
    ].
