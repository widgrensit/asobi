-module(asobi_ws_handler).
-behaviour(nova_websocket).

-export([init/1, websocket_init/1, websocket_handle/2, websocket_info/2, terminate/3]).
%% Exported for tests (pure allowlist predicate), mirroring deployable/1.
-export([origin_allowed/1]).
%% Exported so asobi_protocol_coverage_tests can assert every emitted
%% match./world. event stays inside the reserved namespace (#303), and so
%% asobi_lua_api can reject a bad game.broadcast name against these same
%% rules at the script's call site instead of re-stating them.
%% `is_event_name_char/1` is the charset predicate itself, reused by
%% `asobi_extensions:emit/4` to validate a `module.event` name's bytes against
%% the same allowlist rather than forking a second charset notion.
-export([reserved_event_names/0, event_name_binary/1, is_event_name_char/1]).

-include_lib("kernel/include/logger.hrl").

-define(WS_MSG_LIMIT, 60).
-define(WS_MSG_WINDOW_MS, 1000).
-define(WS_MAX_PAYLOAD_BYTES, 65536).
%% F-16: per-connection cap on simultaneously joined chat channels.
-define(MAX_JOINED_CHANNELS_PER_CONN, 32).
%% #236: at most one `not_in_match` hint per connection per this window.
-define(NOT_IN_MATCH_HINT_WINDOW_MS, 5000).

%% Default time a freshly-connected WS has to send `session.connect`
%% before we close it. Mobile TLS handshake on poor networks can be
%% several seconds; 10s gives margin without leaving idle sockets
%% holding cowboy acceptors. Override via `asobi.ws_idle_auth_timeout_ms`.
-define(DEFAULT_IDLE_AUTH_TIMEOUT_MS, 10000).

%% Extension-produced frames name their producer in the payload's `module`
%% key, not in the wire type, so an extension can emit them without a new
%% frame type per extension. A producer that sends the legacy two-element
%% shape (`{game_message, Payload}`, `{script_error, Payload}`) predates
%% that and can only be asobi_lua.
-define(DEFAULT_EXTENSION, lua).

%% S6: the wire types are `module.message`/`module.error`. `game.message`/
%% `game.error` are the pre-S6 names and are emitted alongside them so no
%% shipped SDK build breaks; they are removed at the 1.0 wire break.
%%
%% Off drops the legacy pair. `game.message` is asobi_lua's `game.send/2`,
%% which a script may call per player per tick, so the compat frame is the
%% one doubling asobi's hottest extension-produced egress path. An operator
%% whose clients all dispatch `module.*` sets `asobi.ws_legacy_game_frames`
%% to `false` and gets that back without waiting for 1.0.
-define(DEFAULT_LEGACY_GAME_FRAMES, true).

%% #303: script-controlled `game.broadcast` event names share the wire
%% namespace with asobi's own `match.*`/`world.*` events, so they must be
%% bounded and validated before ever reaching event_name_binary/1's caller.
-define(MAX_EVENT_NAME_BYTES, 64).
%% Every bare event-name suffix asobi itself ever emits under `match.`/
%% `world.` (per asobi_protocol_coverage_tests:enumerate_emitted_events/0,
%% restricted to those two namespaces). A script-supplied name equal to one
%% of these would forge a byte-identical frame to a genuine library event
%% (fake entity positions via `world.tick`, a false match-end via
%% `match.finished`, etc), so these stay off-limits to game.broadcast.
-define(RESERVED_EVENT_NAMES, [
    ~"state",
    ~"tick",
    ~"terrain",
    ~"list",
    ~"left",
    ~"joined",
    ~"finished",
    ~"phase_changed",
    ~"matched",
    ~"matchmaker_failed",
    ~"matchmaker_expired",
    ~"vote_start",
    ~"vote_tally",
    ~"vote_result",
    ~"vote_vetoed"
]).

-spec init(map()) -> {ok, map()}.
init(#{req := Req} = State) ->
    %% Capture peer IP and Origin before the upgrade so websocket_init can run
    %% the per-IP connect-rate check and the Origin allowlist without
    %% re-parsing the req (websocket_init runs post-upgrade, no req available).
    PeerIp = asobi_peer:client_ip(Req),
    Origin = cowboy_req:header(~"origin", Req, undefined),
    {ok, State#{session => undefined, peer_ip => PeerIp, origin => Origin}};
init(State) ->
    {ok, State#{session => undefined, peer_ip => ~"unknown", origin => undefined}}.

-spec websocket_init(map()) -> {ok, map()} | {reply, {close, 1008, binary()}, map()}.
websocket_init(#{peer_ip := PeerIp} = State) ->
    %% Per-IP connect limiter FIRST: spending a token IS the flood defence, so
    %% every connect must count against the budget, including one we are about
    %% to reject on Origin. Checking Origin first would let an attacker who
    %% sets any disallowed Origin spawn ws processes without ever touching the
    %% limiter - each connect upgrades, emits telemetry, and closes, unbounded.
    case seki:check(asobi_ws_connect_limiter, PeerIp) of
        {deny, _} ->
            asobi_telemetry:ws_connect_rate_limited(PeerIp),
            {reply, {close, 1008, ~"rate_limited"}, State};
        {allow, _} ->
            case origin_allowed(maps:get(origin, State, undefined)) of
                false ->
                    asobi_telemetry:ws_origin_rejected(),
                    {reply, {close, 1008, ~"origin_rejected"}, State};
                true ->
                    start_authenticated_session(State)
            end
    end;
websocket_init(State) ->
    %% No peer_ip — init/1 ran in a path without a req map. Skip the
    %% connect-rate gate but still install the idle-auth timer.
    start_authenticated_session(State).

%% CSWSH defence-in-depth (#160). Opt-in and default-open, matching ADR 0002:
%% with no `ws_allowed_origins` configured every Origin passes (today's
%% behaviour). When an operator sets an allowlist, only those browser Origins
%% may open the socket. A missing Origin header is a non-browser client
%% (Defold/Unity native etc.) - it cannot be a CSWSH vector, so it always
%% passes regardless of the allowlist.
-spec origin_allowed(binary() | undefined) -> boolean().
origin_allowed(undefined) ->
    true;
origin_allowed(Origin) when is_binary(Origin) ->
    case application:get_env(asobi, ws_allowed_origins) of
        undefined ->
            true;
        {ok, []} ->
            true;
        {ok, Allowed} when is_list(Allowed) ->
            %% Set-but-malformed (e.g. a bare binary instead of a list of
            %% binaries) must fail CLOSED and loud, not silently allow-all -
            %% otherwise a dropped-bracket typo nullifies the control while the
            %% operator believes the socket is locked down.
            case lists:all(fun is_binary/1, Allowed) of
                true -> lists:member(Origin, Allowed);
                false -> misconfigured_origins(Allowed)
            end;
        {ok, Other} ->
            misconfigured_origins(Other)
    end.

-spec misconfigured_origins(term()) -> false.
misconfigured_origins(Value) ->
    logger:error(#{
        msg => ~"ws_allowed_origins must be a list of binaries; failing closed",
        value => Value
    }),
    false.

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
            Reply = encode_error(undefined, ~"payload_too_large"),
            {reply, {text, Reply}, State};
        false ->
            case check_ws_rate_limit(State) of
                {ok, State1} ->
                    try json:decode(Raw) of
                        #{~"type" := Type} = Msg when is_binary(Type) ->
                            asobi_telemetry:ws_message_in(Type),
                            safe_handle_message(Msg, State1);
                        _ ->
                            Reply = encode_error(undefined, ~"invalid_message"),
                            {reply, {text, Reply}, State1}
                    catch
                        _:_ ->
                            Reply = encode_error(undefined, ~"invalid_json"),
                            {reply, {text, Reply}, State1}
                    end;
                {rate_limited, State1} ->
                    Reply = encode_error(undefined, ~"rate_limited"),
                    {reply, {text, Reply}, State1}
            end
    end;
websocket_handle(_Frame, State) ->
    {ok, State}.

-spec websocket_info(term(), map()) ->
    {ok, map()}
    | {reply, {text, binary()}, map()}
    | {reply, [{text, binary()}], map()}
    | {reply, {close, non_neg_integer(), binary()}, map()}
    | {stop, map()}.
websocket_info({asobi_message, {match_state, MatchState}}, State) ->
    Reply = encode_reply(undefined, ~"match.state", MatchState),
    {reply, {text, Reply}, State};
websocket_info({asobi_message, {match_state_raw, PreEncoded}}, State) when is_binary(PreEncoded) ->
    {reply, {text, PreEncoded}, State};
websocket_info({asobi_message, {match_event, Event, Payload}}, State) when
    is_atom(Event); is_binary(Event)
->
    %% #297: asobi_match_server:broadcast_event/3 accepts a binary event
    %% name (Lua's game.broadcast never turns client/script-influenced
    %% names into atoms — atom_to_binary here, never binary_to_atom).
    %% #303: a script-controlled binary name must be validated first — an
    %% invalid/non-ASCII name would crash json:encode/1 for every
    %% subscriber, and a reserved name would forge a genuine match.* frame.
    case event_name_binary(Event) of
        {ok, Name} ->
            Type = iolist_to_binary([~"match.", Name]),
            Reply = encode_reply(undefined, Type, Payload),
            {reply, {text, Reply}, State};
        {error, Reason} ->
            logger:warning(#{
                msg => ~"game_broadcast_rejected",
                namespace => ~"match",
                reason => Reason
            }),
            {ok, State}
    end;
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
websocket_info({asobi_message, {world_event, Event, Payload}}, State) when
    is_atom(Event); is_binary(Event)
->
    %% #297: a Lua world script's game.broadcast(event, payload) sends Event
    %% as a binary via asobi_lua_api:fun_broadcast/1 ->
    %% asobi_match_server:broadcast_event/3 -> asobi_world_server -> here.
    %% The old is_atom-only guard silently dropped every such frame. Convert
    %% atom->binary here at the socket only; never binary_to_atom on a
    %% client/Lua-influenced name (atom-table exhaustion risk).
    %% #303: a script-controlled binary name must be validated first — an
    %% invalid/non-ASCII name would crash json:encode/1 for every
    %% subscriber, and a reserved name would forge a genuine world.* frame.
    case event_name_binary(Event) of
        {ok, Name} ->
            Type = iolist_to_binary([~"world.", Name]),
            Reply = encode_reply(undefined, Type, Payload),
            {reply, {text, Reply}, State};
        {error, Reason} ->
            logger:warning(#{
                msg => ~"game_broadcast_rejected",
                namespace => ~"world",
                reason => Reason
            }),
            {ok, State}
    end;
websocket_info({chat_message, ChannelId, Msg}, State) when is_map(Msg) ->
    Reply = encode_reply(undefined, ~"chat.message", Msg#{channel_id => ChannelId}),
    {reply, {text, Reply}, State};
websocket_info({asobi_message, {dm_message, Msg}}, State) when is_map(Msg) ->
    Reply = encode_reply(undefined, ~"dm.message", Msg),
    {reply, {text, Reply}, State};
websocket_info({asobi_message, {notification, Notif}}, State) ->
    Reply = encode_reply(undefined, ~"notification.new", Notif),
    {reply, {text, Reply}, State};
websocket_info({asobi_message, {game_message, Payload}}, State) ->
    websocket_info({asobi_message, {game_message, ?DEFAULT_EXTENSION, Payload}}, State);
websocket_info({asobi_message, {game_message, Extension, Payload}}, State) when
    is_atom(Extension)
->
    %% Wrapped, not sent raw: every other wire event's payload is an
    %% object (enforced by asobi_protocol_coverage_tests), but
    %% game.send/2 accepts any Lua value (string, number, table) as
    %% the message, so a bare scalar payload would break that
    %% convention and couldn't carry more fields later without a
    %% breaking change.
    Body = #{~"module" => atom_to_binary(Extension), ~"message" => Payload},
    {reply, extension_frames(~"module.message", ~"game.message", Body), State};
websocket_info({asobi_message, {extension_event, Extension, Event, Data}}, State) when
    is_atom(Extension), is_binary(Event), is_map(Data)
->
    %% A named, routable server->client event an extension pushes from its own
    %% Erlang code via asobi_extensions:emit/4. Distinct from module.message
    %% (unnamed dev messages) and module.error (dev-mode only): the producer is
    %% in `module`, the `<domain>.<name>` event in `event`, and `data` is always
    %% an object. Emitted as a single frame - unlike module.message it has no
    %% pre-S6 legacy alias, so it never routes through extension_frames/3.
    %% emit/4 has already proven Data JSON-encodable, but the encode is still
    %% wrapped like the script_error clause: a bad term reaching here must
    %% degrade to an error frame, never crash this player's connection process
    %% (send/2 fans out to every session pid, so a crash drops them all).
    Payload = #{~"module" => atom_to_binary(Extension), ~"event" => Event, ~"data" => Data},
    Reply =
        try
            encode_reply(undefined, ~"module.event", Payload)
        catch
            _:_ -> encode_error(undefined, ~"internal")
        end,
    {reply, {text, Reply}, State};
websocket_info({asobi_message, {script_error, Payload}}, State) when is_map(Payload) ->
    websocket_info({asobi_message, {script_error, ?DEFAULT_EXTENSION, Payload}}, State);
websocket_info({asobi_message, {script_error, Extension, Payload}}, State) when
    is_atom(Extension), is_map(Payload)
->
    %% Dev-mode extension callback errors (asobi_lua#98). Only ever emitted
    %% when the runtime has dev errors enabled; production runtimes never send
    %% this, so script internals stay server-side. Encoded defensively: a
    %% future producer sending a non-JSON-encodable map must degrade to an
    %% error frame, not crash the connection process.
    Body = Payload#{~"module" => atom_to_binary(Extension)},
    Reply =
        try
            extension_frames(~"module.error", ~"game.error", Body)
        catch
            _:_ -> [{text, encode_error(undefined, ~"internal")}]
        end,
    {reply, Reply, State};
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
websocket_info(Info, State) ->
    %% #308: dropping an unrecognised message with no signal is the exact
    %% failure class #297 was - a producer's frame vanishing between the
    %% game server and the socket, invisible to the game developer. The
    %% drop itself stays (an unknown shape has no wire encoding), but it is
    %% now observable. Rate-limited per tag because a per-tick producer
    %% would otherwise log once per tick per connection.
    log_unhandled_info(Info),
    {ok, State}.

-spec log_unhandled_info(term()) -> ok.
log_unhandled_info(Info) ->
    Tag = unhandled_tag(Info),
    case asobi_script_log_limiter:allow({?MODULE, Tag}) of
        {true, DroppedSinceLastLog} ->
            ?LOG_WARNING(#{
                event => ws_unhandled_info,
                tag => Tag,
                suppressed_since_last => DroppedSinceLastLog
            });
        false ->
            ok
    end.

%% Tag only, never the payload: an unhandled message may carry player data
%% of unbounded size. Non-atom tags collapse to `unknown` so neither the log
%% field nor the limiter's key space can be grown by a message sender.
-spec unhandled_tag(term()) -> atom() | {asobi_message, atom()}.
unhandled_tag({asobi_message, Inner}) -> {asobi_message, plain_tag(Inner)};
unhandled_tag(Info) -> plain_tag(Info).

-spec plain_tag(term()) -> atom().
plain_tag(Tag) when is_atom(Tag) -> Tag;
plain_tag(Tuple) when is_tuple(Tuple), tuple_size(Tuple) > 0, is_atom(element(1, Tuple)) ->
    element(1, Tuple);
plain_tag(_) ->
    unknown.

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
            Reply = encode_error(Cid, Reason),
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
                            not_in_match_hint(State);
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
    #{~"type" := ~"chat.send", ~"payload" := Payload} = Msg, #{player_id := PlayerId} = State
) when
    is_binary(PlayerId)
->
    Cid = maps:get(~"cid", Msg, undefined),
    #{~"channel_id" := ChannelId, ~"content" := Content} = Payload,
    case is_binary(Content) andalso byte_size(Content) =< 2000 of
        false ->
            {ok, State};
        true ->
            case
                validate_channel_id(ChannelId) andalso
                    asobi_chat_acl:authorized(ChannelId, PlayerId)
            of
                true ->
                    asobi_chat_channel:send_message(ChannelId, PlayerId, Content),
                    {ok, State};
                false ->
                    Reply = encode_error(Cid, ~"not_authorized"),
                    {reply, {text, Reply}, State}
            end
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
            Reply = encode_error(Cid, Reason),
            {reply, {text, Reply}, State}
    end;
handle_message(
    #{~"type" := ~"chat.join", ~"payload" := #{~"channel_id" := ChannelId}} = Msg,
    #{player_id := PlayerId} = State
) when is_binary(ChannelId), is_binary(PlayerId) ->
    Cid = maps:get(~"cid", Msg, undefined),
    %% F-16: bound channel id length, namespace it, and cap how many channels
    %% one connection may join. Prevents one socket from spawning unbounded
    %% chat channel processes on the host.
    %% H1 (2026-05-19): every join must pass asobi_chat_acl:authorized/2 so a
    %% third party cannot silently join `dm:<alice>:<bob>` and eavesdrop.
    case validate_channel_id(ChannelId) of
        false ->
            Reply = encode_error(Cid, ~"invalid_channel_id"),
            {reply, {text, Reply}, State};
        true ->
            case asobi_chat_acl:authorized(ChannelId, PlayerId) of
                false ->
                    Reply = encode_error(Cid, ~"not_authorized"),
                    {reply, {text, Reply}, State};
                true ->
                    Joined = maps:get(joined_channels, State, #{}),
                    case map_size(Joined) >= ?MAX_JOINED_CHANNELS_PER_CONN of
                        true ->
                            Reply = encode_error(Cid, ~"too_many_channels"),
                            {reply, {text, Reply}, State};
                        false ->
                            asobi_chat_channel:join(ChannelId, self()),
                            Reply = encode_reply(Cid, ~"chat.joined", #{channel_id => ChannelId}),
                            {reply, {text, Reply}, State#{
                                joined_channels => Joined#{ChannelId => true}
                            }}
                    end
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
    Mode = maps:get(~"mode", Payload, ~"default"),
    Reply =
        case asobi_matchmaker:known_mode(Mode) of
            false ->
                encode_error(Cid, ~"unknown_mode", #{type => ~"matchmaker.add"});
            true ->
                case
                    asobi_matchmaker:add(PlayerId, #{
                        mode => Mode,
                        properties => maps:get(~"properties", Payload, #{})
                    })
                of
                    {ok, TicketId, Meta} ->
                        encode_reply(Cid, ~"matchmaker.queued", Meta#{
                            ticket_id => TicketId, status => ~"pending"
                        });
                    {error, queue_full} ->
                        encode_error(Cid, ~"queue_full", #{type => ~"matchmaker.add"})
                end
        end,
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
                encode_error(Cid, Reason, #{type => ~"matchmaker.remove"})
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
            Reply = encode_error(Cid, ~"match_not_found"),
            {reply, {text, Reply}, State};
        {ok, MatchPid} ->
            case check_join_rate(PlayerId) of
                denied ->
                    Reply = encode_error(Cid, ~"join_rate_limited"),
                    {reply, {text, Reply}, State};
                allowed ->
                    case asobi_join_ctx:parse(maps:get(~"payload", Msg, #{})) of
                        {error, CtxErr} ->
                            Reply = encode_error(Cid, CtxErr),
                            {reply, {text, Reply}, State};
                        {ok, Ctx} ->
                            join_match_and_reply(Cid, MatchPid, PlayerId, Ctx, State)
                    end
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
            %% #447: a vote lives on the fabric the player is actually in. A
            %% match player casts against their match_server; a world player
            %% casts against their world_server, which owns the world's votes.
            %% Resolving from the authenticated session's own state (never from
            %% the payload) is what stops a player voting in a fabric they are
            %% not in. Mirrors the match.input fallback shape.
            case maps:get(match_pid, SState, undefined) of
                undefined ->
                    case maps:get(world_pid, SState, undefined) of
                        undefined ->
                            Reply = encode_error(Cid, ~"not_in_match"),
                            {reply, {text, Reply}, State};
                        WorldPid ->
                            VoteId = maps:get(~"vote_id", Payload),
                            OptionId = maps:get(~"option_id", Payload),
                            case
                                vote_call(fun() ->
                                    asobi_world_server:cast_vote(
                                        WorldPid, PlayerId, VoteId, OptionId
                                    )
                                end)
                            of
                                ok ->
                                    Reply = encode_reply(Cid, ~"vote.cast_ok", #{success => true}),
                                    {reply, {text, Reply}, State};
                                {error, Reason} ->
                                    Reply = encode_error(Cid, Reason),
                                    {reply, {text, Reply}, State}
                            end
                    end;
                MatchPid ->
                    VoteId = maps:get(~"vote_id", Payload),
                    OptionId = maps:get(~"option_id", Payload),
                    case
                        vote_call(fun() ->
                            asobi_match_server:cast_vote(MatchPid, PlayerId, VoteId, OptionId)
                        end)
                    of
                        ok ->
                            Reply = encode_reply(Cid, ~"vote.cast_ok", #{success => true}),
                            {reply, {text, Reply}, State};
                        {error, Reason} ->
                            Reply = encode_error(Cid, Reason),
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
            %% #447: same fabric-aware routing as vote.cast - a world player's
            %% veto reaches their world_server, a match player's their
            %% match_server.
            case maps:get(match_pid, SState, undefined) of
                undefined ->
                    case maps:get(world_pid, SState, undefined) of
                        undefined ->
                            Reply = encode_error(Cid, ~"not_in_match"),
                            {reply, {text, Reply}, State};
                        WorldPid ->
                            VoteId = maps:get(~"vote_id", Payload),
                            case
                                vote_call(fun() ->
                                    asobi_world_server:use_veto(WorldPid, PlayerId, VoteId)
                                end)
                            of
                                ok ->
                                    Reply = encode_reply(Cid, ~"vote.veto_ok", #{success => true}),
                                    {reply, {text, Reply}, State};
                                {error, Reason} ->
                                    Reply = encode_error(Cid, Reason),
                                    {reply, {text, Reply}, State}
                            end
                    end;
                MatchPid ->
                    VoteId = maps:get(~"vote_id", Payload),
                    case
                        vote_call(fun() ->
                            asobi_match_server:use_veto(MatchPid, PlayerId, VoteId)
                        end)
                    of
                        ok ->
                            Reply = encode_reply(Cid, ~"vote.veto_ok", #{success => true}),
                            {reply, {text, Reply}, State};
                        {error, Reason} ->
                            Reply = encode_error(Cid, Reason),
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
    case build_listing_filters(Payload) of
        {ok, Filters} ->
            %% H3 (2026-05-19): cached variant absorbs the per-world
            %% get_info fan-out so a flood of world.list messages cannot
            %% stall every world's mailbox.
            Worlds = asobi_world_lobby:list_worlds_cached(Filters),
            Reply = encode_reply(Cid, ~"world.list", #{worlds => Worlds}),
            {reply, {text, Reply}, State};
        {error, Reason} ->
            Reply = encode_error(Cid, Reason),
            {reply, {text, Reply}, State}
    end;
handle_message(
    #{~"type" := ~"match.list", ~"payload" := Payload} = Msg,
    #{player_id := _PlayerId} = State
) when is_map(Payload) ->
    Cid = maps:get(~"cid", Msg, undefined),
    case build_listing_filters(Payload) of
        {ok, Filters} ->
            Matches = asobi_match_lobby:list_matches_cached(Filters),
            Reply = encode_reply(Cid, ~"match.list", #{matches => Matches}),
            {reply, {text, Reply}, State};
        {error, Reason} ->
            Reply = encode_error(Cid, Reason),
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
            Reply = encode_error(Cid, Reason),
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
            Reply = encode_error(Cid, Reason),
            {reply, {text, Reply}, State}
    end;
handle_message(
    #{~"type" := ~"world.join", ~"payload" := #{~"world_id" := WorldId}} = Msg,
    #{player_id := PlayerId} = State
) ->
    Cid = maps:get(~"cid", Msg, undefined),
    case asobi_world_server:whereis(WorldId) of
        error ->
            Reply = encode_error(Cid, ~"world_not_found"),
            {reply, {text, Reply}, State};
        {ok, WorldPid} ->
            case check_join_rate(PlayerId) of
                denied ->
                    Reply = encode_error(Cid, ~"join_rate_limited"),
                    {reply, {text, Reply}, State};
                allowed ->
                    case asobi_join_ctx:parse(maps:get(~"payload", Msg, #{})) of
                        {error, CtxErr} ->
                            Reply = encode_error(Cid, CtxErr),
                            {reply, {text, Reply}, State};
                        {ok, Ctx} ->
                            join_and_reply(Cid, WorldPid, PlayerId, Ctx, State)
                    end
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
%% The extension wire (Wave 2b). Everything about the call - `cid` validation,
%% readiness, the method table, the error object - belongs to asobi_rpc; this
%% clause only decides who is calling and encodes the answer. One clause, not
%% one per authentication state, so an unauthenticated caller cannot be told
%% `unknown_type` for a method that exists.
handle_message(#{~"type" := ~"rpc.call"} = Msg, State) ->
    {Cid, Outcome} = asobi_rpc:handle(
        maps:get(~"cid", Msg, undefined),
        maps:get(~"payload", Msg, #{}),
        rpc_caller(State)
    ),
    {reply, {text, encode_rpc(Cid, Outcome)}, State};
handle_message(#{~"type" := _Type} = Msg, State) ->
    %% F-26: do NOT echo the client-supplied `type` back into the error
    %% reply or logs — an attacker could craft strings that pollute the
    %% structured-log pipeline. The client knows what it sent, so the
    %% reason alone is enough.
    Cid = maps:get(~"cid", Msg, undefined),
    Reply = encode_error(Cid, ~"unknown_type"),
    {reply, {text, Reply}, State};
handle_message(_Msg, State) ->
    {ok, State}.

rpc_caller(#{session := SessionPid, player_id := PlayerId}) when
    is_pid(SessionPid), is_binary(PlayerId)
->
    #{player_id => PlayerId, session => SessionPid, transport => ws};
rpc_caller(_State) ->
    unauthenticated.

%% `rpc.error` carries the error object alone. The `reason` half of the older
%% `error` frame is not repeated here: nothing has ever shipped against this
%% frame, so there is no client to keep working, and one dialect on a new
%% surface is the point of the object. The `{type, payload}` pair comes from
%% `asobi_rpc:envelope/1`, the one place it is built, so the HTTP transport
%% (`m:asobi_rpc_controller`) puts the same payload on the wire.
encode_rpc(Cid, Outcome) ->
    {Type, Payload} = asobi_rpc:envelope(Outcome),
    encode_reply(Cid, Type, Payload).

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
    Reply = encode_error(Cid, Reason),
    {reply, {text, Reply}, State}.

%% asobi#193: joining is how a client reaches a roster and leaving is free,
%% so an unbounded join rate lets one account sweep every live world. Keyed
%% on player_id because identity, not IP, is the unit an attacker rotates.
%% `world.create`/`world.find_or_create` route through join_and_reply too, so
%% they are covered by the same bucket.
check_join_rate(PlayerId) ->
    case seki:check(asobi_join_limiter, PlayerId) of
        {allow, _} ->
            allowed;
        {deny, _} ->
            asobi_telemetry:join_rate_limited(PlayerId),
            denied
    end.

join_match_and_reply(Cid, MatchPid, PlayerId, Ctx, State) ->
    case asobi_match_server:join(MatchPid, PlayerId, Ctx) of
        ok ->
            Info = asobi_match_server:get_info(MatchPid),
            Reply = encode_reply(Cid, ~"match.joined", Info),
            {reply, {text, Reply}, State};
        %% The game refused this player. The reason is the script's own
        %% vocabulary, so it travels as a detail under a fixed asobi reason -
        %% a script must not be able to mint an error code (see m:asobi_error).
        {error, {join_refused, undefined}} ->
            Reply = encode_error(Cid, ~"join_refused"),
            {reply, {text, Reply}, State};
        {error, {join_refused, Detail}} when is_binary(Detail) ->
            Reply = encode_error(Cid, ~"join_refused", #{}, #{refused_reason => Detail}),
            {reply, {text, Reply}, State};
        {error, Reason} ->
            Reply = encode_error(Cid, Reason),
            {reply, {text, Reply}, State}
    end.

join_and_reply(Cid, WorldPid, PlayerId, State) ->
    join_and_reply(Cid, WorldPid, PlayerId, #{}, State).

join_and_reply(Cid, WorldPid, PlayerId, Ctx, #{session := SessionPid} = State) when
    SessionPid =/= undefined
->
    case current_player_world(PlayerId) of
        {ok, ExistingPid} when ExistingPid =/= WorldPid ->
            %% Player is already in a different (live) world. Force them to
            %% world.leave first; otherwise they'd appear in two worlds at once.
            Reply = encode_error(Cid, ~"already_in_world"),
            {reply, {text, Reply}, State};
        _ ->
            %% join/3 (vs join/2) sets zone_pid synchronously in the player_session
            %% before returning, so a world.input arriving right after world.joined
            %% lands on the right zone instead of being silently dropped.
            case asobi_world_server:join(WorldPid, PlayerId, SessionPid, Ctx) of
                ok ->
                    Info = asobi_world_server:get_info(WorldPid),
                    Reply = encode_reply(Cid, ~"world.joined", Info),
                    {reply, {text, Reply}, State};
                {error, Reason} ->
                    Reply = encode_error(Cid, Reason),
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

%% asobi#462: a vote whose fabric is gone reaches asobi_vote_server via a
%% gen_statem:call that exits. safe_handle_message/2 already catches any handler
%% exit and returns an error frame, so this is never a crash-preventer - but
%% that generic path logs a warning and answers internal_error, blaming asobi
%% for a race the client cannot avoid. Catch only the process-gone exit shapes
%% here and upgrade them to the clean, registered not_in_match: a finished
%% fabric stops with normal (and a call that lost the race to its cleanup sees
%% that stop), a dead one is noproc, and supervised teardown can surface
%% shutdown or killed. Any other exit reason is a genuine vote-handler crash and
%% falls through to safe_handle_message -> logged internal_error, which is
%% intended - masking a real crash as not_in_match would hide it. The normal
%% ok/{error, Reason} replies are untouched.
-spec vote_call(fun(() -> ok | {error, term()})) -> ok | {error, term()}.
vote_call(Call) ->
    try
        Call()
    catch
        exit:{noproc, _} -> {error, not_in_match};
        exit:{normal, _} -> {error, not_in_match};
        exit:{shutdown, _} -> {error, not_in_match};
        exit:killed -> {error, not_in_match}
    end.

cancel_idle_auth_timer(#{idle_auth_timer := Ref} = State) when is_reference(Ref) ->
    _ = erlang:cancel_timer(Ref, [{async, true}, {info, false}]),
    maps:remove(idle_auth_timer, State);
cancel_idle_auth_timer(State) ->
    State.

authenticate(#{~"token" := Token}) when is_binary(Token) ->
    case asobi_auth_cache:resolve_token(Token) of
        {ok, Player} ->
            {ok, maps:get(id, Player)};
        {error, _} ->
            {error, ~"invalid_token"}
    end;
authenticate(_) ->
    {error, ~"invalid_token"}.

%% #236: input for a match you are not in is still dropped, but the sender
%% gets a hint so "my input does nothing" is debuggable client-side. One
%% hint per window per connection - a client spamming input while unjoined
%% must not turn this into a reflected message stream.
not_in_match_hint(State) ->
    Now = erlang:system_time(millisecond),
    Last = maps:get(not_in_match_hint_at, State, 0),
    case Now - Last >= ?NOT_IN_MATCH_HINT_WINDOW_MS of
        true ->
            Reply = encode_error(undefined, ~"not_in_match", #{type => ~"match.input"}),
            {reply, {text, Reply}, State#{not_in_match_hint_at => Now}};
        false ->
            {ok, State}
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

%% The legacy frame goes first so a shipped client sees byte-identical
%% ordering to before S6; the new type is purely additive behind it.
-spec extension_frames(binary(), binary(), map()) -> [{text, binary()}].
extension_frames(Type, LegacyType, Body) ->
    New = {text, encode_reply(undefined, Type, Body)},
    case legacy_game_frames() of
        true -> [{text, encode_reply(undefined, LegacyType, Body)}, New];
        false -> [New]
    end.

legacy_game_frames() ->
    case application:get_env(asobi, ws_legacy_game_frames) of
        {ok, Enabled} when is_boolean(Enabled) -> Enabled;
        _ -> ?DEFAULT_LEGACY_GAME_FRAMES
    end.

%% Every error frame now carries both dialects. `reason` is the original
%% WebSocket string and is unchanged, byte for byte, so existing clients keep
%% working; `error` is the shared object (see `asobi_error`) that new clients
%% and the ops/RPC surfaces branch on. One funnel, so a converted call site
%% cannot drift back to the bare-`reason` shape.
encode_error(Cid, Reason) ->
    encode_error(Cid, Reason, #{}).

encode_error(Cid, Reason, Extra) when is_map(Extra) ->
    encode_error(Cid, Reason, Extra, #{}).

%% `Extra` sits at the top of the payload, where the pre-object dialect put
%% its per-reason keys; `Details` goes inside the error object, where a client
%% reading only `error` can still see it. New context belongs in `Details`.
encode_error(Cid, Reason, Extra, Details) when is_map(Extra), is_map(Details) ->
    Bin = to_reason_binary(Reason),
    Payload = maps:merge(Extra#{reason => Bin}, asobi_error:from_ws_reason(Bin, Details)),
    encode_reply(Cid, ~"error", Payload).

to_reason_binary(R) when is_atom(R) -> atom_to_binary(R, utf8);
to_reason_binary(R) when is_binary(R) -> R;
%% Anything else is a term from deeper in the stack - a crashed Lua callback's
%% `{lua_error, _}`, say. It reached here with no clause, and
%% safe_handle_message/2 turned the function_clause into `invalid_payload`,
%% blaming the client for a fault on the server. A structured term is never
%% safe to forward (it can carry script internals), so it is reported as what
%% it is and the detail stays in the logs.
to_reason_binary(_) -> ~"internal".

-spec reserved_event_names() -> [binary()].
reserved_event_names() -> ?RESERVED_EVENT_NAMES.

%% #297/#303: normalizes a match/world event name to a binary for the wire
%% `Type` field, validating any script-controlled binary name first.
%% Atoms only ever originate in asobi's own source (never binary_to_atom on
%% a client/Lua-influenced name — atom-table exhaustion risk), so they are
%% trusted unconditionally; binaries come straight from Lua's
%% game.broadcast and must be bounded, ASCII-only, and outside the
%% library-reserved namespace before they may reach the wire:
%%  - unbounded/non-ASCII bytes (including invalid UTF-8) would crash
%%    json:encode/1 inside every subscriber's socket process during the
%%    zone/match broadcast fan-out, disconnecting the whole world/match;
%%  - a name equal to a reserved suffix would forge a frame byte-identical
%%    to a genuine authoritative event (e.g. `world.tick`, `match.state`).
-spec event_name_binary(atom() | binary()) -> {ok, binary()} | {error, atom()}.
event_name_binary(Event) when is_atom(Event) ->
    {ok, atom_to_binary(Event)};
event_name_binary(Event) when is_binary(Event) ->
    case lists:member(Event, ?RESERVED_EVENT_NAMES) of
        true ->
            {error, reserved_event_name};
        false ->
            case
                byte_size(Event) > 0 andalso
                    byte_size(Event) =< ?MAX_EVENT_NAME_BYTES andalso
                    lists:all(fun is_event_name_char/1, binary_to_list(Event))
            of
                true -> {ok, Event};
                false -> {error, invalid_event_name}
            end
    end.

%% Deliberately excludes `.` — a script must not be able to mint a deeper
%% `world.foo.bar` sub-namespace. Spec'd over `term()`, not `byte()`: it is a
%% `lists:all/2` predicate and must stay `fun((term()) -> boolean())` for
%% eqwalizer, which its `_ -> false` total clause honours for any term.
-spec is_event_name_char(term()) -> boolean().
is_event_name_char(C) when C >= $a, C =< $z -> true;
is_event_name_char(C) when C >= $A, C =< $Z -> true;
is_event_name_char(C) when C >= $0, C =< $9 -> true;
is_event_name_char(C) when C =:= $_; C =:= $- -> true;
is_event_name_char(_) -> false.

%% F-16: chat.join must require a small, namespaced channel id so an
%% attacker can't spawn unbounded chat channel gen_servers via WS.
%% Delegates to asobi_chat_acl, the single source of truth for channel id
%% shape shared with the HTTP chat-history path.
validate_channel_id(ChannelId) -> asobi_chat_acl:validate_channel_id(ChannelId).

%% F-29: world.list/match.list filter values must be the right type or we
%% reject the request rather than silently returning unfiltered results.
build_listing_filters(Payload) ->
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
            Acc2 =
                case maps:find(~"has_capacity", Payload) of
                    error -> {ok, A1};
                    {ok, true} -> {ok, A1#{has_capacity => true}};
                    {ok, false} -> {ok, A1};
                    _ -> {error, ~"invalid_has_capacity_filter"}
                end,
            case Acc2 of
                {error, _} = E2 ->
                    E2;
                %% Unlike has_capacity, `false` is a filter and not the
                %% absence of one: "show me the matches that have closed" is
                %% a question a spectator browser asks. Worlds have no
                %% joinable flag and ignore the key.
                {ok, A2} ->
                    case maps:find(~"joinable", Payload) of
                        error -> {ok, A2};
                        {ok, J} when is_boolean(J) -> {ok, A2#{joinable => J}};
                        _ -> {error, ~"invalid_joinable_filter"}
                    end
            end
    end.
