-module(asobi_player_session_tests).

-include_lib("eunit/include/eunit.hrl").

%% asobi#477: world.ack must be monotonic per connection.
%%
%% The seq is the client's own counter, but the server records the high-water
%% mark per zone, and a crossing player stays subscribed to the zone they left
%% whenever it stays in their interest ring. That zone keeps emitting its own
%% mark, so without a filter here the client sees seq go backwards and a
%% prune-and-replay reconciler re-applies input the server already consumed.
%%
%% handle_info/2 is a plain function over a state map, so these drive it
%% directly rather than standing up a session process.

state() ->
    #{player_id => ~"p1", ws_pid => self(), last_ack_seq => -1}.

recv() ->
    receive
        {asobi_message, {world_ack, _Tick, Seq}} -> Seq
    after 0 -> no_ack
    end.

an_advancing_ack_is_forwarded_and_recorded_test() ->
    {noreply, S1} = asobi_player_session:handle_info(
        {asobi_message, {world_ack, 1, 412}}, state()
    ),
    ?assertEqual(412, recv()),
    ?assertEqual(412, maps:get(last_ack_seq, S1)).

a_stale_ack_from_the_zone_left_behind_is_dropped_test() ->
    %% The crossing: the new zone acks 500, then the old zone emits its frozen
    %% 413 on the same broadcast tick. Only the first reaches the client.
    {noreply, S1} = asobi_player_session:handle_info(
        {asobi_message, {world_ack, 9, 500}}, state()
    ),
    ?assertEqual(500, recv()),
    {noreply, S2} = asobi_player_session:handle_info(
        {asobi_message, {world_ack, 9, 413}}, S1
    ),
    ?assertEqual(no_ack, recv()),
    ?assertEqual(500, maps:get(last_ack_seq, S2)).

a_repeated_ack_is_dropped_test() ->
    %% A zone re-emits its unchanged mark every broadcast tick while the player
    %% sends nothing. Forwarding those is pure noise on the socket.
    {noreply, S1} = asobi_player_session:handle_info(
        {asobi_message, {world_ack, 1, 77}}, state()
    ),
    ?assertEqual(77, recv()),
    {noreply, _S2} = asobi_player_session:handle_info(
        {asobi_message, {world_ack, 2, 77}}, S1
    ),
    ?assertEqual(no_ack, recv()).

seq_zero_is_a_real_value_test() ->
    %% last_ack_seq starts at -1 precisely so that seq 0 advances it.
    {noreply, S1} = asobi_player_session:handle_info(
        {asobi_message, {world_ack, 1, 0}}, state()
    ),
    ?assertEqual(0, recv()),
    ?assertEqual(0, maps:get(last_ack_seq, S1)).

other_messages_still_pass_through_test() ->
    {noreply, _} = asobi_player_session:handle_info(
        {asobi_message, {world_tick, 1}}, state()
    ),
    receive
        {asobi_message, {world_tick, 1}} -> ok
    after 0 -> ?assert(false, "world_tick was swallowed by the ack filter")
    end.
