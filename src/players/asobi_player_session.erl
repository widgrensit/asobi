-module(asobi_player_session).
-behaviour(gen_server).

-export([start_link/2, stop/1]).
-export([get_state/1, update_presence/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-dialyzer({nowarn_function, terminate/2}).

-spec start_link(binary(), pid()) -> {ok, pid()}.
start_link(PlayerId, WsPid) ->
    gen_server:start_link(?MODULE, #{player_id => PlayerId, ws_pid => WsPid}, []).

-spec stop(pid()) -> ok.
stop(Pid) ->
    gen_server:stop(Pid, normal, 5000).

-spec get_state(pid()) -> map().
get_state(Pid) ->
    gen_server:call(Pid, get_state).

-spec update_presence(pid(), map()) -> ok.
update_presence(Pid, Status) ->
    gen_server:cast(Pid, {update_presence, Status}).

-spec init(map()) -> {ok, map()}.
init(#{player_id := PlayerId, ws_pid := WsPid}) ->
    process_flag(trap_exit, true),
    monitor(process, WsPid),
    asobi_presence:track(PlayerId, self()),
    {ok, #{
        player_id => PlayerId,
        ws_pid => WsPid,
        match_pid => undefined,
        channels => [],
        presence => #{status => ~"online"},
        connected_at => erlang:system_time(millisecond)
    }}.

-spec handle_call(term(), gen_server:from(), map()) -> {reply, term(), map()}.
handle_call(get_state, _From, State) ->
    {reply, State, State};
handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

-spec handle_cast(term(), map()) -> {noreply, map()}.
handle_cast({update_presence, Status}, #{player_id := PlayerId} = State) ->
    asobi_presence:update(PlayerId, Status),
    {noreply, State#{presence => Status}};
handle_cast(_Msg, State) ->
    {noreply, State}.

-spec handle_info(term(), map()) -> {noreply, map()} | {stop, normal, map()}.
handle_info({'DOWN', _Ref, process, WsPid, _Reason}, #{ws_pid := WsPid} = State) ->
    {stop, normal, State};
handle_info({asobi_message, {match_joined, MatchPid}}, State) ->
    {noreply, State#{match_pid => MatchPid}};
handle_info({asobi_message, _} = Msg, #{ws_pid := WsPid} = State) ->
    WsPid ! Msg,
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

-spec terminate(term(), map()) -> ok.
terminate(_Reason, #{player_id := PlayerId, channels := Channels}) ->
    asobi_presence:untrack(PlayerId),
    lists:foreach(fun(Ch) -> asobi_chat_channel:leave(Ch, self()) end, Channels),
    ok.
