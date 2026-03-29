-module(asobi_matchmaker_controller).

-export([add/1, remove/1, status/1]).

-spec add(cowboy_req:req()) -> {json, integer(), map(), map()}.
add(#{json := Params, auth_data := #{player_id := PlayerId}} = _Req) ->
    MatchParams = #{
        mode => maps:get(~"mode", Params, ~"default"),
        properties => maps:get(~"properties", Params, #{}),
        party => maps:get(~"party", Params, [PlayerId])
    },
    {ok, TicketId} = asobi_matchmaker:add(PlayerId, MatchParams),
    {json, 200, #{}, #{ticket_id => TicketId, status => ~"pending"}}.

-spec remove(cowboy_req:req()) -> {json, map()}.
remove(#{bindings := #{~"ticket_id" := TicketId}, auth_data := #{player_id := PlayerId}} = _Req) ->
    asobi_matchmaker:remove(PlayerId, TicketId),
    {json, #{success => true}}.

-spec status(cowboy_req:req()) -> {json, map()} | {status, integer()}.
status(#{bindings := #{~"ticket_id" := TicketId}} = _Req) ->
    case asobi_matchmaker:get_ticket(TicketId) of
        {ok, Ticket} -> {json, Ticket};
        {error, not_found} -> {status, 404}
    end.
