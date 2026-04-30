-module(asobi_world_sup).
-moduledoc """
Top-level world supervisor.

**Public ETS trust assumption (F-33)**: `asobi_world_state` and
`asobi_player_worlds` are `public` named ETS tables. Anything running
in the same BEAM (game callbacks, plugins, etc.) can read and mutate
them. asobi is single-tenant and the loaded code is trusted, so this
is acceptable — but it's an explicit trust boundary worth surfacing
in the threat model. Any sandboxed runtime layered on top of asobi
(e.g. `asobi_lua`) MUST keep its sandbox out of these tables.
""".
-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

-spec start_link() -> supervisor:startlink_ret().
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

-spec init([]) -> {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init([]) ->
    %% ETS tables for world state backup and player-world mapping
    _ =
        case ets:info(asobi_world_state) of
            undefined ->
                ets:new(asobi_world_state, [named_table, public, set, {read_concurrency, true}]);
            _ ->
                ok
        end,
    _ =
        case ets:info(asobi_player_worlds) of
            undefined ->
                ets:new(asobi_player_worlds, [named_table, public, set, {read_concurrency, true}]);
            _ ->
                ok
        end,
    SupFlags = #{
        strategy => one_for_one,
        intensity => 10,
        period => 60
    },
    Children = [
        #{
            id => asobi_zone_snapshotter,
            start => {asobi_zone_snapshotter, start_link, []}
        },
        #{
            id => asobi_world_registry,
            start => {asobi_world_registry, start_link, []}
        },
        #{
            id => asobi_world_instance_sup,
            start => {asobi_world_instance_sup, start_link, []},
            type => supervisor
        }
    ],
    {ok, {SupFlags, Children}}.
