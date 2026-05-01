-module(asobi_ws_handler).
-behaviour(nova_websocket).

-export([init/1, websocket_init/1, websocket_handle/2, websocket_info/2, terminate/3]).

-define(WS_MSG_LIMIT, 60).
-define(WS_MSG_WINDOW_MS, 1000).
-define(WS_MAX_PAYLOAD_BYTES, 65536).
%% F-16: per-connection cap on simultaneously joined chat channels.
-define(MAX_JOINED_CHANNELS_PER_CONN, 32).
-define(MAX_CHANNEL_ID_BYTES, 256).

%% Default time a freshly-connected WS has to send `session.connect`
%% before we close it. Mobile TLS handshake on poor networks can be
%% several seconds; 10s gives margin without leaving idle sockets
%% holding cowboy acceptors. Override via `asobi.ws_idle_auth_timeout_ms`.
-define(DEFAULT_IDLE_AUTH_TIMEOUT_MS, 10000).

-spec init(map()) -> {ok, map()}.
init(#{req := Req} = State) ->
    %% Capture peer IP before the upgrade so websocket_init can run the
    %% per-IP connect-rate check without re-parsing the req.
    PeerIp = asobi_peer:client_ip(Req),
    {ok, State#{session => undefined, peer_ip => PeerIp}};
init(State) ->
    {ok, State#{session => undefined, peer_ip => ~"unknown"}}.

-spec websocket_init(map()) -> {ok, map()} | {reply, {close, 1008, binary()}, map()}.
websocket_init(#{peer_ip := PeerIp} = State) ->
    case seki:check(asobi_ws_connect_limiter, PeerIp) of
        {allow, _} ->
            start_authenticated_session(State);
        {deny, _} ->
            asobi_telemetry:ws_connect_rate_limited(PeerIp),
            {reply, {close, 1008, ~"rate_limited"}, State}
    end;
websocket_init(State) ->
    %% No peer_ip — init/1 ran in a path without a req map. Skip the
    %% connect-rate gate but still install the idle-auth timer.
    start_authenticated_session(State).

start_authenticated_session(State) ->
    asobi_telemetry:ws_connected(),
    Now = erlang:system_time(millisecond),
    TimeoutMs = idle_auth_timeout_ms(),
    TimerRef = erlang:send_after(TimeoutMs, self(), idle_auth_timeout),
    {ok, State#{
        connected_at => Now,
        ws_msg_count => 0,
        ws_msg_window_start => Now,
        idle_auth_timer => TimerRef
    }}.

idle_auth_timeout_ms() ->
    case application:get_env(asobi, ws_idle_auth_timeout_ms) of
        {ok, Ms} when is_integer(Ms), Ms > 0 -> Ms;
        _ -> ?DEFAULT_IDLE_AUTH_TIMEOUT_MS
    end.

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
    {ok, map()}
    | {reply, {text, binary()}, map()}
    | {reply, {close, non_neg_integer(), binary()}, map()}
    | {stop, map()}.
websocket_info({asobi_message, {match_state, MatchState}}, State) ->
    Reply = encode_reply(undefined, ~"match.state", MatchState),
    {reply, {text, Reply}, State};
websocket_info({asobi_message, {match_event, Event, Payload}}, State) when is_atom(Event) ->
    Type = iolist_to_binary([~"match.", atom_to_binary(Event)]),
    Reply = encode_reply(undefined, Type, Payload),
    {reply, {text, Reply}, State};
websocket_info({asobi_message, {zone_delta_raw, PreEncoded}}, State) when is_binary(PreEncoded) ->
    {reply, {text, PreEncoded}, State};
websocket_info({asobi_message, {zone_delta, TickN, Deltas}}, State) ->
    Reply = encode_reply(undefined, ~"world.tick", #{tick => TickN, updates => Deltas}),
    {reply, {text, Reply}, State};
websocket_info({asobi_message, {terrain_chunk, {CX, CY}, Data}}, State) when is_binary(Data) ->
    Reply = encode_reply(undefined, ~"world.terrain", #{
        coords => [CX, CY],
        data => base64:encode(Data)
    }),
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
websocket_info(idle_auth_timeout, #{session := undefined} = State) ->
    %% Client opened the WS and never sent session.connect within the
    %% configured window. Close so the cowboy acceptor isn't held by an
    %% idle peer that may never authenticate.
    asobi_telemetry:ws_idle_auth_timeout(),
    {reply, {close, 1008, ~"idle_auth_timeout"}, State};
websocket_info(idle_auth_timeout, State) ->
    %% Race: the timer fired but session.connect already succeeded.
    %% Ignore.
    {ok, State};
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
            %% F-28: drive the world reconnect from the supervised player
            %% session process rather than an unsupervised spawn — a slow
            %% or crashing reconnect cannot leak processes anymore.
            case ets:lookup(asobi_player_worlds, PlayerId) of
                [{PlayerId, WorldPid}] when is_pid(WorldPid) ->
                    gen_server:cast(SessionPid, {reconnect_world, WorldPid});
                _ ->
                    ok
            end,
            Reply = encode_reply(Cid, ~"session.connected", #{player_id => PlayerId}),
            State1 = cancel_idle_auth_timer(State),
            {reply, {text, Reply}, State1#{session => SessionPid, player_id => PlayerId}};
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
        {error, Reason} ->
            Reply = encode_reply(Cid, ~"error", #{reason => to_reason_binary(Reason)}),
            {reply, {text, Reply}, State}
    end;
handle_message(
    #{~"type" := ~"chat.join", ~"payload" := #{~"channel_id" := ChannelId}} = Msg, State
) when is_binary(ChannelId) ->
    Cid = maps:get(~"cid", Msg, undefined),
    %% F-16: bound channel id length, namespace it, and cap how many channels
    %% one connection may join. Prevents one socket from spawning unbounded
    %% chat channel processes on the host.
    case validate_channel_id(ChannelId) of
        false ->
            Reply = encode_reply(Cid, ~"error", #{reason => ~"invalid_channel_id"}),
            {reply, {text, Reply}, State};
        true ->
            Joined = maps:get(joined_channels, State, #{}),
            case map_size(Joined) >= ?MAX_JOINED_CHANNELS_PER_CONN of
                true ->
                    Reply = encode_reply(Cid, ~"error", #{reason => ~"too_many_channels"}),
                    {reply, {text, Reply}, State};
                false ->
                    asobi_chat_channel:join(ChannelId, self()),
                    Reply = encode_reply(Cid, ~"chat.joined", #{channel_id => ChannelId}),
                    {reply, {text, Reply}, State#{joined_channels => Joined#{ChannelId => true}}}
            end
    end;
handle_message(
    #{~"type" := ~"chat.leave", ~"payload" := #{~"channel_id" := ChannelId}} = Msg, State
) when is_binary(ChannelId) ->
    Cid = maps:get(~"cid", Msg, undefined),
    asobi_chat_channel:leave(ChannelId, self()),
    Joined = maps:get(joined_channels, State, #{}),
    Reply = encode_reply(Cid, ~"chat.left", #{channel_id => ChannelId}),
    {reply, {text, Reply}, State#{joined_channels => maps:remove(ChannelId, Joined)}};
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
    Reply =
        case asobi_matchmaker:remove(PlayerId, TicketId) of
            ok ->
                encode_reply(Cid, ~"matchmaker.removed", #{success => true});
            {error, Reason} ->
                encode_reply(Cid, ~"error", #{
                    type => ~"matchmaker.remove", reason => atom_to_binary(Reason, utf8)
                })
        end,
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
) when is_map(Payload) ->
    Cid = maps:get(~"cid", Msg, undefined),
    %% F-29: validate filter values rather than silently degrading on
    %% bad types.
    case build_world_filters(Payload) of
        {ok, Filters} ->
            Worlds = asobi_world_lobby:list_worlds(Filters),
            Reply = encode_reply(Cid, ~"world.list", #{worlds => Worlds}),
            {reply, {text, Reply}, State};
        {error, Reason} ->
            Reply = encode_reply(Cid, ~"error", #{reason => Reason}),
            {reply, {text, Reply}, State}
    end;
handle_message(
    #{~"type" := ~"world.create", ~"payload" := #{~"mode" := Mode}} = Msg,
    #{player_id := PlayerId} = State
) ->
    Cid = maps:get(~"cid", Msg, undefined),
    case asobi_world_lobby:create_world(Mode, PlayerId) of
        {ok, WorldPid, _Info} ->
            join_and_reply(Cid, WorldPid, PlayerId, State);
        {error, Reason} ->
            Reply = encode_reply(Cid, ~"error", #{reason => Reason}),
            {reply, {text, Reply}, State}
    end;
handle_message(
    #{~"type" := ~"world.find_or_create", ~"payload" := #{~"mode" := Mode}} = Msg,
    #{player_id := PlayerId} = State
) ->
    Cid = maps:get(~"cid", Msg, undefined),
    case asobi_world_lobby:find_or_create(Mode, PlayerId) of
        {ok, WorldPid, _Info} ->
            join_and_reply(Cid, WorldPid, PlayerId, State);
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
            join_and_reply(Cid, WorldPid, PlayerId, State)
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
handle_message(#{~"type" := _Type} = Msg, State) ->
    %% F-26: do NOT echo the client-supplied `type` back into the error
    %% reply or logs — an attacker could craft strings that pollute the
    %% structured-log pipeline. The client knows what it sent, so the
    %% reason alone is enough.
    Cid = maps:get(~"cid", Msg, undefined),
    Reply = encode_reply(Cid, ~"error", #{reason => ~"unknown_type"}),
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

join_and_reply(Cid, WorldPid, PlayerId, #{session := SessionPid} = State) when
    SessionPid =/= undefined
->
    case current_player_world(PlayerId) of
        {ok, ExistingPid} when ExistingPid =/= WorldPid ->
            %% Player is already in a different (live) world. Force them to
            %% world.leave first; otherwise they'd appear in two worlds at once.
            Reply = encode_reply(Cid, ~"error", #{reason => ~"already_in_world"}),
            {reply, {text, Reply}, State};
        _ ->
            %% join/3 (vs join/2) sets zone_pid synchronously in the player_session
            %% before returning, so a world.input arriving right after world.joined
            %% lands on the right zone instead of being silently dropped.
            case asobi_world_server:join(WorldPid, PlayerId, SessionPid) of
                ok ->
                    Info = asobi_world_server:get_info(WorldPid),
                    Reply = encode_reply(Cid, ~"world.joined", Info),
                    {reply, {text, Reply}, State};
                {error, Reason} ->
                    Reply = encode_reply(Cid, ~"error", #{reason => Reason}),
                    {reply, {text, Reply}, State}
            end
    end.

current_player_world(PlayerId) ->
    case ets:info(asobi_player_worlds) of
        undefined ->
            none;
        _ ->
            case ets:lookup(asobi_player_worlds, PlayerId) of
                [{PlayerId, Pid}] when is_pid(Pid) ->
                    case is_process_alive(Pid) of
                        true -> {ok, Pid};
                        false -> none
                    end;
                _ ->
                    none
            end
    end.

%% --- Internal ---

cancel_idle_auth_timer(#{idle_auth_timer := Ref} = State) when is_reference(Ref) ->
    _ = erlang:cancel_timer(Ref, [{async, true}, {info, false}]),
    maps:remove(idle_auth_timer, State);
cancel_idle_auth_timer(State) ->
    State.

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

to_reason_binary(R) when is_atom(R) -> atom_to_binary(R, utf8).

%% F-16: chat.join must require a small, namespaced channel id so an
%% attacker can't spawn unbounded chat channel gen_servers via WS.
%% Allowed prefixes mirror the channel id schemes documented in
%% asobi_chat_controller's classify/1 (`dm:`, `world:`, `zone:`,
%% `prox:`, plus a `room:` namespace for app-defined group chats).
validate_channel_id(ChannelId) when is_binary(ChannelId) ->
    byte_size(ChannelId) > 0 andalso
        byte_size(ChannelId) =< ?MAX_CHANNEL_ID_BYTES andalso
        valid_channel_prefix(ChannelId).

valid_channel_prefix(<<"dm:", _/binary>>) -> true;
valid_channel_prefix(<<"world:", _/binary>>) -> true;
valid_channel_prefix(<<"zone:", _/binary>>) -> true;
valid_channel_prefix(<<"prox:", _/binary>>) -> true;
valid_channel_prefix(<<"room:", _/binary>>) -> true;
valid_channel_prefix(_) -> false.

%% F-29: world.list filter values must be the right type or we reject the
%% request rather than silently returning unfiltered results.
build_world_filters(Payload) ->
    Acc1 =
        case maps:find(~"mode", Payload) of
            error ->
                {ok, #{}};
            {ok, undefined} ->
                {ok, #{}};
            {ok, Mode} when is_binary(Mode), byte_size(Mode) =< 64 ->
                {ok, #{mode => Mode}};
            _ ->
                {error, ~"invalid_mode_filter"}
        end,
    case Acc1 of
        {error, _} = E1 ->
            E1;
        {ok, A1} ->
            case maps:find(~"has_capacity", Payload) of
                error -> {ok, A1};
                {ok, true} -> {ok, A1#{has_capacity => true}};
                {ok, false} -> {ok, A1};
                _ -> {error, ~"invalid_has_capacity_filter"}
            end
    end.
