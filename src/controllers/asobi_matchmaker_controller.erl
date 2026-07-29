-module(asobi_matchmaker_controller).

-export([add/1, remove/1, status/1]).

-spec add(cowboy_req:req()) -> {json, integer(), map(), map()}.
add(#{json := Params, auth_data := #{player_id := PlayerId}} = _Req) when
    is_map(Params), is_binary(PlayerId)
->
    Mode = maps:get(~"mode", Params, ~"default"),
    case asobi_matchmaker:known_mode(Mode) of
        false ->
            {json, 400, #{}, #{error => ~"unknown_mode"}};
        true ->
            MatchParams = #{
                mode => Mode,
                properties => maps:get(~"properties", Params, #{})
            },
            case asobi_matchmaker:add(PlayerId, MatchParams) of
                {ok, TicketId, Meta} ->
                    {json, 200, #{}, Meta#{ticket_id => TicketId, status => ~"pending"}};
                {error, queue_full} ->
                    {json, 503, #{}, #{error => ~"queue_full"}}
            end
    end.

-spec remove(cowboy_req:req()) -> {json, map()} | {status, integer()}.
remove(
    #{bindings := #{~"ticket_id" := TicketId}, auth_data := #{player_id := PlayerId}} = _Req
) when is_binary(PlayerId), is_binary(TicketId) ->
    case asobi_matchmaker:remove(PlayerId, TicketId) of
        ok -> {json, #{success => true}};
        {error, not_owner} -> {status, 403};
        {error, not_found} -> {status, 404}
    end.

-spec status(cowboy_req:req()) -> {json, map()} | {status, integer()}.
status(
    #{bindings := #{~"ticket_id" := TicketId}, auth_data := #{player_id := PlayerId}} = _Req
) when is_binary(PlayerId), is_binary(TicketId) ->
    case asobi_matchmaker:get_ticket(PlayerId, TicketId) of
        {ok, Ticket} ->
            %% Project an explicit shape rather than dumping the internal ticket
            %% map, so internal fields (attempts, player_id) never leak to the
            %% client. Keeps the public fields clients already read (`id`).
            {json, #{
                id => maps:get(id, Ticket),
                mode => maps:get(mode, Ticket),
                status => maps:get(status, Ticket),
                properties => maps:get(properties, Ticket, #{}),
                submitted_at => maps:get(submitted_at, Ticket)
            }};
        {error, not_owner} ->
            {status, 403};
        {error, not_found} ->
            {status, 404}
    end.
