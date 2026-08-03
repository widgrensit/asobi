-module(asobi_lua_sup).
-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

-spec start_link() -> supervisor:startlink_ret().
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

-spec init([]) -> {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init([]) ->
    SupFlags = #{
        strategy => one_for_one,
        intensity => 10,
        period => 60
    },
    Children = [
        rate_limit_spec(),
        bot_sup(),
        bot_spawner_spec(),
        config_watcher_spec()
    ],
    {ok, {SupFlags, Children}}.

rate_limit_spec() ->
    #{
        id => asobi_lua_rate_limits,
        start => {erlang, apply, [fun register_limiters/0, []]},
        restart => temporary
    }.

register_limiters() ->
    %% game.log flood control (#58): the per-match/zone budget stops one
    %% chatty script drowning its neighbours' log lines; the constant-keyed
    %% global backstop bounds the aggregate cost one node can push into the
    %% operator's log pipeline regardless of how many matches are running.
    %% Mirrors asobi_sup's limiter setup, overridable via the `rate_limits`
    %% key (see asobi_lua_env for which application it is read from).
    Defaults = #{
        log => #{algorithm => sliding_window, limit => 30, window => 1000},
        log_global => #{algorithm => sliding_window, limit => 300, window => 1000}
    },
    Configured =
        case asobi_lua_env:get_env(rate_limits, #{}) of
            M when is_map(M) -> M;
            _ -> #{}
        end,
    maps:foreach(
        fun(Group, DefaultOpts) ->
            Overrides =
                case maps:get(Group, Configured, #{}) of
                    O when is_map(O) -> O;
                    _ -> #{}
                end,
            _ = seki:new_limiter(limiter_name(Group), maps:merge(DefaultOpts, Overrides))
        end,
        Defaults
    ),
    ignore.

limiter_name(log) -> asobi_lua_log_limiter;
limiter_name(log_global) -> asobi_lua_log_global_limiter.

config_watcher_spec() ->
    #{
        id => asobi_lua_config_watcher,
        start => {asobi_lua_config_watcher, start_link, []}
    }.

bot_sup() ->
    #{
        id => asobi_bot_sup,
        start => {asobi_bot_sup, start_link, []},
        type => supervisor
    }.

bot_spawner_spec() ->
    #{
        id => asobi_bot_spawner,
        start => {asobi_bot_spawner, start_link, []}
    }.
