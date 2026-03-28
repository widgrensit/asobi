-module(asobi_match_sup).
-behaviour(supervisor).

-export([start_link/0, start_match/1]).
-export([init/1]).

-spec start_link() -> {ok, pid()}.
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

-spec start_match(map()) -> {ok, pid()}.
start_match(Config) ->
    supervisor:start_child(?MODULE, [Config]).

-spec init([]) -> {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init([]) ->
    SupFlags = #{
        strategy => simple_one_for_one,
        intensity => 10,
        period => 60
    },
    ChildSpec = #{
        id => asobi_match_server,
        start => {asobi_match_server, start_link, []},
        restart => temporary
    },
    {ok, {SupFlags, [ChildSpec]}}.
