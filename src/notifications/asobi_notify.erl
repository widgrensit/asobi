-module(asobi_notify).

-export([send/4, send_many/4]).

-spec send(binary(), binary(), binary(), map()) -> {ok, map()} | {error, term()}.
send(PlayerId, Type, Subject, Content) ->
    CS = kura_changeset:cast(
        asobi_notification,
        #{},
        #{
            player_id => PlayerId,
            type => Type,
            subject => Subject,
            content => Content,
            sent_at => calendar:universal_time()
        },
        [player_id, type, subject, content, sent_at]
    ),
    case asobi_repo:insert(CS) of
        {ok, Notif} ->
            asobi_presence:send(PlayerId, {notification, Notif}),
            {ok, Notif};
        {error, _} = Err ->
            Err
    end.

-spec send_many([binary()], binary(), binary(), map()) -> [binary()].
send_many(PlayerIds, Type, Subject, Content) ->
    lists:filtermap(
        fun(PlayerId) ->
            case send(PlayerId, Type, Subject, Content) of
                {ok, _} -> {true, PlayerId};
                {error, _} -> false
            end
        end,
        PlayerIds
    ).
