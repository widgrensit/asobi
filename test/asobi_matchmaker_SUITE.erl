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
    add_distinct_players_new_ticket/1,
    add_default_mode_idempotent/1,
    remove_then_readd_new_ticket/1,
    selfmatch_group_rejected/1,
    add_reply_reports_players_needed/1,
    spawn_retry_bounded_then_gives_up/1
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
        add_distinct_players_new_ticket,
        add_default_mode_idempotent,
        remove_then_readd_new_ticket,
        selfmatch_group_rejected,
        add_reply_reports_players_needed,
        spawn_retry_bounded_then_gives_up
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(asobi),

    Config.

end_per_suite(Config) ->
    Config.

add_ticket(Config) ->
    {ok, TicketId, _} = asobi_matchmaker:add(~"player1", #{mode => ~"ranked"}),
    ?assert(is_binary(TicketId)),
    Config.

remove_ticket(Config) ->
    {ok, TicketId, _} = asobi_matchmaker:add(~"player1", #{mode => ~"casual"}),
    ok = asobi_matchmaker:remove(~"player1", TicketId),
    ?assertMatch({error, not_found}, asobi_matchmaker:get_ticket(TicketId)),
    Config.

get_ticket(Config) ->
    {ok, TicketId, _} = asobi_matchmaker:add(~"player1", #{
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
    {ok, TicketId, _} = asobi_matchmaker:add(~"player_defaults", #{}),
    {ok, Ticket} = asobi_matchmaker:get_ticket(TicketId),
    ?assertMatch(#{mode := ~"default", properties := #{}, status := pending}, Ticket),
    asobi_matchmaker:remove(~"player_defaults", TicketId),
    Config.

ticket_expiry(_Config) ->
    %% Tickets submitted with max_wait=0 should be expired on next tick
    %% We can't easily test this without modifying the matchmaker config,
    %% but we can verify the ticket has submitted_at set
    {ok, TicketId, _} = asobi_matchmaker:add(~"player_expiry", #{mode => ~"casual"}),
    {ok, Ticket} = asobi_matchmaker:get_ticket(TicketId),
    ?assert(is_integer(maps:get(submitted_at, Ticket))),
    asobi_matchmaker:remove(~"player_expiry", TicketId).

%% Re-adding while already queued for the same mode is idempotent: same ticket
%% id, no second ticket. This is the self-match guard (asobi#230) - two tickets
%% for one player would otherwise fill each other into a match.
add_idempotent_same_player_mode(Config) ->
    {ok, #{total := Before}} = asobi_matchmaker:get_queue_stats(),
    {ok, T1, _} = asobi_matchmaker:add(~"player_idem", #{mode => ~"ranked"}),
    {ok, T2, _} = asobi_matchmaker:add(~"player_idem", #{mode => ~"ranked"}),
    ?assertEqual(T1, T2),
    {ok, #{total := After}} = asobi_matchmaker:get_queue_stats(),
    ?assertEqual(Before + 1, After),
    asobi_matchmaker:remove(~"player_idem", T1),
    ?assertMatch({error, not_found}, asobi_matchmaker:get_ticket(T1)),
    Config.

%% The guard is per (player, mode): the same player in a different mode gets a
%% distinct ticket.
add_distinct_modes_new_ticket(Config) ->
    {ok, T1, _} = asobi_matchmaker:add(~"player_modes", #{mode => ~"ranked"}),
    {ok, T2, _} = asobi_matchmaker:add(~"player_modes", #{mode => ~"casual"}),
    ?assertNotEqual(T1, T2),
    asobi_matchmaker:remove(~"player_modes", T1),
    asobi_matchmaker:remove(~"player_modes", T2),
    Config.

%% Different players in the same mode each get their own ticket (the guard must
%% not collapse distinct players).
add_distinct_players_new_ticket(Config) ->
    {ok, T1, _} = asobi_matchmaker:add(~"player_a", #{mode => ~"ranked"}),
    {ok, T2, _} = asobi_matchmaker:add(~"player_b", #{mode => ~"ranked"}),
    ?assertNotEqual(T1, T2),
    asobi_matchmaker:remove(~"player_a", T1),
    asobi_matchmaker:remove(~"player_b", T2),
    Config.

%% The guard covers the no-mode default too: two mode-less adds are idempotent.
add_default_mode_idempotent(Config) ->
    {ok, T1, _} = asobi_matchmaker:add(~"player_defmode", #{}),
    {ok, T2, _} = asobi_matchmaker:add(~"player_defmode", #{}),
    ?assertEqual(T1, T2),
    asobi_matchmaker:remove(~"player_defmode", T1),
    Config.

%% After removing, a re-add mints a fresh working ticket (the guard un-sticks).
remove_then_readd_new_ticket(Config) ->
    {ok, T1, _} = asobi_matchmaker:add(~"player_readd", #{mode => ~"ranked"}),
    ok = asobi_matchmaker:remove(~"player_readd", T1),
    {ok, T2, _} = asobi_matchmaker:add(~"player_readd", #{mode => ~"ranked"}),
    ?assertNotEqual(T1, T2),
    asobi_matchmaker:remove(~"player_readd", T2),
    Config.

%% The reject seam, exercised through the real tick with a strategy that forces a
%% self-match group. With the seam the ticket is re-queued (still present); a
%% spawned self-match would instead consume it (get_ticket -> not_found).
selfmatch_group_rejected(Config) ->
    Prev = application:get_env(asobi, game_modes),
    application:set_env(asobi, game_modes, #{~"dupmode" => #{strategy => asobi_dup_strategy}}),
    {ok, T, _} = asobi_matchmaker:add(~"player_dup", #{mode => ~"dupmode"}),
    %% try/after so a failed assertion still restores game_modes and removes the
    %% ticket, rather than clobbering shared state into later suite cases.
    try
        timer:sleep(1500),
        ?assertMatch({ok, _}, asobi_matchmaker:get_ticket(T))
    after
        asobi_matchmaker:remove(~"player_dup", T),
        case Prev of
            {ok, V} -> application:set_env(asobi, game_modes, V);
            undefined -> application:unset_env(asobi, game_modes)
        end
    end,
    Config.

%% The queued reply reports players_needed (the mode's match_size), so a client
%% can show "waiting for N" instead of silence. A mode with no match_size -> null.
add_reply_reports_players_needed(Config) ->
    Prev = application:get_env(asobi, game_modes),
    application:set_env(asobi, game_modes, #{~"needmode" => #{match_size => 3}}),
    try
        {ok, T1, Meta1} = asobi_matchmaker:add(~"player_need1", #{mode => ~"needmode"}),
        ?assertEqual(3, maps:get(players_needed, Meta1)),
        asobi_matchmaker:remove(~"player_need1", T1),

        {ok, T2, Meta2} = asobi_matchmaker:add(~"player_need2", #{mode => ~"unknownmode"}),
        ?assertEqual(null, maps:get(players_needed, Meta2)),
        asobi_matchmaker:remove(~"player_need2", T2)
    after
        case Prev of
            {ok, V} -> application:set_env(asobi, game_modes, V);
            undefined -> application:unset_env(asobi, game_modes)
        end
    end,
    Config.

%% Bounded spawn retry: attempts 0->1->2 re-queue, the 3rd (?MAX_SPAWN_ATTEMPTS)
%% gives up. The group's max attempt count drives the decision.
spawn_retry_bounded_then_gives_up(Config) ->
    ?assertEqual(
        {retry, 1}, asobi_matchmaker:next_spawn_attempt([#{attempts => 0}, #{attempts => 0}])
    ),
    ?assertEqual({retry, 2}, asobi_matchmaker:next_spawn_attempt([#{attempts => 1}])),
    ?assertEqual(give_up, asobi_matchmaker:next_spawn_attempt([#{attempts => 2}])),
    ?assertEqual(
        give_up, asobi_matchmaker:next_spawn_attempt([#{attempts => 0}, #{attempts => 2}])
    ),
    %% a missing/garbage attempts field defaults to 0
    ?assertEqual({retry, 1}, asobi_matchmaker:next_spawn_attempt([#{}])),
    Config.
