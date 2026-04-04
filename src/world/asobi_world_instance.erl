-module(asobi_world_instance).
-behaviour(supervisor).

%% Supervisor for a single world instance.
%% Uses one_for_all: if any child crashes, restart everything.
%%
%% Start sequence:
%% 1. Zone sup (no deps)
%% 2. World ticker (no deps initially, gets zone list later)
%% 3. World server (discovers zone_sup and ticker via supervisor)
%%
%% The world server starts zones via zone_sup and tells the ticker about them.

-export([start_link/1]).
-export([init/1]).
-export([get_child/2]).

-spec start_link(map()) -> supervisor:startlink_ret().
start_link(Config) ->
    supervisor:start_link(?MODULE, Config).

-spec get_child(pid(), atom()) -> pid() | undefined.
get_child(SupPid, ChildId) ->
    Children = supervisor:which_children(SupPid),
    case lists:keyfind(ChildId, 1, Children) of
        {_, Pid, _, _} when is_pid(Pid) -> Pid;
        _ -> undefined
    end.

-spec init(map()) -> {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init(Config) ->
    SupFlags = #{
        strategy => one_for_all,
        intensity => 5,
        period => 60
    },
    TickerConfig = #{
        tick_rate => maps:get(tick_rate, Config, 50),
        world_pid => self()
    },
    WorldConfig = Config#{
        instance_sup => self()
    },
    Children = [
        #{
            id => asobi_zone_sup,
            start => {asobi_zone_sup, start_link, []},
            type => supervisor
        },
        #{
            id => asobi_world_ticker,
            start => {asobi_world_ticker, start_link, [TickerConfig]},
            restart => transient
        },
        #{
            id => asobi_world_server,
            start => {asobi_world_server, start_link, [WorldConfig]},
            restart => transient
        }
    ],
    {ok, {SupFlags, Children}}.
