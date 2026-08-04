-module(asobi_dm_controller).

-export([send/1, history/1]).

-spec send(cowboy_req:req()) ->
    {json, integer(), map(), map()} | {asobi_error, asobi_error:code()}.
send(#{
    json := #{~"recipient_id" := RecipientId, ~"content" := Content},
    auth_data := #{player_id := PlayerId}
}) when is_binary(RecipientId), is_binary(Content), is_binary(PlayerId) ->
    case asobi_dm:send(PlayerId, RecipientId, Content) of
        ok ->
            {json, 200, #{}, #{
                success => true, channel_id => asobi_dm:channel_id(PlayerId, RecipientId)
            }};
        {error, blocked} ->
            {asobi_error, ~"dm.blocked"};
        {error, content_empty} ->
            {asobi_error, ~"dm.content_empty"};
        {error, content_too_large} ->
            {asobi_error, ~"dm.content_too_large"};
        {error, _} ->
            {asobi_error, ~"invalid_payload"}
    end;
send(_Req) ->
    {asobi_error, ~"invalid_payload"}.

-spec history(cowboy_req:req()) -> {json, map()}.
history(#{
    bindings := #{~"player_id" := OtherPlayerId},
    qs := Qs,
    auth_data := #{player_id := PlayerId}
}) when is_binary(OtherPlayerId), is_binary(PlayerId) ->
    Params = cow_qs:parse_qs(Qs),
    Limit = asobi_qs:integer(~"limit", Params, 50, 1, 200),
    Messages = asobi_dm:history(PlayerId, OtherPlayerId, Limit),
    {json, #{messages => Messages, channel_id => asobi_dm:channel_id(PlayerId, OtherPlayerId)}}.
