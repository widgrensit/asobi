-module(asobi_dm).

%% Direct messaging built on the chat channel system.
%%
%% DM channel IDs are deterministic: the two player IDs sorted and
%% joined with a colon. This ensures both players always reference
%% the same channel regardless of who initiated.

-export([send/3, history/3, channel_id/2]).

-spec send(binary(), binary(), binary()) -> ok | {error, term()}.
send(SenderId, RecipientId, Content) ->
    case is_blocked(SenderId, RecipientId) of
        true ->
            {error, blocked};
        false ->
            ChannelId = channel_id(SenderId, RecipientId),
            asobi_chat_channel:send_message(ChannelId, SenderId, Content),
            asobi_presence:send(
                RecipientId,
                {dm_message, #{
                    sender_id => SenderId,
                    content => Content,
                    channel_id => ChannelId,
                    sent_at => erlang:system_time(millisecond)
                }}
            ),
            ok
    end.

-spec history(binary(), binary(), pos_integer()) -> [map()].
history(PlayerId, OtherPlayerId, Limit) ->
    ChannelId = channel_id(PlayerId, OtherPlayerId),
    asobi_chat_channel:get_history(ChannelId, Limit).

-spec channel_id(binary(), binary()) -> binary().
channel_id(A, B) when A =< B ->
    iolist_to_binary([~"dm:", A, ~":", B]);
channel_id(A, B) ->
    iolist_to_binary([~"dm:", B, ~":", A]).

%% --- Internal ---

-spec is_blocked(binary(), binary()) -> boolean().
is_blocked(SenderId, RecipientId) ->
    Q = kura_query:where(
        kura_query:where(
            kura_query:where(kura_query:from(asobi_friendship), {player_id, RecipientId}),
            {friend_id, SenderId}
        ),
        {status, ~"blocked"}
    ),
    case asobi_repo:all(Q) of
        {ok, [_ | _]} -> true;
        _ -> false
    end.
