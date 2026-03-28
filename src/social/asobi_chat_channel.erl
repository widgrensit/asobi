-module(asobi_chat_channel).
-behaviour(gen_server).

-export([start_link/2, join/2, leave/2, send_message/3, get_history/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(PG_SCOPE, asobi_chat).
-define(MAX_BUFFER, 100).

-spec start_link(binary(), binary()) -> {ok, pid()}.
start_link(ChannelId, ChannelType) ->
    gen_server:start_link(
        {via, {global, {?MODULE, ChannelId}}}, ?MODULE, {ChannelId, ChannelType}, []
    ).

-spec join(binary(), pid()) -> ok.
join(ChannelId, Pid) ->
    pg:join(?PG_SCOPE, {chat, ChannelId}, Pid),
    ok.

-spec leave(binary(), pid()) -> ok.
leave(ChannelId, Pid) ->
    pg:leave(?PG_SCOPE, {chat, ChannelId}, Pid),
    ok.

-spec send_message(binary(), binary(), binary()) -> ok.
send_message(ChannelId, SenderId, Content) ->
    gen_server:cast({via, {global, {?MODULE, ChannelId}}}, {message, SenderId, Content}).

-spec get_history(binary(), pos_integer()) -> [map()].
get_history(ChannelId, Limit) ->
    gen_server:call({via, {global, {?MODULE, ChannelId}}}, {history, Limit}).

-spec init({binary(), binary()}) -> {ok, map()}.
init({ChannelId, ChannelType}) ->
    pg:start_link(?PG_SCOPE),
    {ok, #{
        channel_id => ChannelId,
        channel_type => ChannelType,
        buffer => [],
        buffer_size => 0
    }}.

-spec handle_call(term(), gen_server:from(), map()) -> {reply, term(), map()}.
handle_call({history, Limit}, _From, #{buffer := Buffer} = State) ->
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
) ->
    Msg = #{
        sender_id => SenderId,
        content => Content,
        sent_at => erlang:system_time(millisecond)
    },
    Members = pg:get_members(?PG_SCOPE, {chat, ChannelId}),
    lists:foreach(
        fun(Pid) -> Pid ! {chat_message, ChannelId, Msg} end,
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
terminate(_Reason, _State) ->
    ok.

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
