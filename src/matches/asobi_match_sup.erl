-module(asobi_match_sup).
-behaviour(supervisor).

-export([start_link/0, start_match/1]).
-export([init/1]).

-spec start_link() -> supervisor:startlink_ret().
start_link() ->
    _ = ets:new(asobi_match_state, [named_table, public, set, {read_concurrency, true}]),
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

-spec start_match(map()) -> supervisor:startchild_ret().
start_match(Config) ->
    supervisor:start_child(?MODULE, [Config]).

-spec init([]) -> {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init([]) ->
    SupFlags = #{
        strategy => simple_one_for_one,
        intensity => 10,
        period => 60
    },
    ChildSpec = #{
        id => asobi_match_server,
        start => {asobi_match_server, start_link, []},
        restart => transient
    },
    {ok, {SupFlags, [ChildSpec]}}.
