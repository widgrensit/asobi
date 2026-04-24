-module(asobi_dm_controller).

-export([send/1, history/1]).

-spec send(cowboy_req:req()) -> {json, map()} | {json, integer(), map(), map()}.
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
            {json, 403, #{}, #{error => ~"blocked"}}
    end.

-spec history(cowboy_req:req()) -> {json, map()}.
history(#{
    bindings := #{~"player_id" := OtherPlayerId},
    qs := Qs,
    auth_data := #{player_id := PlayerId}
}) when is_binary(OtherPlayerId), is_binary(PlayerId) ->
    Params = cow_qs:parse_qs(Qs),
    Limit =
        case proplists:get_value(~"limit", Params) of
            V when is_binary(V) -> binary_to_integer(V);
            _ -> 50
        end,
    Messages = asobi_dm:history(PlayerId, OtherPlayerId, Limit),
    {json, #{messages => Messages, channel_id => asobi_dm:channel_id(PlayerId, OtherPlayerId)}}.
