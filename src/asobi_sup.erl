-module(asobi_sup).
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
        cluster_spec(),
        player_session_sup(),
        match_sup(),
        world_sup(),
        vote_sup(),
        matchmaker_spec(),
        leaderboard_sup(),
        chat_sup(),
        tournament_sup(),
        presence_spec(),
        bot_sup(),
        bot_spawner_spec(),
        season_manager_spec()
    ],
    {ok, {SupFlags, Children}}.

player_session_sup() ->
    #{
        id => asobi_player_session_sup,
        start => {asobi_player_session_sup, start_link, []},
        type => supervisor
    }.

match_sup() ->
    #{
        id => asobi_match_sup,
        start => {asobi_match_sup, start_link, []},
        type => supervisor
    }.

world_sup() ->
    #{
        id => asobi_world_sup,
        start => {asobi_world_sup, start_link, []},
        type => supervisor
    }.

leaderboard_sup() ->
    #{
        id => asobi_leaderboard_sup,
        start => {asobi_leaderboard_sup, start_link, []},
        type => supervisor
    }.

chat_sup() ->
    #{
        id => asobi_chat_sup,
        start => {asobi_chat_sup, start_link, []},
        type => supervisor
    }.

vote_sup() ->
    #{
        id => asobi_vote_sup,
        start => {asobi_vote_sup, start_link, []},
        type => supervisor
    }.

matchmaker_spec() ->
    #{
        id => asobi_matchmaker,
        start => {asobi_matchmaker, start_link, []}
    }.

tournament_sup() ->
    #{
        id => asobi_tournament_sup,
        start => {asobi_tournament_sup, start_link, []},
        type => supervisor
    }.

presence_spec() ->
    #{
        id => asobi_presence,
        start => {asobi_presence, start_link, []}
    }.

rate_limit_spec() ->
    #{
        id => asobi_rate_limits,
        start => {erlang, apply, [fun register_limiters/0, []]},
        restart => temporary
    }.

register_limiters() ->
    Defaults = #{
        auth => #{algorithm => sliding_window, limit => 300, window => 1000},
        iap => #{algorithm => sliding_window, limit => 300, window => 1000},
        api => #{algorithm => sliding_window, limit => 300, window => 1000}
    },
    Configured =
        case application:get_env(asobi, rate_limits, #{}) of
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
            Opts = maps:merge(DefaultOpts, Overrides),
            Name = limiter_name(Group),
            seki:new_limiter(Name, Opts)
        end,
        Defaults
    ),
    ignore.

limiter_name(auth) -> asobi_auth_limiter;
limiter_name(iap) -> asobi_iap_limiter;
limiter_name(api) -> asobi_api_limiter.

cluster_spec() ->
    #{
        id => asobi_cluster,
        start => {asobi_cluster, start_link, []}
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

season_manager_spec() ->
    #{
        id => asobi_season_manager,
        start => {asobi_season_manager, start_link, []}
    }.
