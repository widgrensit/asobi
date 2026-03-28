-module(asobi_matchmaker_SUITE).

-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([
    add_ticket/1,
    remove_ticket/1,
    get_ticket/1
]).

all() -> [add_ticket, remove_ticket, get_ticket].

init_per_suite(Config) ->
    application:ensure_all_started(asobi),
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
    Config.
