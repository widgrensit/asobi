-module(asobi_ws_handler_tests).

-include_lib("eunit/include/eunit.hrl").

%% #297: game.broadcast(event, payload) from a Lua world/match script sends
%% Event as a binary. Before the fix, websocket_info/2's world_event and
%% match_event clauses were guarded `when is_atom(Event)` only, so a binary
%% event name fell through to the catch-all clause and was silently
%% dropped — no frame, no error, no log. These tests call websocket_info/2
%% directly (a pure function given a plain State map) to prove a binary
%% event name now produces a text frame with the expected wire envelope.

world_event_binary_name_reaches_socket_test() ->
    Msg = {asobi_message, {world_event, ~"door_opened", #{~"room" => 1}}},
    {reply, {text, Frame}, _State1} = asobi_ws_handler:websocket_info(Msg, #{}),
    ?assertMatch(
        #{~"type" := ~"world.door_opened", ~"payload" := #{~"room" := 1}},
        json:decode(iolist_to_binary(Frame))
    ).

world_event_atom_name_still_works_test() ->
    Msg = {asobi_message, {world_event, finished, #{}}},
    {reply, {text, Frame}, _State1} = asobi_ws_handler:websocket_info(Msg, #{}),
    ?assertMatch(#{~"type" := ~"world.finished"}, json:decode(iolist_to_binary(Frame))).

match_event_binary_name_reaches_socket_test() ->
    Msg = {asobi_message, {match_event, ~"round_started", #{~"round" => 2}}},
    {reply, {text, Frame}, _State1} = asobi_ws_handler:websocket_info(Msg, #{}),
    ?assertMatch(
        #{~"type" := ~"match.round_started", ~"payload" := #{~"round" := 2}},
        json:decode(iolist_to_binary(Frame))
    ).

match_event_atom_name_still_works_test() ->
    Msg = {asobi_message, {match_event, finished, #{}}},
    {reply, {text, Frame}, _State1} = asobi_ws_handler:websocket_info(Msg, #{}),
    ?assertMatch(#{~"type" := ~"match.finished"}, json:decode(iolist_to_binary(Frame))).

%% A non-atom, non-binary Event (a shape that should never occur, but the
%% guard is now `is_atom(Event); is_binary(Event)` rather than a catch-all)
%% must still fall through harmlessly rather than crash the connection
%% process.
world_event_other_type_is_ignored_test() ->
    Msg = {asobi_message, {world_event, 123, #{}}},
    ?assertEqual({ok, #{}}, asobi_ws_handler:websocket_info(Msg, #{})).
