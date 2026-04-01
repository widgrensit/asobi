-module(asobi_player_session_sup).
-behaviour(supervisor).

-export([start_link/0, start_session/2]).
-export([init/1]).

-spec start_link() -> supervisor:startlink_ret().
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

-spec start_session(binary(), pid()) -> supervisor:startchild_ret().
start_session(PlayerId, WsPid) ->
    supervisor:start_child(?MODULE, [PlayerId, WsPid]).

-spec init([]) -> {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init([]) ->
    SupFlags = #{
        strategy => simple_one_for_one,
        intensity => 10,
        period => 60
    },
    ChildSpec = #{
        id => asobi_player_session,
        start => {asobi_player_session, start_link, []},
        restart => temporary
    },
    {ok, {SupFlags, [ChildSpec]}}.
