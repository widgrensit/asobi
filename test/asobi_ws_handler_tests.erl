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
%% producing extension travels in the payload's `module` key, and the wire
%% type is now `module.message`/`module.error`. The pre-S6 pair is emitted
%% alongside it so no shipped SDK breaks, and is removed at the 1.0 wire
%% break.

game_message_names_lua_by_default_test() ->
    Msg = {asobi_message, {game_message, ~"you are player 3"}},
    {reply, Frames, _State1} = asobi_ws_handler:websocket_info(Msg, #{}),
    Expected = #{~"module" => ~"lua", ~"message" => ~"you are player 3"},
    ?assertEqual(Expected, payload_of(~"module.message", Frames)),
    ?assertEqual(Expected, payload_of(~"game.message", Frames)).

game_message_carries_the_producing_extension_test() ->
    Msg = {asobi_message, {game_message, wasm, #{~"n" => 1}}},
    {reply, Frames, _State1} = asobi_ws_handler:websocket_info(Msg, #{}),
    Expected = #{~"module" => ~"wasm", ~"message" => #{~"n" => 1}},
    ?assertEqual(Expected, payload_of(~"module.message", Frames)),
    ?assertEqual(Expected, payload_of(~"game.message", Frames)).

script_error_names_lua_by_default_test() ->
    Payload = #{
        ~"callback" => ~"handle_input",
        ~"script" => ~"match.lua",
        ~"message" => ~"bad arithmetic + on nil, 1"
    },
    Msg = {asobi_message, {script_error, Payload}},
    {reply, Frames, _State1} = asobi_ws_handler:websocket_info(Msg, #{}),
    ?assertEqual(Payload#{~"module" => ~"lua"}, payload_of(~"module.error", Frames)),
    ?assertEqual(Payload#{~"module" => ~"lua"}, payload_of(~"game.error", Frames)).

script_error_carries_the_producing_extension_test() ->
    Msg = {asobi_message, {script_error, wasm, #{~"message" => ~"trap"}}},
    {reply, Frames, _State1} = asobi_ws_handler:websocket_info(Msg, #{}),
    Expected = #{~"module" => ~"wasm", ~"message" => ~"trap"},
    ?assertEqual(Expected, payload_of(~"module.error", Frames)),
    ?assertEqual(Expected, payload_of(~"game.error", Frames)).

%% asobi#347: the dual-emit only works because novaframework/nova#400
%% splices a list-valued reply into cowboy's command list. A nova without
%% that fix turns both frames into one malformed cowboy command and kills
%% the connection process - a failure no other asobi test would see,
%% because it happens below websocket_info/2's return value.
nova_splices_a_list_reply_into_separate_commands_test() ->
    ?assertEqual(
        #{commands => [{text, ~"a"}, {text, ~"b"}], controller_data => st},
        nova_basic_handler:handle_ws({reply, [{text, ~"a"}, {text, ~"b"}], st}, #{commands => []})
    ).

%% The dual-emit is what asobi#347's nova pin bought: nova 0.15.1 consed a
%% list-valued reply onto the command list as one cowboy command, so both
%% frames arrived at cow_ws:frame/2 as a single frame and took the
%% connection process down. Pin the frame count, not just the payloads -
%% a regression to a single frame is exactly what shipped in #330.
extension_frames_are_two_separate_frames_test() ->
    Msg = {asobi_message, {game_message, ~"hi"}},
    {reply, Frames, _State1} = asobi_ws_handler:websocket_info(Msg, #{}),
    ?assertEqual(2, length(Frames)),
    ?assertEqual([~"game.message", ~"module.message"], [type_of(F) || F <- Frames]).

%% The legacy pair is the compat cost, and `game.message` is `game.send/2`
%% - potentially one frame per player per tick. An operator whose clients
%% all dispatch `module.*` must be able to stop paying for it before 1.0.
legacy_game_frames_can_be_disabled_test() ->
    ok = application:set_env(asobi, ws_legacy_game_frames, false),
    try
        MsgOk = {asobi_message, {game_message, ~"hi"}},
        {reply, [Frame], _} = asobi_ws_handler:websocket_info(MsgOk, #{}),
        ?assertEqual(~"module.message", type_of(Frame)),
        MsgErr = {asobi_message, {script_error, #{~"message" => ~"boom"}}},
        {reply, [ErrFrame], _} = asobi_ws_handler:websocket_info(MsgErr, #{}),
        ?assertEqual(~"module.error", type_of(ErrFrame))
    after
        ok = application:unset_env(asobi, ws_legacy_game_frames)
    end.

%% The defensive encode path must still degrade to an `error` frame rather
%% than crashing the connection process. Asserted on `reason` rather than the
%% whole payload: the shared error object rides alongside it, and a test that
%% pins every key would fail on an additive change that breaks nothing.
%% Nothing of the unencodable payload may reach the client either way.
script_error_unencodable_payload_degrades_test() ->
    Msg = {asobi_message, {script_error, #{~"message" => {not_json}}}},
    {reply, Frames, _State1} = asobi_ws_handler:websocket_info(Msg, #{}),
    ?assertEqual(1, length(Frames)),
    Payload = payload_of(~"error", Frames),
    ?assertEqual(~"internal", maps:get(~"reason", Payload)),
    ?assertEqual(~"internal", maps:get(~"code", maps:get(~"error", Payload))),
    ?assertEqual([~"error", ~"reason"], lists:sort(maps:keys(Payload))).

%% module.event (asobi_extensions:emit/4): a named, routable server->client
%% event, distinct from the unnamed module.message dev frame. Emitted as a
%% single frame - it has no pre-S6 legacy alias, so unlike module.message it
%% does not dual-emit through extension_frames/3. `data` is always an object.
extension_event_encodes_the_named_push_envelope_test() ->
    Data = #{~"quest_id" => ~"01j8", ~"reward" => 250},
    Msg = {asobi_message, {extension_event, quests, ~"quests.completed", Data}},
    {reply, {text, Frame}, _State1} = asobi_ws_handler:websocket_info(Msg, #{}),
    ?assertEqual(
        #{
            ~"type" => ~"module.event",
            ~"payload" => #{
                ~"module" => ~"quests",
                ~"event" => ~"quests.completed",
                ~"data" => Data
            }
        },
        decode(Frame)
    ).

extension_event_is_a_single_frame_test() ->
    Msg = {asobi_message, {extension_event, quests, ~"quests.completed", #{}}},
    ?assertMatch({reply, {text, _}, _}, asobi_ws_handler:websocket_info(Msg, #{})).

%% The socket safety net: emit/4 normally rejects non-encodable data, but if a
%% bad term reaches the ws clause the encode is wrapped so it degrades to an
%% error frame rather than crashing this connection process - send/2 fans out
%% to every one of the player's session pids, so a crash would drop them all.
extension_event_unencodable_data_degrades_test() ->
    Msg = {asobi_message, {extension_event, quests, ~"x.y", #{~"k" => self()}}},
    {reply, {text, Frame}, _State1} = asobi_ws_handler:websocket_info(Msg, #{}),
    Decoded = decode(Frame),
    ?assertEqual(~"error", maps:get(~"type", Decoded)),
    ?assertEqual(~"internal", maps:get(~"reason", maps:get(~"payload", Decoded))).

type_of({text, Raw}) ->
    #{~"type" := Type} = decode(Raw),
    Type.

payload_of(Type, Frames) when is_list(Frames) ->
    [{text, Raw}] = [F || F <- Frames, type_of(F) =:= Type],
    #{~"payload" := Payload} = decode(Raw),
    Payload.

%% --- error frames carry both dialects ---

%% The shared error object (asobi_error) is additive: `reason` stays exactly
%% as it was so existing clients keep working, and `error` is added alongside
%% it for anything that wants to branch on a code.
oversized_frame_error_carries_reason_and_object_test() ->
    Big = binary:copy(~"x", 65537),
    {reply, {text, Frame}, _State} = asobi_ws_handler:websocket_handle({text, Big}, #{}),
    ?assertMatch(
        #{
            ~"type" := ~"error",
            ~"payload" := #{
                ~"reason" := ~"payload_too_large",
                ~"error" := #{
                    ~"code" := ~"payload_too_large",
                    ~"message" := _,
                    ~"details" := #{}
                }
            }
        },
        decode(Frame)
    ).

invalid_json_error_carries_object_test() ->
    {reply, {text, Frame}, _State} =
        asobi_ws_handler:websocket_handle({text, ~"{not json"}, fresh_state()),
    ?assertMatch(
        #{~"payload" := #{~"reason" := ~"invalid_json", ~"error" := #{~"code" := ~"invalid_json"}}},
        decode(Frame)
    ).

%% A reply to a request keeps its correlation id, and the error object rides
%% next to the legacy reason rather than replacing it.
unknown_type_error_keeps_cid_test() ->
    Raw = iolist_to_binary(json:encode(#{~"type" => ~"nope.nope", ~"cid" => ~"c-1"})),
    {reply, {text, Frame}, _State} =
        asobi_ws_handler:websocket_handle({text, Raw}, fresh_state()),
    ?assertMatch(
        #{
            ~"cid" := ~"c-1",
            ~"payload" := #{
                ~"reason" := ~"unknown_type",
                ~"error" := #{~"code" := ~"unknown_type", ~"details" := #{}}
            }
        },
        decode(Frame)
    ).

%% The interesting case: a legacy reason whose code is deliberately a
%% different, namespaced string. `invalid_token` stays on the wire untouched
%% while the code says `unauthenticated`.
reason_and_code_may_differ_test() ->
    Raw = iolist_to_binary(json:encode(#{~"type" => ~"session.connect", ~"payload" => #{}})),
    {reply, {text, Frame}, _State} =
        asobi_ws_handler:websocket_handle({text, Raw}, fresh_state()),
    ?assertMatch(
        #{
            ~"payload" := #{
                ~"reason" := ~"invalid_token",
                ~"error" := #{~"code" := ~"unauthenticated"}
            }
        },
        decode(Frame)
    ).

decode(Frame) ->
    json:decode(iolist_to_binary(Frame)).

fresh_state() ->
    #{ws_msg_count => 0, ws_msg_window_start => erlang:system_time(millisecond)}.

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
