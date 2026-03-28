-module(asobi_chat_controller).

-export([history/1]).

-spec history(cowboy_req:req()) -> {json, map()}.
history(#{bindings := #{~"channel_id" := ChannelId}, qs := Qs} = _Req) ->
    Params = cow_qs:parse_qs(Qs),
    Limit = binary_to_integer(proplists:get_value(~"limit", Params, ~"50")),
    Q = kura_query:limit(
        kura_query:order_by(
            kura_query:where(kura_query:from(asobi_chat_message), {channel_id, ChannelId}),
            [{sent_at, desc}]
        ),
        Limit
    ),
    {ok, Messages} = asobi_repo:all(Q),
    {json, #{messages => lists:reverse(Messages)}}.
