-module(asobi_ws_handler_tests).

-include_lib("eunit/include/eunit.hrl").

%% logger_handler callback used by the #303 rejection tests below to prove
%% a rejected event name is logged, not silently dropped.
-export([log/2]).

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

%% #303: a script-supplied binary name still reaches the wire when it's
%% valid ASCII, unreserved, and within the size cap — the happy path the
%% hardening must not regress.
world_event_valid_binary_name_still_works_test() ->
    Msg = {asobi_message, {world_event, ~"pong", #{}}},
    {reply, {text, Frame}, _State1} = asobi_ws_handler:websocket_info(Msg, #{}),
    ?assertMatch(#{~"type" := ~"world.pong"}, json:decode(iolist_to_binary(Frame))).

%% #303 finding 1: a non-ASCII (here, invalid-UTF-8) event name must not
%% crash json:encode/1 inside the caller's process — it is dropped with a
%% logged warning instead of producing a frame or a crash.
world_event_non_ascii_name_is_rejected_and_logged_test() ->
    ok = install_log_capture(),
    BadName = <<"evt", 255>>,
    Msg = {asobi_message, {world_event, BadName, #{}}},
    ?assertEqual({ok, #{}}, asobi_ws_handler:websocket_info(Msg, #{})),
    ?assertEqual(#{namespace => ~"world", reason => invalid_event_name}, await_rejection()),
    ok = remove_log_capture().

%% #303: an oversized name is dropped rather than silently truncated or
%% forwarded — same log-not-crash contract as the non-ASCII case.
world_event_oversized_name_is_rejected_and_logged_test() ->
    ok = install_log_capture(),
    TooLong = list_to_binary(lists:duplicate(65, $a)),
    Msg = {asobi_message, {world_event, TooLong, #{}}},
    ?assertEqual({ok, #{}}, asobi_ws_handler:websocket_info(Msg, #{})),
    ?assertEqual(#{namespace => ~"world", reason => invalid_event_name}, await_rejection()),
    ok = remove_log_capture().

%% #303 finding 2: a name equal to a reserved library event name must be
%% dropped, not forwarded as a byte-identical forged frame.
world_event_reserved_name_is_rejected_and_logged_test() ->
    ok = install_log_capture(),
    Msg = {asobi_message, {world_event, ~"tick", #{}}},
    ?assertEqual({ok, #{}}, asobi_ws_handler:websocket_info(Msg, #{})),
    ?assertEqual(#{namespace => ~"world", reason => reserved_event_name}, await_rejection()),
    ok = remove_log_capture().

match_event_reserved_name_is_rejected_and_logged_test() ->
    ok = install_log_capture(),
    Msg = {asobi_message, {match_event, ~"state", #{}}},
    ?assertEqual({ok, #{}}, asobi_ws_handler:websocket_info(Msg, #{})),
    ?assertEqual(#{namespace => ~"match", reason => reserved_event_name}, await_rejection()),
    ok = remove_log_capture().

%% #308: the catch-all clause still drops what it cannot encode, but the
%% drop must leave a signal - the tag of the unrecognised message - so the
%% next producer that invents an {asobi_message, _} shape shows up in the
%% logs instead of needing another bug-hunt.
unknown_asobi_message_is_logged_test() ->
    ok = install_log_capture(),
    Msg = {asobi_message, {brand_new_shape, #{~"a" => 1}}},
    ?assertEqual({ok, #{}}, asobi_ws_handler:websocket_info(Msg, #{})),
    ?assertEqual({asobi_message, brand_new_shape}, await_unhandled()),
    ok = remove_log_capture().

unknown_bare_message_is_logged_test() ->
    ok = install_log_capture(),
    ?assertEqual({ok, #{}}, asobi_ws_handler:websocket_info(some_stray_message, #{})),
    ?assertEqual(some_stray_message, await_unhandled()),
    ok = remove_log_capture().

%% A sender-controlled tag must not widen the log field or the rate
%% limiter's key space.
non_atom_tag_collapses_to_unknown_test() ->
    ok = install_log_capture(),
    Msg = {asobi_message, {~"from_the_wire", 1}},
    ?assertEqual({ok, #{}}, asobi_ws_handler:websocket_info(Msg, #{})),
    ?assertEqual({asobi_message, unknown}, await_unhandled()),
    ok = remove_log_capture().

%% Handled shapes must not start logging as unhandled.
handled_message_is_not_logged_as_unhandled_test() ->
    ok = install_log_capture(),
    Msg = {asobi_message, {world_event, ~"pong", #{}}},
    ?assertMatch({reply, {text, _}, _}, asobi_ws_handler:websocket_info(Msg, #{})),
    ?assertEqual(no_log, await_no_unhandled()),
    ok = remove_log_capture().

%% S6: `game.message`/`game.error` named one extension (Lua) inside the
%% client wire, which five of seven SDKs cannot extend at runtime. The
%% generalised `module.message`/`module.error` frames carry the producing
%% extension in the payload instead. Both are emitted for one release, so
%% every one of these asserts the old frame is still on the wire next to
%% the new one.

game_message_emits_both_frames_test() ->
    Msg = {asobi_message, {game_message, ~"you are player 3"}},
    {reply, Frames, _State1} = asobi_ws_handler:websocket_info(Msg, #{}),
    ?assertEqual(
        #{~"message" => ~"you are player 3"},
        payload_of(~"game.message", Frames)
    ),
    ?assertEqual(
        #{~"module" => ~"lua", ~"message" => ~"you are player 3"},
        payload_of(~"module.message", Frames)
    ).

game_message_carries_the_producing_extension_test() ->
    Msg = {asobi_message, {game_message, wasm, #{~"n" => 1}}},
    {reply, Frames, _State1} = asobi_ws_handler:websocket_info(Msg, #{}),
    ?assertEqual(
        #{~"module" => ~"wasm", ~"message" => #{~"n" => 1}},
        payload_of(~"module.message", Frames)
    ),
    ?assertEqual(#{~"message" => #{~"n" => 1}}, payload_of(~"game.message", Frames)).

script_error_emits_both_frames_test() ->
    Payload = #{
        ~"callback" => ~"handle_input",
        ~"script" => ~"match.lua",
        ~"message" => ~"bad arithmetic + on nil, 1"
    },
    Msg = {asobi_message, {script_error, Payload}},
    {reply, Frames, _State1} = asobi_ws_handler:websocket_info(Msg, #{}),
    ?assertEqual(Payload, payload_of(~"game.error", Frames)),
    ?assertEqual(Payload#{~"module" => ~"lua"}, payload_of(~"module.error", Frames)).

script_error_carries_the_producing_extension_test() ->
    Msg = {asobi_message, {script_error, wasm, #{~"message" => ~"trap"}}},
    {reply, Frames, _State1} = asobi_ws_handler:websocket_info(Msg, #{}),
    ?assertEqual(
        #{~"module" => ~"wasm", ~"message" => ~"trap"},
        payload_of(~"module.error", Frames)
    ).

%% The defensive encode path must still degrade to a single `error` frame
%% rather than crashing the connection process — now covering both frames.
script_error_unencodable_payload_degrades_test() ->
    Msg = {asobi_message, {script_error, #{~"message" => {not_json}}}},
    {reply, Frames, _State1} = asobi_ws_handler:websocket_info(Msg, #{}),
    ?assertEqual(1, length(Frames)),
    ?assertEqual(#{~"reason" => ~"internal"}, payload_of(~"error", Frames)).

payload_of(Type, Frames) ->
    Decoded = [json:decode(iolist_to_binary(F)) || {text, F} <- Frames],
    case [P || #{~"type" := T, ~"payload" := P} <- Decoded, T =:= Type] of
        [Payload] -> Payload;
        Other -> error({no_single_frame_of_type, Type, Other})
    end.

%% --- log capture helpers ---

install_log_capture() ->
    logger:add_handler(?MODULE, ?MODULE, #{level => warning, config => #{pid => self()}}).

remove_log_capture() ->
    logger:remove_handler(?MODULE).

%% logger_handler callback: forwards only the rejection report this test
%% suite cares about to the installing test process, filtering out any
%% unrelated warning-level log traffic from the rest of the system.
log(#{msg := {report, #{msg := ~"game_broadcast_rejected"} = Report}}, #{config := #{pid := Pid}}) ->
    Pid ! {game_broadcast_rejected, maps:with([namespace, reason], Report)},
    ok;
log(#{msg := {report, #{event := ws_unhandled_info, tag := Tag}}}, #{config := #{pid := Pid}}) ->
    Pid ! {ws_unhandled_info, Tag},
    ok;
log(_Event, _Config) ->
    ok.

await_rejection() ->
    receive
        {game_broadcast_rejected, Report} -> Report
    after 1000 ->
        error(timeout_waiting_for_rejection_log)
    end.

await_unhandled() ->
    receive
        {ws_unhandled_info, Tag} -> Tag
    after 1000 ->
        error(timeout_waiting_for_unhandled_log)
    end.

await_no_unhandled() ->
    receive
        {ws_unhandled_info, Tag} -> {unexpected, Tag}
    after 200 ->
        no_log
    end.
