-module(asobi_world_instance_sup).
-behaviour(supervisor).

-export([start_link/0, start_world/1]).
-export([init/1]).

-spec start_link() -> supervisor:startlink_ret().
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

-spec start_world(map()) -> supervisor:startchild_ret().
start_world(Config) ->
    supervisor:start_child(?MODULE, [Config]).

-spec init([]) -> {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init([]) ->
    SupFlags = #{
        strategy => simple_one_for_one,
        intensity => 10,
        period => 60
    },
    ChildSpec = #{
        id => asobi_world_instance,
        start => {asobi_world_instance, start_link, []},
        type => supervisor,
        restart => transient
    },
    {ok, {SupFlags, [ChildSpec]}}.
