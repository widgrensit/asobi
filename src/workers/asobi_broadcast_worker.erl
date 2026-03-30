-module(asobi_broadcast_worker).
-behaviour(shigoto_worker).

-export([perform/1, queue/0, priority/0, max_attempts/1]).
-export([enqueue/2]).

-spec queue() -> binary().
queue() -> ~"broadcast".

-spec priority() -> integer().
priority() -> 100.

-spec max_attempts(map()) -> pos_integer().
max_attempts(_Args) -> 1.

-spec enqueue(binary(), map()) -> {ok, term()} | {error, term()}.
enqueue(Type, Payload) ->
    shigoto:insert(#{
        worker => ?MODULE,
        args => Payload#{type => Type}
    }).

-spec perform(map()) -> ok.
perform(#{type := ~"session_revoked", player_id := PlayerId, reason := Reason}) ->
    asobi_presence:disconnect(PlayerId, Reason);
perform(#{type := ~"notification", player_id := PlayerId} = Payload) ->
    Notif = maps:without([type, player_id], Payload),
    asobi_presence:send(PlayerId, {notification, Notif});
perform(#{type := ~"chat", channel_id := ChannelId, sender_id := SenderId, content := Content}) ->
    asobi_chat_channel:send_message(ChannelId, SenderId, Content);
perform(#{type := Type}) ->
    logger:warning(#{msg => ~"unknown_broadcast_type", type => Type}),
    ok.
