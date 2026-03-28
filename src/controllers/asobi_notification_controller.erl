-module(asobi_notification_controller).

-export([index/1, mark_read/1, delete/1]).

-spec index(cowboy_req:req()) -> {json, map()}.
index(#{auth_data := #{player_id := PlayerId}, qs := Qs} = _Req) ->
    Params = cow_qs:parse_qs(Qs),
    Limit = binary_to_integer(proplists:get_value(~"limit", Params, ~"50")),
    Q0 = kura_query:where(kura_query:from(asobi_notification), {player_id, PlayerId}),
    Q1 =
        case proplists:get_value(~"read", Params) of
            ~"false" -> kura_query:where(Q0, {read, false});
            ~"true" -> kura_query:where(Q0, {read, true});
            _ -> Q0
        end,
    Q2 = kura_query:limit(kura_query:order_by(Q1, [{sent_at, desc}]), Limit),
    {ok, Notifications} = asobi_repo:all(Q2),
    {json, #{notifications => Notifications}}.

-spec mark_read(cowboy_req:req()) -> {json, map()} | {status, integer()}.
mark_read(#{bindings := #{~"id" := NotifId}, auth_data := #{player_id := PlayerId}} = _Req) ->
    case asobi_repo:get(asobi_notification, NotifId) of
        {ok, #{player_id := PlayerId} = Notif} ->
            CS = kura_changeset:cast(asobi_notification, Notif, #{read => true}, [read]),
            {ok, Updated} = asobi_repo:update(CS),
            {json, Updated};
        {ok, _} ->
            {status, 403};
        {error, not_found} ->
            {status, 404}
    end.

-spec delete(cowboy_req:req()) -> {json, map()} | {status, integer()}.
delete(#{bindings := #{~"id" := NotifId}, auth_data := #{player_id := PlayerId}} = _Req) ->
    case asobi_repo:get(asobi_notification, NotifId) of
        {ok, #{player_id := PlayerId} = Notif} ->
            _ = asobi_repo:delete(Notif),
            {json, #{success => true}};
        {ok, _} ->
            {status, 403};
        {error, not_found} ->
            {status, 404}
    end.
