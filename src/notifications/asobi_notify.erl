-module(asobi_notify).
-moduledoc """
Delivery of notifications to players.

`send_many/4` returns `{ok, Succeeded, Failed}` rather than the list of
recipients it managed to reach. The old shape could not express partial
failure at all - it dropped failed inserts on the floor - and its one
operator-facing caller then audited a half-delivered broadcast as a success.
The widened shape is `asobi_ops_audit`'s outcome contract, so an
operator-attributed fan-out is auditable without the call site
reconstructing what happened.
""".

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

-doc """
Send one notification to each of `PlayerIds`.

Every recipient is attempted; one failure does not abandon the rest. Returns
`{ok, Succeeded, Failed}`, `Failed` carrying each recipient with the reason
it could not be delivered.
""".
-spec send_many([binary()], binary(), binary(), map()) ->
    {ok, [binary()], [{binary(), term()}]}.
send_many(PlayerIds, Type, Subject, Content) ->
    {Succeeded, Failed} = lists:partition(
        fun({_PlayerId, Result}) -> Result =:= ok end,
        [{PlayerId, attempt(PlayerId, Type, Subject, Content)} || PlayerId <- PlayerIds]
    ),
    {ok, [PlayerId || {PlayerId, _} <- Succeeded], [
        {PlayerId, Reason}
     || {PlayerId, {error, Reason}} <- Failed
    ]}.

-spec attempt(binary(), binary(), binary(), map()) -> ok | {error, term()}.
attempt(PlayerId, Type, Subject, Content) ->
    case send(PlayerId, Type, Subject, Content) of
        {ok, _Notif} -> ok;
        {error, Reason} -> {error, Reason}
    end.
