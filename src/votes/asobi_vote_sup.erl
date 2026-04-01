-module(asobi_vote_sup).
-moduledoc "Dynamic supervisor for `asobi_vote_server` processes.".
-behaviour(supervisor).

-export([start_link/0, start_vote/1]).
-export([init/1]).

-spec start_link() -> {ok, pid()}.
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

-spec start_vote(map()) -> {ok, pid()}.
start_vote(Config) ->
    supervisor:start_child(?MODULE, [Config]).

-spec init([]) -> {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init([]) ->
    SupFlags = #{
        strategy => simple_one_for_one,
        intensity => 10,
        period => 60
    },
    ChildSpec = #{
        id => asobi_vote_server,
        start => {asobi_vote_server, start_link, []},
        restart => temporary
    },
    {ok, {SupFlags, [ChildSpec]}}.
