-module(asobi_sup).
-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

-spec start_link() -> {ok, pid()}.
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
        vote_sup(),
        matchmaker_spec(),
        leaderboard_sup(),
        chat_sup(),
        tournament_sup(),
        presence_spec()
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
        id => asobi_rate_limit_server,
        start => {asobi_rate_limit_server, start_link, []}
    }.

cluster_spec() ->
    #{
        id => asobi_cluster,
        start => {asobi_cluster, start_link, []}
    }.
