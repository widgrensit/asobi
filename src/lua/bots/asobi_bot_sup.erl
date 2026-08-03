-module(asobi_bot_sup).
-behaviour(supervisor).

-export([start_link/0, start_bot/3]).
-export([init/1]).

-spec start_link() -> supervisor:startlink_ret().
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

-spec start_bot(pid(), binary(), binary() | undefined) -> supervisor:startchild_ret().
start_bot(MatchPid, BotId, LuaScript) ->
    supervisor:start_child(?MODULE, [MatchPid, BotId, LuaScript]).

-spec init([]) -> {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init([]) ->
    SupFlags = #{
        strategy => simple_one_for_one,
        intensity => 10,
        period => 60
    },
    ChildSpec = #{
        id => asobi_bot,
        start => {asobi_bot, start_link, []},
        restart => temporary,
        shutdown => 5000,
        type => worker
    },
    {ok, {SupFlags, [ChildSpec]}}.
