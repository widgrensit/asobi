-module(asobi_zone_sup).
-behaviour(supervisor).

-export([start_link/0, start_zone/2]).
-export([init/1]).

-spec start_link() -> supervisor:startlink_ret().
start_link() ->
    supervisor:start_link(?MODULE, []).

-spec start_zone(pid(), map()) -> supervisor:startchild_ret().
start_zone(SupPid, Config) ->
    supervisor:start_child(SupPid, [Config]).

-spec init([]) -> {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init([]) ->
    SupFlags = #{
        strategy => simple_one_for_one,
        intensity => 50,
        period => 60
    },
    %% Explicit rather than defaulted: a zone traps exits so its terminate/2 can
    %% write a final snapshot, and the shutdown budget is what gives it time to.
    %% simple_one_for_one terminates its children concurrently, so this is the
    %% wall-clock ceiling for the whole grid, not per zone.
    ChildSpec = #{
        id => asobi_zone,
        start => {asobi_zone, start_link, []},
        restart => transient,
        shutdown => 5_000
    },
    {ok, {SupFlags, [ChildSpec]}}.
