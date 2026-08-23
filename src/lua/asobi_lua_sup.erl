-module(asobi_lua_sup).
-behaviour(supervisor).

-include_lib("kernel/include/logger.hrl").

%% Judgement calls rather than security boundaries: a limiter this repo would
%% defend in guides/configuration.md, and enough headroom that no real
%% deployment trips them.
-define(MAX_LIMITER_LIMIT, 100_000).
-define(MAX_LIMITER_WINDOW_MS, 3_600_000).

-export([start_link/0, register_game_modes/0]).
-export([init/1]).
-ifdef(TEST).
-export([merged_opts/3]).
-endif.

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
    _ = seki:new_limiter(limiter_name(Group), merged_opts(Group, DefaultOpts, Overrides)),
    ok.

%% `rate_limits` is operator-supplied, so the merge is checked rather than
%% handed to seki as-is: `limit => 0` reaches seki's registry as a division by
%% zero at register time, and that registry owns every limiter on the node.
%%
%% Rejection is logged, not silent - an operator who asked for something and
%% got asobi's defaults has to be able to find out. `backend`/`backend_opts`
%% are dropped deliberately: they are seki's own plumbing, and an operator
%% reaching for them here is likelier a typo than an intent.
-spec merged_opts(atom(), seki:limiter_opts(), map()) -> seki:limiter_opts().
merged_opts(_Group, Defaults, Overrides) when map_size(Overrides) =:= 0 ->
    Defaults;
merged_opts(Group, Defaults, Overrides) ->
    case maps:merge(Defaults, Overrides) of
        #{algorithm := A, limit := L, window := W} = Merged when
            is_integer(L),
            L > 0,
            L =< ?MAX_LIMITER_LIMIT,
            is_integer(W),
            W > 0,
            W =< ?MAX_LIMITER_WINDOW_MS,
            A =:= token_bucket orelse A =:= sliding_window orelse
                A =:= gcra orelse A =:= leaky_bucket
        ->
            with_burst(#{algorithm => A, limit => L, window => W}, Merged);
        _ ->
            ?LOG_WARNING(#{
                event => invalid_rate_limit_override,
                group => Group,
                override => Overrides,
                using => Defaults
            }),
            Defaults
    end.

-spec with_burst(seki:limiter_opts(), map()) -> seki:limiter_opts().
with_burst(Opts, #{burst := B}) when is_integer(B), B > 0, B =< ?MAX_LIMITER_LIMIT ->
    Opts#{burst => B};
with_burst(Opts, _Merged) ->
    Opts.

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
