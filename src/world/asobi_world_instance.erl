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
    GridSize = maps:get(grid_size, Config, 10),
    ZoneSize = maps:get(zone_size, Config, 200),
    %% Owned by this supervisor so it dies exactly when the world does. No asobi
    %% process traps exits, so nothing's terminate/2 runs on a supervisor
    %% shutdown - hanging the mirror's cleanup off one would strand a whole grid
    %% of rows on every world teardown. See asobi_zone_border.
    BorderTab = asobi_zone_border:new(),
    ZoneManagerConfig = #{
        world_id => maps:get(world_id, Config, undefined),
        instance_sup => self(),
        grid_size => GridSize,
        zone_size => ZoneSize,
        zone_config => maps:get(zone_manager_config, Config, #{}),
        idle_timeout => maps:get(zone_idle_timeout, Config, 30_000),
        max_active_zones => maps:get(max_active_zones, Config, 10_000)
    },
    TickerConfig = #{
        tick_rate => maps:get(tick_rate, Config, 50),
        %% Was never threaded through, so a world declaring `cold_tick_divisor`
        %% silently got the ticker's own default (widgrensit/asobi#543).
        cold_tick_divisor => maps:get(cold_tick_divisor, Config, 10),
        world_id => maps:get(world_id, Config, undefined),
        world_pid => self()
    },
    WorldConfig = Config#{
        instance_sup => self(),
        border_tab => BorderTab
    },
    Children = [
        #{
            id => asobi_zone_sup,
            start => {asobi_zone_sup, start_link, []},
            type => supervisor
        },
        #{
            id => asobi_zone_manager,
            start => {asobi_zone_manager, start_link, [ZoneManagerConfig]},
            restart => transient
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
