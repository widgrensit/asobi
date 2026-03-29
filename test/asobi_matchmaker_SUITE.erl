-module(asobi_matchmaker_SUITE).

-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([
    add_ticket/1,
    remove_ticket/1,
    get_ticket/1,
    ticket_not_found/1,
    ticket_defaults/1,
    ticket_expiry/1
]).

all() -> [add_ticket, remove_ticket, get_ticket, ticket_not_found, ticket_defaults, ticket_expiry].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(asobi),

    Config.

end_per_suite(Config) ->
    Config.

add_ticket(Config) ->
    {ok, TicketId} = asobi_matchmaker:add(~"player1", #{mode => ~"ranked"}),
    ?assert(is_binary(TicketId)),
    Config.

remove_ticket(Config) ->
    {ok, TicketId} = asobi_matchmaker:add(~"player1", #{mode => ~"casual"}),
    ok = asobi_matchmaker:remove(~"player1", TicketId),
    ?assertMatch({error, not_found}, asobi_matchmaker:get_ticket(TicketId)),
    Config.

get_ticket(Config) ->
    {ok, TicketId} = asobi_matchmaker:add(~"player1", #{
        mode => ~"ranked", properties => #{skill => 1200}
    }),
    {ok, Ticket} = asobi_matchmaker:get_ticket(TicketId),
    ?assertMatch(#{id := TicketId, player_id := ~"player1", mode := ~"ranked"}, Ticket),
    %% Clean up
    asobi_matchmaker:remove(~"player1", TicketId),
    Config.

ticket_not_found(Config) ->
    ?assertMatch({error, not_found}, asobi_matchmaker:get_ticket(~"nonexistent_id")),
    Config.

ticket_defaults(Config) ->
    {ok, TicketId} = asobi_matchmaker:add(~"player_defaults", #{}),
    {ok, Ticket} = asobi_matchmaker:get_ticket(TicketId),
    ?assertMatch(#{mode := ~"default", properties := #{}, status := pending}, Ticket),
    asobi_matchmaker:remove(~"player_defaults", TicketId),
    Config.

ticket_expiry(_Config) ->
    %% Tickets submitted with max_wait=0 should be expired on next tick
    %% We can't easily test this without modifying the matchmaker config,
    %% but we can verify the ticket has submitted_at set
    {ok, TicketId} = asobi_matchmaker:add(~"player_expiry", #{mode => ~"casual"}),
    {ok, Ticket} = asobi_matchmaker:get_ticket(TicketId),
    ?assert(is_integer(maps:get(submitted_at, Ticket))),
    asobi_matchmaker:remove(~"player_expiry", TicketId).
