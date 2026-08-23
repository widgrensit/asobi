-module(asobi_lua_sup).
-behaviour(supervisor).

-export([start_link/0, register_game_modes/0]).
-export([init/1]).

-doc """
Register the Lua bridge modules as the providers for the three Lua game-mode
kinds `asobi_game_modes` knows about.

Called from `asobi_app:start/2` before the supervision tree comes up, and by
any test that resolves a `{lua, _}` mode without booting the application. The
mapping lives here, next to the bridges, so `asobi_game_modes` keeps knowing
nothing about the scripting runtime.
""".
-spec register_game_modes() -> ok.
register_game_modes() ->
    ok = asobi_game_modes:register_game_mode(lua_match, asobi_lua_match),
    ok = asobi_game_modes:register_game_mode(lua_match_shared, asobi_lua_match_shared),
    ok = asobi_game_modes:register_game_mode(lua_world, asobi_lua_world).

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
        fun(Group, DefaultOpts) -> register_limiter(Group, DefaultOpts, Configured) end,
        Defaults
    ),
    ignore.

-spec register_limiter(atom(), seki:limiter_opts(), map()) -> ok.
register_limiter(Group, DefaultOpts, Configured) ->
    Overrides =
        case maps:get(Group, Configured, #{}) of
            O when is_map(O) -> O;
            _ -> #{}
        end,
    _ = seki:new_limiter(limiter_name(Group), merged_opts(DefaultOpts, Overrides)),
    ok.

%% `rate_limits` is operator-supplied, so the merge is checked rather than
%% handed to seki as-is. An override that is not a usable algorithm/limit/window
%% now falls back to asobi's defaults instead of reaching the limiter, and the
%% optional seki keys (burst, backend, backend_opts) are not overridable -
%% nothing here sets them, and passing an unvalidated map through was the only
%% reason they were.
-spec merged_opts(seki:limiter_opts(), map()) -> seki:limiter_opts().
merged_opts(Defaults, Overrides) ->
    case maps:merge(Defaults, Overrides) of
        #{algorithm := A, limit := L, window := W} when
            is_integer(L),
            L > 0,
            is_integer(W),
            W > 0,
            A =:= token_bucket orelse A =:= sliding_window orelse
                A =:= gcra orelse A =:= leaky_bucket
        ->
            #{algorithm => A, limit => L, window => W};
        _ ->
            Defaults
    end.

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
