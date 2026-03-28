-module(asobi_ws_handler).
-behaviour(nova_websocket).

-export([init/1, websocket_init/1, websocket_handle/2, websocket_info/2, terminate/3]).

-spec init(map()) -> {ok, map()}.
init(State) ->
    {ok, State#{session => undefined}}.

-spec websocket_init(map()) -> {ok, map()}.
websocket_init(State) ->
    {ok, State}.

-spec websocket_handle({text | binary, binary()}, map()) ->
    {ok, map()} | {reply, {text, binary()}, map()}.
websocket_handle({text, Raw}, State) ->
    try json:decode(Raw) of
        Msg ->
            handle_message(Msg, State)
    catch
        _:_ ->
            Reply = encode_reply(undefined, ~"error", #{reason => ~"invalid_json"}),
            {reply, {text, Reply}, State}
    end;
websocket_handle(_Frame, State) ->
    {ok, State}.

-spec websocket_info(term(), map()) -> {ok, map()} | {reply, {text, binary()}, map()}.
websocket_info({asobi_message, {match_state, MatchState}}, State) ->
    Reply = encode_reply(undefined, ~"match.state", MatchState),
    {reply, {text, Reply}, State};
websocket_info({asobi_message, {match_event, Event, Payload}}, State) ->
    Type = iolist_to_binary([~"match.", atom_to_binary(Event)]),
    Reply = encode_reply(undefined, Type, Payload),
    {reply, {text, Reply}, State};
websocket_info({chat_message, ChannelId, Msg}, State) ->
    Reply = encode_reply(undefined, ~"chat.message", Msg#{channel_id => ChannelId}),
    {reply, {text, Reply}, State};
websocket_info({asobi_message, {notification, Notif}}, State) ->
    Reply = encode_reply(undefined, ~"notification.new", Notif),
    {reply, {text, Reply}, State};
websocket_info(_Info, State) ->
    {ok, State}.

-spec terminate(term(), term(), map()) -> ok.
terminate(_Reason, _Req, #{session := undefined}) ->
    ok;
terminate(_Reason, _Req, #{session := SessionPid}) ->
    asobi_player_session:stop(SessionPid),
    ok.

%% --- Message Routing ---

handle_message(#{~"type" := ~"session.connect", ~"payload" := Payload} = Msg, State) ->
    Cid = maps:get(~"cid", Msg, undefined),
    case authenticate(Payload) of
        {ok, PlayerId} ->
            {ok, SessionPid} = asobi_player_session_sup:start_session(PlayerId, self()),
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
    #{player_id := PlayerId} = asobi_player_session:get_state(SessionPid),
    case maps:get(match_pid, asobi_player_session:get_state(SessionPid), undefined) of
        undefined ->
            {ok, State};
        MatchPid ->
            asobi_match_server:handle_input(MatchPid, PlayerId, Payload),
            {ok, State}
    end;
handle_message(#{~"type" := ~"chat.send", ~"payload" := Payload}, #{player_id := PlayerId} = State) ->
    #{~"channel_id" := ChannelId, ~"content" := Content} = Payload,
    asobi_chat_channel:send_message(ChannelId, PlayerId, Content),
    {ok, State};
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
    asobi_player_session:update_presence(SessionPid, #{status => Status}),
    Reply = encode_reply(Cid, ~"presence.updated", #{status => Status}),
    {reply, {text, Reply}, State};
handle_message(
    #{~"type" := ~"match.join", ~"payload" := #{~"match_id" := MatchId}} = Msg,
    #{player_id := PlayerId} = State
) ->
    Cid = maps:get(~"cid", Msg, undefined),
    case global:whereis_name({asobi_match_server, MatchId}) of
        undefined ->
            Reply = encode_reply(Cid, ~"error", #{reason => ~"match_not_found"}),
            {reply, {text, Reply}, State};
        MatchPid ->
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
handle_message(#{~"type" := Type} = Msg, State) ->
    Cid = maps:get(~"cid", Msg, undefined),
    Reply = encode_reply(Cid, ~"error", #{reason => ~"unknown_type", type => Type}),
    {reply, {text, Reply}, State};
handle_message(_Msg, State) ->
    {ok, State}.

%% --- Internal ---

authenticate(#{~"token" := Token}) ->
    case nova_auth_session:get_user_by_session_token(asobi_auth, Token) of
        {ok, Player} ->
            {ok, maps:get(id, Player)};
        {error, _} ->
            {error, ~"invalid_token"}
    end.

encode_reply(Cid, Type, Payload) ->
    Msg0 = #{~"type" => Type, ~"payload" => Payload},
    Msg =
        case Cid of
            undefined -> Msg0;
            _ -> Msg0#{~"cid" => Cid}
        end,
    json:encode(Msg).
