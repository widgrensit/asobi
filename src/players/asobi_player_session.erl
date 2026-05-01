-module(asobi_player_session).
-include_lib("kernel/include/logger.hrl").
-behaviour(gen_server).

-export([start_link/2, stop/1]).
-export([get_state/1, update_presence/2, set_zone/3]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-spec start_link(binary(), pid()) -> gen_server:start_ret().
start_link(PlayerId, WsPid) ->
    gen_server:start_link(?MODULE, #{player_id => PlayerId, ws_pid => WsPid}, []).

-spec stop(pid()) -> ok.
stop(Pid) ->
    gen_server:stop(Pid, normal, 5000).

-spec get_state(pid()) -> map().
get_state(Pid) ->
    case gen_server:call(Pid, get_state) of
        S when is_map(S) -> S;
        _ -> #{}
    end.

-spec update_presence(pid(), map()) -> ok.
update_presence(Pid, Status) ->
    gen_server:cast(Pid, {update_presence, Status}).

%% Synchronously bind world_pid + zone_pid into the session before the WS handler
%% replies world.joined, so an immediately-following world.input is routed to the
%% right zone instead of being silently dropped while the async {world_joined,...}
%% message is still in flight.
-spec set_zone(pid(), pid(), pid() | undefined) -> ok.
set_zone(Pid, WorldPid, ZonePid) ->
    ok = gen_server:call(Pid, {set_zone, WorldPid, ZonePid}).

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
handle_call({set_zone, WorldPid, ZonePid}, _From, State) ->
    {reply, ok, State#{world_pid => WorldPid, zone_pid => ZonePid}};
handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

-spec handle_cast(term(), map()) -> {noreply, map()}.
handle_cast({update_presence, Status}, #{player_id := PlayerId} = State) when is_map(Status) ->
    asobi_presence:update(PlayerId, Status),
    {noreply, State#{presence => Status}};
handle_cast({reconnect_world, WorldPid}, #{player_id := PlayerId} = State) when
    is_pid(WorldPid)
->
    %% F-28: world reconnects used to spawn an unsupervised helper from
    %% the WS handler. Running them inside the supervised session
    %% process means they're cleaned up with the session and a stuck
    %% reconnect cannot leak a pid.
    try asobi_world_server:reconnect(WorldPid, PlayerId) of
        _ -> ok
    catch
        Class:Reason ->
            ?LOG_DEBUG(#{
                msg => ~"world_reconnect_failed",
                player_id => PlayerId,
                class => Class,
                reason => Reason
            })
    end,
    {noreply, State};
handle_cast(_Msg, State) ->
    {noreply, State}.

-spec handle_info(term(), map()) -> {noreply, map()} | {stop, term(), map()}.
handle_info({'DOWN', _Ref, process, WsPid, _Reason}, #{ws_pid := WsPid} = State) ->
    {stop, normal, State};
handle_info({session_revoked, Reason}, #{ws_pid := WsPid} = State) ->
    WsPid ! {session_revoked, Reason},
    {stop, {shutdown, session_revoked}, State};
handle_info({asobi_message, {match_joined, MatchPid}}, State) ->
    {noreply, State#{match_pid => MatchPid}};
handle_info({asobi_message, {world_joined, WorldPid, ZonePid}}, State) ->
    {noreply, State#{world_pid => WorldPid, zone_pid => ZonePid}};
handle_info({asobi_message, {world_zone_changed, ZonePid}}, State) ->
    {noreply, State#{zone_pid => ZonePid}};
handle_info({asobi_message, _} = Msg, #{ws_pid := WsPid} = State) ->
    WsPid ! Msg,
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

-spec terminate(term(), map()) -> ok.
terminate(_Reason, #{player_id := PlayerId, channels := Channels}) ->
    asobi_presence:untrack(PlayerId),
    lists:foreach(fun(Ch) when is_binary(Ch) -> asobi_chat_channel:leave(Ch, self()) end, Channels),
    ok.
