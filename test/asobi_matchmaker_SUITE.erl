-module(asobi_matchmaker_SUITE).

-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([
    add_ticket/1,
    remove_ticket/1,
    get_ticket/1,
    ticket_not_found/1,
    ticket_defaults/1,
    ticket_expiry/1,
    add_idempotent_same_player_mode/1,
    add_distinct_modes_new_ticket/1,
    add_distinct_players_new_ticket/1
]).

all() ->
    [
        add_ticket,
        remove_ticket,
        get_ticket,
        ticket_not_found,
        ticket_defaults,
        ticket_expiry,
        add_idempotent_same_player_mode,
        add_distinct_modes_new_ticket,
        add_distinct_players_new_ticket
    ].

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

%% Re-adding while already queued for the same mode is idempotent: same ticket
%% id, no second ticket. This is the self-match guard (asobi#230) - two tickets
%% for one player would otherwise fill each other into a match.
add_idempotent_same_player_mode(Config) ->
    {ok, #{total := Before}} = asobi_matchmaker:get_queue_stats(),
    {ok, T1} = asobi_matchmaker:add(~"player_idem", #{mode => ~"ranked"}),
    {ok, T2} = asobi_matchmaker:add(~"player_idem", #{mode => ~"ranked"}),
    ?assertEqual(T1, T2),
    {ok, #{total := After}} = asobi_matchmaker:get_queue_stats(),
    ?assertEqual(Before + 1, After),
    asobi_matchmaker:remove(~"player_idem", T1),
    ?assertMatch({error, not_found}, asobi_matchmaker:get_ticket(T1)),
    Config.

%% The guard is per (player, mode): the same player in a different mode gets a
%% distinct ticket.
add_distinct_modes_new_ticket(Config) ->
    {ok, T1} = asobi_matchmaker:add(~"player_modes", #{mode => ~"ranked"}),
    {ok, T2} = asobi_matchmaker:add(~"player_modes", #{mode => ~"casual"}),
    ?assertNotEqual(T1, T2),
    asobi_matchmaker:remove(~"player_modes", T1),
    asobi_matchmaker:remove(~"player_modes", T2),
    Config.

%% Different players in the same mode each get their own ticket (the guard must
%% not collapse distinct players).
add_distinct_players_new_ticket(Config) ->
    {ok, T1} = asobi_matchmaker:add(~"player_a", #{mode => ~"ranked"}),
    {ok, T2} = asobi_matchmaker:add(~"player_b", #{mode => ~"ranked"}),
    ?assertNotEqual(T1, T2),
    asobi_matchmaker:remove(~"player_a", T1),
    asobi_matchmaker:remove(~"player_b", T2),
    Config.
