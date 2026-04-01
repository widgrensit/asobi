-module(asobi_chat_sup).
-behaviour(supervisor).

-export([start_link/0, start_channel/1, start_channel/2]).
-export([init/1]).

-spec start_link() -> supervisor:startlink_ret().
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

-spec start_channel(binary()) -> supervisor:startchild_ret().
start_channel(ChannelId) ->
    start_channel(ChannelId, ~"room").

-spec start_channel(binary(), binary()) -> supervisor:startchild_ret().
start_channel(ChannelId, ChannelType) ->
    supervisor:start_child(?MODULE, [ChannelId, ChannelType]).

-spec init([]) -> {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init([]) ->
    SupFlags = #{
        strategy => simple_one_for_one,
        intensity => 5,
        period => 60
    },
    ChildSpec = #{
        id => asobi_chat_channel,
        start => {asobi_chat_channel, start_link, []},
        restart => transient
    },
    {ok, {SupFlags, [ChildSpec]}}.
