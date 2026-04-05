-module(asobi_chat_channel).
-behaviour(gen_server).

-export([start_link/2, join/2, leave/2, send_message/3, get_history/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(MAX_BUFFER, 100).
-define(REGISTRY, asobi_chat_registry).
-define(PG_SCOPE, nova_scope).

-spec start_link(binary(), binary()) -> gen_server:start_ret().
start_link(ChannelId, ChannelType) ->
    gen_server:start_link(?MODULE, {ChannelId, ChannelType}, []).

-spec join(binary(), pid()) -> ok.
join(ChannelId, Pid) ->
    ensure_channel(ChannelId),
    pg:join(?PG_SCOPE, {chat, ChannelId}, Pid),
    ok.

-spec leave(binary(), pid()) -> ok.
leave(ChannelId, Pid) ->
    pg:leave(?PG_SCOPE, {chat, ChannelId}, Pid),
    ok.

-spec send_message(binary(), binary(), binary()) -> ok.
send_message(ChannelId, SenderId, Content) ->
    asobi_telemetry:chat_message_sent(ChannelId, SenderId),
    ensure_channel(ChannelId),
    case lookup(ChannelId) of
        {ok, Pid} ->
            gen_server:cast(Pid, {message, SenderId, Content});
        error ->
            ok
    end,
    ok.

-spec get_history(binary(), pos_integer()) -> [map()].
get_history(ChannelId, Limit) when is_integer(Limit) ->
    case lookup(ChannelId) of
        {ok, Pid} ->
            case gen_server:call(Pid, {history, Limit}) of
                History when is_list(History) -> [M || M <- History, is_map(M)];
                _ -> []
            end;
        error ->
            []
    end.

-spec init({binary(), binary()}) -> {ok, map()}.
init({ChannelId, ChannelType}) ->
    ensure_registry(),
    ets:insert(?REGISTRY, {ChannelId, self()}),
    process_flag(trap_exit, true),
    {ok, #{
        channel_id => ChannelId,
        channel_type => ChannelType,
        buffer => [],
        buffer_size => 0
    }}.

-spec handle_call(term(), gen_server:from(), map()) -> {reply, term(), map()}.
handle_call({history, Limit}, _From, #{buffer := Buffer} = State) when is_integer(Limit) ->
    History = lists:sublist(Buffer, Limit),
    {reply, lists:reverse(History), State};
handle_call(_Request, _From, State) ->
    {reply, ok, State}.

-spec handle_cast(term(), map()) -> {noreply, map()}.
handle_cast(
    {message, SenderId, Content},
    #{
        channel_id := ChannelId,
        channel_type := ChannelType,
        buffer := Buffer,
        buffer_size := Size
    } = State
) when is_binary(SenderId), is_binary(Content) ->
    Msg = #{
        sender_id => SenderId,
        content => Content,
        sent_at => erlang:system_time(millisecond)
    },
    Members = pg:get_members(?PG_SCOPE, {chat, ChannelId}),
    lists:foreach(
        fun(Pid) when is_pid(Pid) -> Pid ! {chat_message, ChannelId, Msg} end,
        Members
    ),
    persist_message(ChannelType, ChannelId, SenderId, Content),
    Buffer1 =
        case Size >= ?MAX_BUFFER of
            true -> [Msg | lists:droplast(Buffer)];
            false -> [Msg | Buffer]
        end,
    {noreply, State#{buffer => Buffer1, buffer_size => min(Size + 1, ?MAX_BUFFER)}};
handle_cast(_Msg, State) ->
    {noreply, State}.

-spec handle_info(term(), map()) -> {noreply, map()}.
handle_info(_Info, State) ->
    {noreply, State}.

-spec terminate(term(), map()) -> ok.
terminate(_Reason, #{channel_id := ChannelId}) ->
    try
        ets:delete(?REGISTRY, ChannelId)
    catch
        _:_ -> ok
    end,
    ok;
terminate(_Reason, _State) ->
    ok.

%% --- Channel lifecycle ---

ensure_channel(ChannelId) ->
    case lookup(ChannelId) of
        {ok, Pid} when is_pid(Pid) ->
            case is_process_alive(Pid) of
                true ->
                    ok;
                false ->
                    try
                        ets:delete(?REGISTRY, ChannelId)
                    catch
                        _:_ -> ok
                    end,
                    start_new_channel(ChannelId)
            end;
        error ->
            start_new_channel(ChannelId)
    end.

start_new_channel(ChannelId) ->
    case asobi_chat_sup:start_channel(ChannelId) of
        {ok, _Pid} -> ok;
        {error, _} -> ok
    end.

lookup(ChannelId) ->
    ensure_registry(),
    case ets:lookup(?REGISTRY, ChannelId) of
        [{_, Pid}] -> {ok, Pid};
        [] -> error
    end.

ensure_registry() ->
    case ets:whereis(?REGISTRY) of
        undefined ->
            _ = ets:new(?REGISTRY, [named_table, public, set, {read_concurrency, true}]),
            ok;
        _ ->
            ok
    end.

%% --- Persistence ---

-spec persist_message(binary(), binary(), binary(), binary()) -> ok.
persist_message(ChannelType, ChannelId, SenderId, Content) ->
    CS = kura_changeset:cast(
        asobi_chat_message,
        #{},
        #{
            channel_type => ChannelType,
            channel_id => ChannelId,
            sender_id => SenderId,
            content => Content,
            sent_at => calendar:universal_time()
        },
        [channel_type, channel_id, sender_id, content, sent_at]
    ),
    _ = asobi_repo:insert(CS),
    ok.
