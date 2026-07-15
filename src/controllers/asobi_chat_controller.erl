-module(asobi_chat_controller).

-export([history/1]).

-define(MAX_HISTORY_LIMIT, 200).
-define(DEFAULT_HISTORY_LIMIT, 50).

-spec history(cowboy_req:req()) -> {json, map()} | {json, integer(), map(), map()} | {status, 403}.
history(
    #{
        bindings := #{~"channel_id" := ChannelId},
        qs := Qs,
        auth_data := #{player_id := PlayerId}
    } = _Req
) when
    is_binary(ChannelId), is_binary(Qs), is_binary(PlayerId)
->
    case asobi_chat_acl:authorized(ChannelId, PlayerId) of
        true ->
            Params = cow_qs:parse_qs(Qs),
            Limit = asobi_qs:integer(
                ~"limit", Params, ?DEFAULT_HISTORY_LIMIT, 1, ?MAX_HISTORY_LIMIT
            ),
            Q = kura_query:limit(
                kura_query:order_by(
                    kura_query:where(kura_query:from(asobi_chat_message), {channel_id, ChannelId}),
                    [{sent_at, desc}]
                ),
                Limit
            ),
            {ok, Messages} = asobi_repo:all(Q),
            {json, #{messages => lists:reverse(Messages)}};
        false ->
            {status, 403}
    end;
history(_Req) ->
    {json, 400, #{}, #{error => ~"invalid_request"}}.
