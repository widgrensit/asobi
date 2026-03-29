-module(asobi_tournament_server).
-behaviour(gen_server).

-export([start_link/1, get_info/1, join/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-spec start_link(map()) -> {ok, pid()}.
start_link(Tournament) ->
    TournamentId = maps:get(id, Tournament),
    gen_server:start_link({global, {?MODULE, TournamentId}}, ?MODULE, Tournament, []).

-spec get_info(binary()) -> {ok, map()} | {error, not_found}.
get_info(TournamentId) ->
    try
        gen_server:call({global, {?MODULE, TournamentId}}, get_info)
    catch
        exit:{noproc, _} -> {error, not_found}
    end.

-spec join(binary(), binary()) -> ok | {error, term()}.
join(TournamentId, PlayerId) ->
    try
        gen_server:call({global, {?MODULE, TournamentId}}, {join, PlayerId})
    catch
        exit:{noproc, _} -> {error, not_found}
    end.

-spec init(map()) -> {ok, map()}.
init(Tournament) ->
    #{start_at := StartAt, end_at := EndAt, leaderboard_id := BoardId} = Tournament,
    Now = erlang:system_time(second),
    StartSec = calendar:datetime_to_gregorian_seconds(StartAt) - 62167219200,
    EndSec = calendar:datetime_to_gregorian_seconds(EndAt) - 62167219200,
    _ =
        case StartSec > Now of
            true ->
                erlang:send_after((StartSec - Now) * 1000, self(), start_tournament);
            false ->
                self() ! start_tournament
        end,
    _ =
        case EndSec > Now of
            true ->
                erlang:send_after((EndSec - Now) * 1000, self(), end_tournament);
            false ->
                ok
        end,
    {ok, _} = asobi_leaderboard_sup:start_board(BoardId),
    {ok, Tournament#{participants => [], started => false}}.

-spec handle_call(term(), gen_server:from(), map()) -> {reply, term(), map()}.
handle_call(get_info, _From, State) ->
    {reply, {ok, maps:without([participants], State)}, State};
handle_call({join, _PlayerId}, _From, #{participants := P, max_entries := Max} = State) when
    is_integer(Max), length(P) >= Max
->
    {reply, {error, tournament_full}, State};
handle_call({join, PlayerId}, _From, #{participants := P} = State) ->
    case lists:member(PlayerId, P) of
        true ->
            {reply, {error, already_joined}, State};
        false ->
            {reply, ok, State#{participants => [PlayerId | P]}}
    end;
handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

-spec handle_cast(term(), map()) -> {noreply, map()}.
handle_cast(_Msg, State) ->
    {noreply, State}.

-spec handle_info(term(), map()) -> {noreply, map()} | {stop, normal, map()}.
handle_info(start_tournament, State) ->
    CS = kura_changeset:cast(asobi_tournament, State, #{status => ~"active"}, [status]),
    _ = asobi_repo:update(CS),
    {noreply, State#{status => ~"active", started => true}};
handle_info(end_tournament, State) ->
    CS = kura_changeset:cast(asobi_tournament, State, #{status => ~"finished"}, [status]),
    _ = asobi_repo:update(CS),
    {stop, normal, State#{status => ~"finished"}};
handle_info(_Info, State) ->
    {noreply, State}.

-spec terminate(term(), map()) -> ok.
terminate(_Reason, _State) ->
    ok.
