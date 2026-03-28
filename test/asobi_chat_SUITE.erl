-module(asobi_chat_SUITE).

-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([
    channel_lifecycle/1,
    message_buffer/1,
    message_broadcast/1
]).

all() -> [channel_lifecycle, message_buffer, message_broadcast].

init_per_suite(Config) ->
    application:ensure_all_started(asobi),
    Config.

end_per_suite(Config) ->
    Config.

channel_lifecycle(Config) ->
    ChannelId = ~"test_channel_1",
    {ok, _} = asobi_chat_sup:start_channel(ChannelId, ~"room"),
    asobi_chat_channel:join(ChannelId, self()),
    asobi_chat_channel:send_message(ChannelId, ~"sender1", ~"Hello!"),
    receive
        {chat_message, ChannelId, #{content := ~"Hello!"}} -> ok
    after 1000 ->
        error(message_not_received)
    end,
    asobi_chat_channel:leave(ChannelId, self()),
    Config.

message_buffer(Config) ->
    ChannelId = ~"test_channel_2",
    {ok, _} = asobi_chat_sup:start_channel(ChannelId, ~"room"),
    lists:foreach(
        fun(I) ->
            Content = list_to_binary("msg" ++ integer_to_list(I)),
            asobi_chat_channel:send_message(ChannelId, ~"sender", Content)
        end,
        lists:seq(1, 5)
    ),
    timer:sleep(50),
    History = asobi_chat_channel:get_history(ChannelId, 3),
    ?assertEqual(3, length(History)),
    Config.

message_broadcast(Config) ->
    ChannelId = ~"test_channel_3",
    {ok, _} = asobi_chat_sup:start_channel(ChannelId, ~"room"),
    Self = self(),
    Listener = spawn(fun() ->
        asobi_chat_channel:join(ChannelId, self()),
        receive
            {chat_message, _, #{content := C}} -> Self ! {received, C}
        end
    end),
    timer:sleep(50),
    asobi_chat_channel:join(ChannelId, self()),
    asobi_chat_channel:send_message(ChannelId, ~"sender", ~"broadcast_test"),
    receive
        {received, ~"broadcast_test"} -> ok
    after 1000 ->
        error(listener_did_not_receive)
    end,
    _ = Listener,
    Config.
