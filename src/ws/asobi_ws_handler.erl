-module(asobi_ws_handler).
-behaviour(nova_websocket).

-export([init/1, websocket_init/1, websocket_handle/2, websocket_info/2, terminate/3]).

-define(WS_MSG_LIMIT, 60).
-define(WS_MSG_WINDOW_MS, 1000).
-define(WS_MAX_PAYLOAD_BYTES, 65536).

-spec init(map()) -> {ok, map()}.
init(State) ->
    {ok, State#{session => undefined}}.

-spec websocket_init(map()) -> {ok, map()}.
websocket_init(State) ->
    asobi_telemetry:ws_connected(),
    {ok, State#{
        connected_at => erlang:system_time(millisecond),
        ws_msg_count => 0,
        ws_msg_window_start => erlang:system_time(millisecond)
    }}.

-spec websocket_handle({text | binary, binary()}, map()) ->
    {ok, map()} | {reply, {text, binary()}, map()}.
websocket_handle({text, Raw}, State) ->
    case byte_size(Raw) > ?WS_MAX_PAYLOAD_BYTES of
        true ->
            Reply = encode_reply(undefined, ~"error", #{reason => ~"payload_too_large"}),
            {reply, {text, Reply}, State};
        false ->
            case check_ws_rate_limit(State) of
                {ok, State1} ->
                    try json:decode(Raw) of
                        #{~"type" := Type} = Msg when is_binary(Type) ->
                            asobi_telemetry:ws_message_in(Type),
                            safe_handle_message(Msg, State1);
                        _ ->
                            Reply = encode_reply(undefined, ~"error", #{
                                reason => ~"invalid_message"
                            }),
                            {reply, {text, Reply}, State1}
                    catch
                        _:_ ->
                            Reply = encode_reply(undefined, ~"error", #{reason => ~"invalid_json"}),
                            {reply, {text, Reply}, State1}
                    end;
                {rate_limited, State1} ->
                    Reply = encode_reply(undefined, ~"error", #{reason => ~"rate_limited"}),
                    {reply, {text, Reply}, State1}
            end
    end;
websocket_handle(_Frame, State) ->
    {ok, State}.

-spec websocket_info(term(), map()) ->
    {ok, map()} | {reply, {text, binary()}, map()} | {stop, map()}.
websocket_info({asobi_message, {match_state, MatchState}}, State) ->
    Reply = encode_reply(undefined, ~"match.state", MatchState),
    {reply, {text, Reply}, State};
websocket_info({asobi_message, {match_event, Event, Payload}}, State) when is_atom(Event) ->
    Type = iolist_to_binary([~"match.", atom_to_binary(Event)]),
    Reply = encode_reply(undefined, Type, Payload),
    {reply, {text, Reply}, State};
websocket_info({asobi_message, {zone_delta, TickN, Deltas}}, State) ->
    Reply = encode_reply(undefined, ~"world.tick", #{tick => TickN, updates => Deltas}),
    {reply, {text, Reply}, State};
websocket_info({asobi_message, {world_event, Event, Payload}}, State) when is_atom(Event) ->
    Type = iolist_to_binary([~"world.", atom_to_binary(Event)]),
    Reply = encode_reply(undefined, Type, Payload),
    {reply, {text, Reply}, State};
websocket_info({chat_message, ChannelId, Msg}, State) when is_map(Msg) ->
    Reply = encode_reply(undefined, ~"chat.message", Msg#{channel_id => ChannelId}),
    {reply, {text, Reply}, State};
websocket_info({asobi_message, {dm_message, Msg}}, State) when is_map(Msg) ->
    Reply = encode_reply(undefined, ~"dm.message", Msg),
    {reply, {text, Reply}, State};
websocket_info({asobi_message, {notification, Notif}}, State) ->
    Reply = encode_reply(undefined, ~"notification.new", Notif),
    {reply, {text, Reply}, State};
websocket_info({session_revoked, Reason}, State) ->
    logger:notice(#{msg => ~"session_revoked", reason => Reason}),
    {stop, State#{session => undefined}};
websocket_info(_Info, State) ->
    {ok, State}.

-spec terminate(term(), term(), map()) -> ok.
terminate(_Reason, _Req, #{session := undefined}) ->
    asobi_telemetry:ws_disconnected(),
    ok;
terminate(_Reason, _Req, #{session := SessionPid}) ->
    asobi_telemetry:ws_disconnected(),
    asobi_player_session:stop(SessionPid),
    ok.

%% --- Message Routing ---

handle_message(#{~"type" := ~"session.connect", ~"payload" := Payload} = Msg, State) ->
    Cid = maps:get(~"cid", Msg, undefined),
    case authenticate(Payload) of
        {ok, PlayerId} ->
            {ok, SessionPid} = asobi_player_session_sup:start_session(PlayerId, self()),
            asobi_telemetry:session_connected(PlayerId),
            %% Check for pending world reconnection
            _ =
                case ets:lookup(asobi_player_worlds, PlayerId) of
                    [{PlayerId, WorldPid}] ->
                        _ = spawn(fun() ->
                            catch asobi_world_server:reconnect(WorldPid, PlayerId)
                        end);
                    [] ->
                        ok
                end,
            Reply = encode_reply(Cid, ~"session.connected", #{player_id => PlayerId}),
            {reply, {text, Reply}, State#{session => SessionPid, player_id => PlayerId}};
        {error, Reason} ->
            Reply = encode_reply(Cid, ~"error", #{reason => Reason}),
            {reply, {text, Reply}, State}
    end;
handle_message(#{~"type" := ~"session.heartbeat"} = Msg, State) ->
    Cid = maps:get(~"cid", Msg, undefined),
    Reply = encode_reply(Cid, ~"session.heartbeat", #{ts => erlang:system_time(millisecond)}),
    {reply, {text, Reply}, State};
handle_message(
    #{~"type" := ~"match.input", ~"payload" := Payload}, #{session := SessionPid} = State
) when
    SessionPid =/= undefined
->
    try asobi_player_session:get_state(SessionPid) of
        #{player_id := PlayerId} = SState ->
            InputData =
                case maps:get(~"data", Payload, undefined) of
                    undefined when is_map(Payload) -> Payload;
                    Bin when is_binary(Bin) ->
                        case json:decode(Bin) of
                            M when is_map(M) -> M;
                            _ -> #{}
                        end;
                    Other when is_map(Other) -> Other;
                    _ ->
                        #{}
                end,
            case maps:get(match_pid, SState, undefined) of
                undefined ->
                    case maps:get(zone_pid, SState, undefined) of
                        undefined ->
                            {ok, State};
                        ZonePid ->
                            asobi_zone:player_input(ZonePid, PlayerId, InputData),
                            {ok, State}
                    end;
                MatchPid ->
                    asobi_match_server:handle_input(MatchPid, PlayerId, InputData),
                    {ok, State}
            end
    catch
        exit:{noproc, _} ->
            {ok, State#{session => undefined}}
    end;
handle_message(
    #{~"type" := ~"chat.send", ~"payload" := Payload}, #{player_id := PlayerId} = State
) when
    is_binary(PlayerId)
->
    #{~"channel_id" := ChannelId, ~"content" := Content} = Payload,
    case is_binary(Content) andalso byte_size(Content) =< 2000 of
        true ->
            asobi_chat_channel:send_message(ChannelId, PlayerId, Content),
            {ok, State};
        false ->
            {ok, State}
    end;
handle_message(
    #{~"type" := ~"dm.send", ~"payload" := Payload} = Msg, #{player_id := PlayerId} = State
) when is_binary(PlayerId) ->
    Cid = maps:get(~"cid", Msg, undefined),
    #{~"recipient_id" := RecipientId, ~"content" := Content} = Payload,
    case asobi_dm:send(PlayerId, RecipientId, Content) of
        ok ->
            Reply = encode_reply(Cid, ~"dm.sent", #{
                channel_id => asobi_dm:channel_id(PlayerId, RecipientId)
            }),
            {reply, {text, Reply}, State};
        {error, blocked} ->
            Reply = encode_reply(Cid, ~"error", #{reason => ~"blocked"}),
            {reply, {text, Reply}, State}
    end;
handle_message(
    #{~"type" := ~"chat.join", ~"payload" := #{~"channel_id" := ChannelId}} = Msg, State
) ->
    Cid = maps:get(~"cid", Msg, undefined),
    asobi_chat_channel:join(ChannelId, self()),
    Reply = encode_reply(Cid, ~"chat.joined", #{channel_id => ChannelId}),
    {reply, {text, Reply}, State};
handle_message(
    #{~"type" := ~"chat.leave", ~"payload" := #{~"channel_id" := ChannelId}} = Msg, State
) ->
    Cid = maps:get(~"cid", Msg, undefined),
    asobi_chat_channel:leave(ChannelId, self()),
    Reply = encode_reply(Cid, ~"chat.left", #{channel_id => ChannelId}),
    {reply, {text, Reply}, State};
handle_message(
    #{~"type" := ~"matchmaker.add", ~"payload" := Payload} = Msg,
    #{player_id := PlayerId} = State
) ->
    Cid = maps:get(~"cid", Msg, undefined),
    {ok, TicketId} = asobi_matchmaker:add(PlayerId, #{
        mode => maps:get(~"mode", Payload, ~"default"),
        properties => maps:get(~"properties", Payload, #{}),
        party => maps:get(~"party", Payload, [PlayerId])
    }),
    Reply = encode_reply(Cid, ~"matchmaker.queued", #{ticket_id => TicketId, status => ~"pending"}),
    {reply, {text, Reply}, State};
handle_message(
    #{~"type" := ~"matchmaker.remove", ~"payload" := #{~"ticket_id" := TicketId}} = Msg,
    #{player_id := PlayerId} = State
) ->
    Cid = maps:get(~"cid", Msg, undefined),
    asobi_matchmaker:remove(PlayerId, TicketId),
    Reply = encode_reply(Cid, ~"matchmaker.removed", #{success => true}),
    {reply, {text, Reply}, State};
handle_message(
    #{~"type" := ~"presence.update", ~"payload" := Payload} = Msg,
    #{session := SessionPid} = State
) when SessionPid =/= undefined ->
    Cid = maps:get(~"cid", Msg, undefined),
    Status = maps:get(~"status", Payload, ~"online"),
    try
        asobi_player_session:update_presence(SessionPid, #{status => Status})
    catch
        exit:{noproc, _} -> ok
    end,
    Reply = encode_reply(Cid, ~"presence.updated", #{status => Status}),
    {reply, {text, Reply}, State};
handle_message(
    #{~"type" := ~"match.join", ~"payload" := #{~"match_id" := MatchId}} = Msg,
    #{player_id := PlayerId} = State
) ->
    Cid = maps:get(~"cid", Msg, undefined),
    case asobi_match_server:whereis(MatchId) of
        error ->
            Reply = encode_reply(Cid, ~"error", #{reason => ~"match_not_found"}),
            {reply, {text, Reply}, State};
        {ok, MatchPid} ->
            case asobi_match_server:join(MatchPid, PlayerId) of
                ok ->
                    Info = asobi_match_server:get_info(MatchPid),
                    Reply = encode_reply(Cid, ~"match.joined", Info),
                    {reply, {text, Reply}, State};
                {error, Reason} ->
                    Reply = encode_reply(Cid, ~"error", #{reason => Reason}),
                    {reply, {text, Reply}, State}
            end
    end;
handle_message(
    #{~"type" := ~"match.leave"} = Msg,
    #{player_id := PlayerId, session := SessionPid} = State
) when SessionPid =/= undefined ->
    Cid = maps:get(~"cid", Msg, undefined),
    case maps:get(match_pid, asobi_player_session:get_state(SessionPid), undefined) of
        undefined ->
            Reply = encode_reply(Cid, ~"match.left", #{success => true}),
            {reply, {text, Reply}, State};
        MatchPid ->
            asobi_match_server:leave(MatchPid, PlayerId),
            Reply = encode_reply(Cid, ~"match.left", #{success => true}),
            {reply, {text, Reply}, State}
    end;
handle_message(
    #{~"type" := ~"vote.cast", ~"payload" := Payload} = Msg,
    #{session := SessionPid} = State
) when SessionPid =/= undefined ->
    Cid = maps:get(~"cid", Msg, undefined),
    try asobi_player_session:get_state(SessionPid) of
        #{player_id := PlayerId} = SState ->
            case maps:get(match_pid, SState, undefined) of
                undefined ->
                    Reply = encode_reply(Cid, ~"error", #{reason => ~"not_in_match"}),
                    {reply, {text, Reply}, State};
                MatchPid ->
                    VoteId = maps:get(~"vote_id", Payload),
                    OptionId = maps:get(~"option_id", Payload),
                    case asobi_match_server:cast_vote(MatchPid, PlayerId, VoteId, OptionId) of
                        ok ->
                            Reply = encode_reply(Cid, ~"vote.cast_ok", #{success => true}),
                            {reply, {text, Reply}, State};
                        {error, Reason} ->
                            Reply = encode_reply(Cid, ~"error", #{reason => Reason}),
                            {reply, {text, Reply}, State}
                    end
            end
    catch
        exit:{noproc, _} ->
            {ok, State#{session => undefined}}
    end;
handle_message(
    #{~"type" := ~"vote.veto", ~"payload" := Payload} = Msg,
    #{session := SessionPid} = State
) when SessionPid =/= undefined ->
    Cid = maps:get(~"cid", Msg, undefined),
    try asobi_player_session:get_state(SessionPid) of
        #{player_id := PlayerId} = SState ->
            case maps:get(match_pid, SState, undefined) of
                undefined ->
                    Reply = encode_reply(Cid, ~"error", #{reason => ~"not_in_match"}),
                    {reply, {text, Reply}, State};
                MatchPid ->
                    VoteId = maps:get(~"vote_id", Payload),
                    case asobi_match_server:use_veto(MatchPid, PlayerId, VoteId) of
                        ok ->
                            Reply = encode_reply(Cid, ~"vote.veto_ok", #{success => true}),
                            {reply, {text, Reply}, State};
                        {error, Reason} ->
                            Reply = encode_reply(Cid, ~"error", #{reason => Reason}),
                            {reply, {text, Reply}, State}
                    end
            end
    catch
        exit:{noproc, _} ->
            {ok, State#{session => undefined}}
    end;
handle_message(
    #{~"type" := ~"world.list", ~"payload" := Payload} = Msg,
    #{player_id := _PlayerId} = State
) ->
    Cid = maps:get(~"cid", Msg, undefined),
    Filters = #{
        mode => maps:get(~"mode", Payload, undefined),
        has_capacity => maps:get(~"has_capacity", Payload, false)
    },
    Filters1 = maps:filter(fun(_, V) -> V =/= undefined end, Filters),
    Worlds = asobi_world_lobby:list_worlds(Filters1),
    Reply = encode_reply(Cid, ~"world.list", #{worlds => Worlds}),
    {reply, {text, Reply}, State};
handle_message(
    #{~"type" := ~"world.create", ~"payload" := #{~"mode" := Mode}} = Msg,
    #{player_id := PlayerId} = State
) ->
    Cid = maps:get(~"cid", Msg, undefined),
    case asobi_world_lobby:create_world(Mode) of
        {ok, WorldPid, Info} ->
            _ = asobi_world_server:join(WorldPid, PlayerId),
            Reply = encode_reply(Cid, ~"world.joined", Info),
            {reply, {text, Reply}, State};
        {error, Reason} ->
            Reply = encode_reply(Cid, ~"error", #{reason => Reason}),
            {reply, {text, Reply}, State}
    end;
handle_message(
    #{~"type" := ~"world.find_or_create", ~"payload" := #{~"mode" := Mode}} = Msg,
    #{player_id := PlayerId} = State
) ->
    Cid = maps:get(~"cid", Msg, undefined),
    case asobi_world_lobby:find_or_create(Mode) of
        {ok, WorldPid, Info} ->
            _ = asobi_world_server:join(WorldPid, PlayerId),
            Reply = encode_reply(Cid, ~"world.joined", Info),
            {reply, {text, Reply}, State};
        {error, Reason} ->
            Reply = encode_reply(Cid, ~"error", #{reason => Reason}),
            {reply, {text, Reply}, State}
    end;
handle_message(
    #{~"type" := ~"world.join", ~"payload" := #{~"world_id" := WorldId}} = Msg,
    #{player_id := PlayerId} = State
) ->
    Cid = maps:get(~"cid", Msg, undefined),
    case asobi_world_server:whereis(WorldId) of
        error ->
            Reply = encode_reply(Cid, ~"error", #{reason => ~"world_not_found"}),
            {reply, {text, Reply}, State};
        {ok, WorldPid} ->
            case asobi_world_server:join(WorldPid, PlayerId) of
                ok ->
                    Info = asobi_world_server:get_info(WorldPid),
                    Reply = encode_reply(Cid, ~"world.joined", Info),
                    {reply, {text, Reply}, State};
                {error, Reason} ->
                    Reply = encode_reply(Cid, ~"error", #{reason => Reason}),
                    {reply, {text, Reply}, State}
            end
    end;
handle_message(
    #{~"type" := ~"world.leave"} = Msg,
    #{player_id := PlayerId, session := SessionPid} = State
) when SessionPid =/= undefined ->
    Cid = maps:get(~"cid", Msg, undefined),
    case maps:get(world_pid, asobi_player_session:get_state(SessionPid), undefined) of
        undefined ->
            Reply = encode_reply(Cid, ~"world.left", #{success => true}),
            {reply, {text, Reply}, State};
        WorldPid ->
            asobi_world_server:leave(WorldPid, PlayerId),
            Reply = encode_reply(Cid, ~"world.left", #{success => true}),
            {reply, {text, Reply}, State}
    end;
handle_message(
    #{~"type" := ~"world.input", ~"payload" := Payload},
    #{session := SessionPid} = State
) when SessionPid =/= undefined ->
    try asobi_player_session:get_state(SessionPid) of
        #{player_id := PlayerId} = SState ->
            case maps:get(zone_pid, SState, undefined) of
                undefined ->
                    {ok, State};
                ZonePid ->
                    InputData =
                        case maps:get(~"data", Payload, undefined) of
                            undefined when is_map(Payload) -> Payload;
                            Other when is_map(Other) -> Other;
                            _ -> #{}
                        end,
                    asobi_zone:player_input(ZonePid, PlayerId, InputData),
                    {ok, State}
            end
    catch
        exit:{noproc, _} ->
            {ok, State#{session => undefined}}
    end;
handle_message(#{~"type" := Type} = Msg, State) ->
    Cid = maps:get(~"cid", Msg, undefined),
    Reply = encode_reply(Cid, ~"error", #{reason => ~"unknown_type", type => Type}),
    {reply, {text, Reply}, State};
handle_message(_Msg, State) ->
    {ok, State}.

%% --- Safe Message Dispatch ---

safe_handle_message(Msg, State) ->
    try
        handle_message(Msg, State)
    catch
        error:{badmatch, _}:_Stack ->
            reply_error(Msg, ~"invalid_payload", State);
        error:{badkey, _}:_Stack ->
            reply_error(Msg, ~"missing_field", State);
        error:function_clause:_Stack ->
            reply_error(Msg, ~"invalid_payload", State);
        error:{case_clause, _}:_Stack ->
            reply_error(Msg, ~"invalid_payload", State);
        Class:Reason:Stack ->
            logger:warning(#{
                msg => ~"ws_handler_crash",
                class => Class,
                reason => Reason,
                stacktrace => Stack
            }),
            reply_error(Msg, ~"internal_error", State)
    end.

reply_error(Msg, Reason, State) ->
    Cid = maps:get(~"cid", Msg, undefined),
    Reply = encode_reply(Cid, ~"error", #{reason => Reason}),
    {reply, {text, Reply}, State}.

%% --- Internal ---

authenticate(#{~"token" := Token}) ->
    case nova_auth_session:get_user_by_session_token(asobi_auth, Token) of
        {ok, Player} ->
            {ok, maps:get(id, Player)};
        {error, _} ->
            {error, ~"invalid_token"}
    end.

check_ws_rate_limit(#{ws_msg_count := Count, ws_msg_window_start := WindowStart} = State) ->
    Now = erlang:system_time(millisecond),
    case Now - WindowStart >= ?WS_MSG_WINDOW_MS of
        true ->
            {ok, State#{ws_msg_count => 1, ws_msg_window_start => Now}};
        false when Count >= ?WS_MSG_LIMIT ->
            {rate_limited, State};
        false ->
            {ok, State#{ws_msg_count => Count + 1}}
    end.

encode_reply(Cid, Type, Payload) ->
    Msg0 = #{~"type" => Type, ~"payload" => Payload},
    Msg =
        case Cid of
            undefined -> Msg0;
            _ -> Msg0#{~"cid" => Cid}
        end,
    json:encode(Msg).
