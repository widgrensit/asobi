-module(asobi_chat_sup).
-behaviour(supervisor).

-export([start_link/0, start_channel/1, start_channel/2]).
-export([init/1]).

-define(REGISTRY, asobi_chat_registry).

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
    %% Owned by the supervisor process so the table outlives every
    %% channel restart. Eager-creating here removes the lazy
    %% ets:whereis/ets:new check from the lookup hot path and the race
    %% where two simultaneous `start_channel` callers both saw the
    %% table missing.
    case ets:whereis(?REGISTRY) of
        undefined ->
            ?REGISTRY = ets:new(?REGISTRY, [
                named_table,
                public,
                set,
                {read_concurrency, true},
                {write_concurrency, true}
            ]),
            ok;
        _ ->
            ok
    end,
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
